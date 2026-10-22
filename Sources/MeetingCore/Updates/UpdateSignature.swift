public import CryptoKit
public import Foundation

/// Ed25519 signature of an update archive (TD-29). The private key lives only in the publisher's Keychain;
/// the app embeds the public key (`MIUpdatePublicKey`). The signed message binds the version, so an older
/// signed archive cannot be offered as a newer one.
public enum UpdateSignature {
    static let context = "dev.meetingintelligence.app-update.v1"

    public static func message(version: String, sha256: String) -> Data {
        Data("\(context)\nversion=\(version)\nsha256=\(sha256.lowercased())\n".utf8)
    }

    public static func sign(version: String, sha256: String, privateKey: Curve25519.Signing.PrivateKey) throws -> String {
        try privateKey.signature(for: message(version: version, sha256: sha256)).base64EncodedString()
    }

    /// `signature` and `publicKey` are base64; whitespace around them is ignored.
    public static func isValid(signature: String, version: String, sha256: String, publicKey: String) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: publicKey.trimmed) ?? Data()),
              let signatureData = Data(base64Encoded: signature.trimmed) else { return false }
        return key.isValidSignature(signatureData, for: message(version: version, sha256: sha256))
    }

    public static func publicKey(of privateKey: Curve25519.Signing.PrivateKey) -> String {
        privateKey.publicKey.rawRepresentation.base64EncodedString()
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
