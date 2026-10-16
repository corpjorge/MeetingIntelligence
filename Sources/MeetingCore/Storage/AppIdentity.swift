import Foundation

/// Single source of truth for the product's identity.
///
/// The display name is read from the bundle (`CFBundleDisplayName`, written by
/// `scripts/build-app.sh` from `config/app.env`) so renaming the product never
/// requires touching Swift code. The fallback is used by tests, the CLI and the
/// MCP server, which are not bundled apps.
public enum AppIdentity {
    public static let fallbackDisplayName = "Meeting Intelligence"
    public static let fallbackBundleIdentifier = "dev.meetingintelligence.app"

    /// Folder under `~/Library/Application Support`. Kept independent from the
    /// display name so renaming the product does not orphan existing data.
    public static let storageFolderName = "MeetingIntelligence"

    public static var displayName: String {
        if let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
           !name.isEmpty {
            return name
        }
        return fallbackDisplayName
    }

    public static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? fallbackBundleIdentifier
    }

    /// Keychain service shared by the app and its helper executables.
    public static var keychainService: String {
        "\(fallbackBundleIdentifier).secrets"
    }

    public static var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.1.0-dev"
    }
}
