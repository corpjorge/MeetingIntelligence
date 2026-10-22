import CryptoKit
import Foundation
import MeetingCore

// mi-release — publisher-only tool (never shipped inside the app). Manages the Ed25519 key that signs
// update archives (TD-29) and signs/verifies them with the exact message the app checks.
//
//   mi-release keygen                                       create the key in the login Keychain (once)
//   mi-release public-key                                   print the public key for config/app.env
//   mi-release sign <zip> --version X [--public-key K]      print the base64 signature
//   mi-release verify <zip> --version X --signature <file> --public-key K
//
// The private key is stored and read with /usr/bin/security, so rebuilding this tool never triggers
// Keychain prompts, and it never appears in process arguments.

let service = "dev.meetingintelligence.update-signing"
let account = "ed25519"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("mi-release: \(message)\n".utf8))
    exit(1)
}

func option(_ name: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func security(_ arguments: [String], stdin: String? = nil) async throws -> ProcessResult {
    try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/security"), arguments: arguments,
                                stdin: stdin.map { Data($0.utf8) }, timeout: 30)
}

func storedKey() async throws -> Curve25519.Signing.PrivateKey? {
    let result = try await security(["find-generic-password", "-s", service, "-a", account, "-w"])
    guard result.exitCode == 0 else { return nil }
    guard let raw = Data(base64Encoded: result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        fail("la clave guardada en el Llavero no es válida")
    }
    return try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
}

func requireKey() async throws -> Curve25519.Signing.PrivateKey {
    guard let key = try await storedKey() else { fail("no hay clave de firma en el Llavero; ejecuta `mi-release keygen`") }
    return key
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "keygen":
    if try await storedKey() != nil {
        fail("ya existe una clave de firma en el Llavero (servicio \(service)); no se reemplaza")
    }
    let key = Curve25519.Signing.PrivateKey()
    let command = "add-generic-password -s \(service) -a \(account) -l \"Meeting Intelligence · firma de actualizaciones\" "
        + "-j \"Clave privada Ed25519 de mi-release (TD-29). Haz una copia de seguridad.\" "
        + "-w \(key.rawRepresentation.base64EncodedString())\n"
    let result = try await security(["-i"], stdin: command)
    guard result.exitCode == 0, try await storedKey() != nil else {
        fail("no se pudo guardar la clave en el Llavero: \(result.stderrText)")
    }
    print(UpdateSignature.publicKey(of: key))
    FileHandle.standardError.write(Data("""
    Clave creada en el Llavero de inicio de sesión (servicio \(service)).
    Copia la clave pública de arriba en config/app.env (UPDATE_PUBLIC_KEY) y guarda una copia de seguridad
    de la privada: sin ella, las versiones futuras no se podrán instalar desde la app.

    """.utf8))
case "public-key":
    print(UpdateSignature.publicKey(of: try await requireKey()))
case "sign":
    guard args.count >= 2, let version = option("--version", in: args) else {
        fail("uso: mi-release sign <zip> --version X [--public-key K]")
    }
    let key = try await requireKey()
    if let expected = option("--public-key", in: args), expected != UpdateSignature.publicKey(of: key) {
        fail("la clave del Llavero no corresponde a UPDATE_PUBLIC_KEY: la app rechazaría esta firma")
    }
    let sha = try ContentHash.sha256(of: URL(fileURLWithPath: args[1]))
    print(try UpdateSignature.sign(version: version, sha256: sha, privateKey: key))
case "verify":
    guard args.count >= 2, let version = option("--version", in: args),
          let signatureFile = option("--signature", in: args), let publicKey = option("--public-key", in: args) else {
        fail("uso: mi-release verify <zip> --version X --signature <archivo> --public-key K")
    }
    let signature = try String(contentsOfFile: signatureFile, encoding: .utf8)
    let sha = try ContentHash.sha256(of: URL(fileURLWithPath: args[1]))
    guard UpdateSignature.isValid(signature: signature, version: version, sha256: sha, publicKey: publicKey) else {
        fail("firma NO válida")
    }
    print("firma válida · \(version) · sha256 \(sha)")
default:
    fail("comandos: keygen | public-key | sign <zip> --version X [--public-key K] | verify <zip> --version X --signature F --public-key K")
}
