import AVFoundation
import Foundation
import Testing
@testable import MeetingCore
@testable import MeetingSpeech

private actor Received {
    var values: [Float] = []
    func append(_ value: Float) { values.append(value) }
}

@Suite("Transcripción en vivo: entrada ordenada", .timeLimit(.minutes(1)))
struct LiveAudioInputsTests {
    @Test func blocksArriveInOrderAndCloseWaitsForDelivery() async {
        let inputs = LiveAudioInputs()
        let remote = Received(), mic = Received()
        inputs.open(.remoteSystemAudio) { samples in
            if Int(samples[0]) % 10 == 0 { try? await Task.sleep(for: .milliseconds(2)) }
            await remote.append(samples[0])
        }
        inputs.open(.localMicrophone) { samples in await mic.append(samples[0]) }
        for i in 0..<300 {
            inputs.send([Float(i)], to: .remoteSystemAudio)
            inputs.send([Float(i + 1_000)], to: .localMicrophone)
        }
        await inputs.close()
        #expect(await remote.values == (0..<300).map(Float.init))
        #expect(await mic.values == (0..<300).map { Float($0 + 1_000) })
        inputs.send([1], to: .remoteSystemAudio)
        await inputs.close()
        #expect(await remote.values.count == 300)
    }

    @Test func blocksFedFromAnotherThreadKeepTheirOrder() async {
        let inputs = LiveAudioInputs()
        let remote = Received()
        inputs.open(.remoteSystemAudio) { samples in await remote.append(samples[0]) }
        await Task.detached {
            for i in 0..<200 { inputs.send([Float(i)], to: .remoteSystemAudio) }
        }.value
        await inputs.close()
        #expect(await remote.values == (0..<200).map(Float.init))
    }

    @Test func cancelDropsPendingInput() async {
        let inputs = LiveAudioInputs()
        let remote = Received()
        inputs.open(.remoteSystemAudio) { samples in
            try? await Task.sleep(for: .seconds(5))
            await remote.append(samples[0])
        }
        inputs.send([0], to: .remoteSystemAudio)
        inputs.cancel()
        inputs.send([1], to: .remoteSystemAudio)
        await inputs.close()
        #expect(await remote.values.count <= 1)
    }

    @Test func pcmBufferCopiesSamples() throws {
        let buffer = try #require(LiveTranscriber.pcmBuffer([0.25, -0.5, 1]))
        #expect(buffer.frameLength == 3)
        #expect(buffer.format.sampleRate == 16_000)
        #expect(Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: 3)) == [0.25, -0.5, 1])
        #expect(LiveTranscriber.pcmBuffer([]) == nil)
    }
}
