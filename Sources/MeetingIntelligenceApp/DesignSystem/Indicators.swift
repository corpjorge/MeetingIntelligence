import SwiftUI

struct SpeakerAvatar: View {
    let name: String
    var colorIndex: Int?
    var size: CGFloat = DS.Layout.avatarSize
    var isUnknown = false

    private var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first.map(String.init) }.joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }

    var body: some View {
        let tint = isUnknown ? DS.Color.textTertiary : DS.Color.speaker(colorIndex ?? StableHash.index(name))
        ZStack {
            Circle().fill(tint.opacity(0.16))
            if isUnknown {
                Image(systemName: "person.fill.questionmark").font(.system(size: size * 0.42)).foregroundStyle(tint)
            } else {
                Text(initials).font(.system(size: size * 0.38, weight: .semibold)).foregroundStyle(tint)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Segmented horizontal level meter (0…1).
struct LevelMeterView: View {
    let level: Double
    var tint: Color = DS.Color.success
    var segments = 24

    var body: some View {
        GeometryReader { geo in
            let spacing: CGFloat = 2
            let width = (geo.size.width - spacing * CGFloat(segments - 1)) / CGFloat(segments)
            HStack(spacing: spacing) {
                ForEach(0..<segments, id: \.self) { i in
                    let threshold = Double(i) / Double(segments)
                    let lit = level > threshold
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(lit ? color(for: threshold) : DS.Color.border)
                        .frame(width: max(1, width))
                }
            }
        }
        .frame(height: 8)
        .animation(.linear(duration: 0.08), value: level)
        .accessibilityLabel("Nivel de audio")
        .accessibilityValue("\(Int(level * 100)) por ciento")
    }

    private func color(for threshold: Double) -> Color {
        threshold > 0.88 ? DS.Color.danger : (threshold > 0.72 ? DS.Color.warning : tint)
    }
}

struct RecordingDot: View {
    var size: CGFloat = 10
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(DS.Color.recording)
            .frame(width: size, height: size)
            .overlay(Circle().stroke(DS.Color.recording.opacity(0.4), lineWidth: 3).scaleEffect(pulsing ? 1.9 : 1)
                .opacity(pulsing ? 0 : 1))
            .onAppear { withAnimation(DS.Motion.pulse) { pulsing = true } }
            .accessibilityLabel("Grabando")
    }
}

/// Text with `[term]` markers (from FTS snippets) rendered as highlights.
struct HighlightedSnippet: View {
    let snippet: String

    var body: some View {
        Text(attributed).font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary)
    }

    private var attributed: AttributedString {
        var result = AttributedString()
        var remainder = Substring(snippet)
        while let open = remainder.firstIndex(of: "[") {
            result += AttributedString(String(remainder[..<open]))
            let after = remainder[remainder.index(after: open)...]
            guard let close = after.firstIndex(of: "]") else {
                result += AttributedString(String(remainder[open...]))
                return result
            }
            var match = AttributedString(String(after[..<close]))
            match.foregroundColor = DS.Color.textPrimary
            match.backgroundColor = DS.Color.accentSoft
            match.font = DS.Font.callout.weight(.semibold)
            result += match
            remainder = after[after.index(after: close)...]
        }
        result += AttributedString(String(remainder))
        return result
    }
}

/// Deterministic hash (stable across launches, unlike `hashValue`) for color assignment.
enum StableHash {
    static func index(_ string: String) -> Int {
        var hash: UInt32 = 5381
        for byte in string.utf8 { hash = (hash &* 33) &+ UInt32(byte) }
        return Int(hash % 1024)
    }
}
