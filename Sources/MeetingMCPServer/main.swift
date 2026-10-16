import Foundation
import MeetingCore

// meeting-intelligence-mcp — read-only MCP server over stdio.
//
// Framing: one JSON-RPC message per line on stdin/stdout (MCP stdio transport).
// Diagnostics go to stderr only; stdout carries protocol messages exclusively.

setvbuf(stdout, nil, _IOLBF, 0)

func log(_ message: String) {
    FileHandle.standardError.write(Data("[meeting-intelligence-mcp] \(message)\n".utf8))
}

let paths = AppPaths.resolveDefault()
let reader: any GRDBReaderBox
do {
    reader = try OpenedLibrary(paths: paths)
} catch {
    log("No se pudo abrir la biblioteca: \(error.localizedDescription)")
    reader = UnavailableLibrary(reason: error.localizedDescription)
}

let server = reader.makeServer(paths: paths)
log("listo · biblioteca \(paths.root.path) · protocolos \((MCPServerCore.modernVersions + MCPServerCore.legacyVersions).joined(separator: ", "))")

while let line = readLine(strippingNewline: true) {
    if let response = server.handleLine(line) {
        FileHandle.standardOutput.write(Data((response + "\n").utf8))
    }
}
log("stdin cerrado; saliendo")
