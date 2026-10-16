import Foundation
import GRDB
import MeetingCore

/// Opens the library read-only; if it does not exist the server still speaks
/// MCP and reports the problem from each tool call.
protocol GRDBReaderBox {
    func makeServer(paths: AppPaths) -> MCPServerCore
}

struct OpenedLibrary: GRDBReaderBox {
    let reader: any DatabaseReader
    init(paths: AppPaths) throws {
        reader = try AppDatabase.openReadOnly(paths: paths)
    }
    func makeServer(paths: AppPaths) -> MCPServerCore {
        MCPServerCore(tools: MCPTools(reader: reader, policy: { MCPAccessPolicy.load(from: paths) }))
    }
}

struct UnavailableLibrary: GRDBReaderBox {
    let reason: String
    func makeServer(paths: AppPaths) -> MCPServerCore {
        // An empty in-memory library with access disabled yields clear tool errors.
        let db = try! AppDatabase.inMemory()
        return MCPServerCore(tools: MCPTools(reader: db.reader, policy: { MCPAccessPolicy(enabled: false) }))
    }
}
