import Foundation

/// `MAJOR.MINOR.PATCH[-prerelease]` as published in release tags (`v0.2.0`). A pre-release sorts
/// before its release; missing components count as zero (`1.0` == `1.0.0`).
public struct AppVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let components: [Int]
    public let prerelease: String?

    public init?(_ string: String) {
        var text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.first == "v" || text.first == "V" { text.removeFirst() }
        let parts = text.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numbers = parts[0].split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard (1...4).contains(numbers.count), numbers.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
        if parts.count == 2, parts[1].isEmpty { return nil }
        components = numbers.compactMap { $0 }
        prerelease = parts.count == 2 ? String(parts[1]) : nil
    }

    public var description: String {
        components.map(String.init).joined(separator: ".") + (prerelease.map { "-\($0)" } ?? "")
    }

    private var padded: [Int] { components + Array(repeating: 0, count: 4 - components.count) }

    public static func == (a: AppVersion, b: AppVersion) -> Bool {
        a.padded == b.padded && a.prerelease == b.prerelease
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(padded)
        hasher.combine(prerelease)
    }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        if a.padded != b.padded { return a.padded.lexicographicallyPrecedes(b.padded) }
        switch (a.prerelease, b.prerelease) {
        case (nil, _): return false
        case (_?, nil): return true
        case let (x?, y?): return x.compare(y, options: .numeric) == .orderedAscending
        }
    }
}
