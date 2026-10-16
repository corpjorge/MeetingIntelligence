import Foundation

public enum Timecode {
    /// `HH:MM:SS` (always with hours, as used in evidence references).
    public static func hms(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    /// `M:SS` or `H:MM:SS` for compact UI labels.
    public static func compact(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// SubRip timestamp `HH:MM:SS,mmm`.
    public static func srt(_ seconds: Double) -> String {
        let clamped = max(0, seconds)
        let millis = Int((clamped * 1000).rounded())
        let h = millis / 3_600_000
        let m = (millis % 3_600_000) / 60_000
        let s = (millis % 60_000) / 1000
        let ms = millis % 1000
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }

    /// Human duration in Spanish: "1 h 05 min", "12 min", "45 s".
    public static func humanDuration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%d h %02d min", h, m) }
        if m > 0 { return "\(m) min" }
        return "\(s) s"
    }
}
