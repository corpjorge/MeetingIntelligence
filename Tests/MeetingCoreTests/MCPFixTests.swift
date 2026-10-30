import Foundation
import GRDB
import Testing
@testable import MeetingCore

@Suite("Servidor MCP: tipos JSON, participantes vigentes y JSON-RPC")
struct MCPFixTests {
    private func server(_ db: AppDatabase) -> MCPServerCore {
        MCPServerCore(tools: MCPTools(reader: db.reader, policy: { MCPAccessPolicy(enabled: true) }), serverVersion: "test")
    }

    private func object(_ line: String?) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(try #require(line).utf8))
    }

    private func response(_ s: MCPServerCore, _ line: String) throws -> [String: Any] {
        try #require(try object(s.handleLine(line)) as? [String: Any])
    }

    private func call(_ s: MCPServerCore, _ name: String, _ arguments: String) throws -> [String: Any] {
        let reply = try response(s, #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"\#(name)","arguments":\#(arguments)}}"#)
        return try #require(reply["result"] as? [String: Any])
    }

    private func errorCode(_ reply: [String: Any]) -> Int? {
        (reply["error"] as? [String: Any])?["code"] as? Int
    }

    @Test func numbersFromRealJSONAreNotTakenForBooleans() throws {
        let values = try #require(try JSONSerialization.jsonObject(with: Data("[0,1,1.0,0.0,true,false]".utf8)) as? [Any])
        #expect(values.map(MCPTools.isJSONBoolean) == [false, false, false, false, true, true])

        let db = try AppDatabase.inMemory()
        let (meeting, _, _, _) = try Fixture.meeting(db, texts: [("Debemos validar ese campo", 0, 2), ("De acuerdo", 3, 4)])
        let s = server(db)
        for arguments in [#"{"limit":1}"#, #"{"limit":1.0}"#] {
            let result = try call(s, "list_meetings", arguments)
            #expect(result["isError"] as? Bool == false, "\(arguments)")
            #expect(((result["structuredContent"] as? [String: Any])?["meetings"] as? [Any])?.count == 1)
        }
        let window = try call(s, "get_transcript", #"{"meeting_id":"\#(meeting.id)","start_seconds":0,"end_seconds":1,"max_segments":1}"#)
        #expect(window["isError"] as? Bool == false)
        #expect(((window["structuredContent"] as? [String: Any])?["segments"] as? [Any])?.count == 1)
        #expect(try call(s, "get_transcript", #"{"meeting_id":"\#(meeting.id)","start_seconds":0.0}"#)["isError"] as? Bool == false)
        for arguments in [#"{"limit":true}"#, #"{"limit":false}"#, #"{"limit":1.5}"#, #"{"limit":0}"#, #"{"limit":1e300}"#] {
            #expect(try call(s, "list_meetings", arguments)["isError"] as? Bool == true, "\(arguments)")
        }
        #expect(try call(s, "get_transcript", #"{"meeting_id":"\#(meeting.id)","start_seconds":true}"#)["isError"] as? Bool == true)
        #expect(try call(s, "get_decisions", #"{"include_unconfirmed":true}"#)["isError"] as? Bool == false)
        #expect(try call(s, "get_decisions", #"{"include_unconfirmed":1}"#)["isError"] as? Bool == true)
    }

    @Test func participantsOnlyCountTheCurrentTranscript() async throws {
        let db = try AppDatabase.inMemory()
        let (meeting, track, _, segments) = try Fixture.meeting(db, texts: [("Hola, soy Ana", 0, 2)])
        let ana = Participant(displayName: "Ana Pérez")
        try await db.writer.write { db in
            try ana.insert(db)
            var segment = segments[0]
            segment.participantId = ana.id
            try segment.update(db)
        }
        let s = server(db)
        func names(_ arguments: String) throws -> [String] {
            let result = try call(s, "get_participants", arguments)
            let people = (result["structuredContent"] as? [String: Any])?["participants"] as? [[String: Any]] ?? []
            return people.compactMap { $0["name"] as? String }
        }
        #expect(try names(#"{"meeting_id":"\#(meeting.id)"}"#) == ["Ana Pérez"])
        #expect(try names("{}") == ["Ana Pérez"])

        let reprocessed = Transcript(meetingId: meeting.id, trackId: track.id, engine: "fixture", modelIdentifier: "fixture-2",
                                     language: "es-CO", isFinal: true, audioDurationSeconds: 120, processingSeconds: 1,
                                     meanConfidence: 0.9)
        try db.replaceTranscript(reprocessed, segments: [
            TranscriptSegment(transcriptId: reprocessed.id, meetingId: meeting.id, trackId: track.id, source: .imported,
                              orderIndex: 0, startTime: 0, endTime: 2, asrText: "Hola a todos"),
        ])
        #expect(try names(#"{"meeting_id":"\#(meeting.id)"}"#).isEmpty)
        #expect(try names("{}").isEmpty)
    }

    @Test func jsonRPCIdsAndBatchesFollowTheSpecification() throws {
        let s = server(try AppDatabase.inMemory())
        let nullID = try response(s, #"{"jsonrpc":"2.0","id":null,"method":"ping"}"#)
        #expect(errorCode(nullID) == -32600 && nullID["id"] is NSNull)
        let boolID = try response(s, #"{"jsonrpc":"2.0","id":true,"method":"ping"}"#)
        #expect(errorCode(boolID) == -32600 && boolID["id"] is NSNull)
        let stringID = try response(s, #"{"jsonrpc":"2.0","id":"a","method":"ping"}"#)
        #expect(stringID["id"] as? String == "a" && stringID["result"] != nil)
        #expect(errorCode(try response(s, #"{"jsonrpc":"2.0"}"#)) == -32600)
        #expect(s.handleLine(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)

        let empty = try response(s, "[]")
        #expect(errorCode(empty) == -32600 && empty["id"] is NSNull)
        let mixed = try #require(try object(s.handleLine(
            #"[{"jsonrpc":"2.0","id":7,"method":"ping"},1,{"jsonrpc":"2.0","method":"notifications/initialized"}]"#)) as? [[String: Any]])
        #expect(mixed.count == 2)
        #expect(mixed.first?["id"] as? Int == 7 && mixed.first?["result"] != nil)
        #expect(mixed.last.flatMap(errorCode) == -32600 && mixed.last?["id"] is NSNull)
        #expect(s.handleLine(#"[{"jsonrpc":"2.0","method":"notifications/initialized"}]"#) == nil)
    }
}
