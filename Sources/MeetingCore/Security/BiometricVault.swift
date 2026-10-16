public import Foundation
public import CryptoKit

/// Supplies the symmetric key protecting biometric data.
public protocol BiometricKeyProvider: Sendable {
    func key() throws -> SymmetricKey
    /// Destroys the key, making every sealed embedding unrecoverable.
    func destroyKey() throws
}

/// Key stored in the user's login Keychain (device-only, after first unlock).
public struct KeychainBiometricKeyProvider: BiometricKeyProvider {
    private let store: KeychainStore
    private let account = "biometric-embedding-key.v1"

    public init(store: KeychainStore = KeychainStore()) {
        self.store = store
    }

    public func key() throws -> SymmetricKey {
        if let data = try store.data(for: account), data.count == 32 {
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        try store.set(key.withUnsafeBytes { Data($0) }, for: account)
        return key
    }

    public func destroyKey() throws {
        try store.delete(account)
    }
}

/// In-memory key for tests and previews. Never used in production paths.
public final class EphemeralBiometricKeyProvider: BiometricKeyProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: SymmetricKey? = SymmetricKey(size: .bits256)

    public init() {}

    public func key() throws -> SymmetricKey {
        lock.withLock {
            if let stored { return stored }
            let fresh = SymmetricKey(size: .bits256)
            stored = fresh
            return fresh
        }
    }

    public func destroyKey() throws {
        lock.withLock { stored = nil }
    }
}

/// Seals speaker embeddings with AES-GCM before they touch the database.
/// Biometric vectors are never written in clear text and never exported.
public struct BiometricVault: Sendable {
    private let keyProvider: any BiometricKeyProvider
    /// Associated data binds ciphertexts to their purpose and format version.
    private let associatedData = Data("mi.speaker-embedding.v1".utf8)

    public init(keyProvider: any BiometricKeyProvider) {
        self.keyProvider = keyProvider
    }

    public func seal(_ embedding: [Float]) throws -> Data {
        let plain = embedding.withUnsafeBufferPointer { Data(buffer: $0) }
        let box = try AES.GCM.seal(plain, using: try keyProvider.key(), authenticating: associatedData)
        guard let combined = box.combined else { throw BiometricVaultError.sealingFailed }
        return combined
    }

    public func open(_ ciphertext: Data) throws -> [Float] {
        let box = try AES.GCM.SealedBox(combined: ciphertext)
        let plain = try AES.GCM.open(box, using: try keyProvider.key(), authenticating: associatedData)
        guard plain.count % MemoryLayout<Float>.size == 0 else { throw BiometricVaultError.corrupted }
        return plain.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}

public enum BiometricVaultError: LocalizedError, Sendable {
    case sealingFailed
    case corrupted

    public var errorDescription: String? {
        switch self {
        case .sealingFailed: "No se pudo cifrar el perfil de voz."
        case .corrupted: "El perfil de voz cifrado está dañado."
        }
    }
}
