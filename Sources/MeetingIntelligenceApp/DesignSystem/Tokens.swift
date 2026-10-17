import AppKit
import SwiftUI

// MARK: - Design tokens
//
// Every visual constant of the app lives here. Views never use raw numbers or
// literal colors: they use `DS.Space`, `DS.Radius`, `DS.Color`, `DS.Font`, …
// Colors are dynamic (light/dark) and defined in code (no asset catalog).

enum DS {
    // MARK: Spacing (4-pt grid)
    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        static let xxxl: CGFloat = 48
    }

    // MARK: Corner radius
    enum Radius {
        static let xs: CGFloat = 4
        static let s: CGFloat = 6
        static let m: CGFloat = 10
        static let l: CGFloat = 14
        static let pill: CGFloat = 999
    }

    // MARK: Layout
    enum Layout {
        static let contentMaxWidth: CGFloat = 1040
        static let readingMaxWidth: CGFloat = 760
        static let sidebarWidth: CGFloat = 220
        static let listColumnWidth: CGFloat = 290
        static let rowHeight: CGFloat = 44
        static let avatarSize: CGFloat = 28
        static let iconButton: CGFloat = 28
        static let hairline: CGFloat = 1
    }

    // MARK: Typography (SF Pro / SF Mono, Dynamic Type aware via relativeTo)
    enum Font {
        static let display = SwiftUI.Font.system(size: 26, weight: .semibold, design: .default)
        static let title = SwiftUI.Font.system(size: 19, weight: .semibold)
        static let headline = SwiftUI.Font.system(size: 14, weight: .semibold)
        static let body = SwiftUI.Font.system(size: 13)
        static let bodyEmphasis = SwiftUI.Font.system(size: 13, weight: .medium)
        static let reading = SwiftUI.Font.system(size: 14).leading(.loose)
        static let callout = SwiftUI.Font.system(size: 12)
        static let caption = SwiftUI.Font.system(size: 11)
        static let captionEmphasis = SwiftUI.Font.system(size: 11, weight: .semibold)
        static let overline = SwiftUI.Font.system(size: 10.5, weight: .semibold).width(.expanded)
        static let mono = SwiftUI.Font.system(size: 11.5, design: .monospaced)
        static let timer = SwiftUI.Font.system(size: 44, weight: .light, design: .rounded).monospacedDigit()
        static let metric = SwiftUI.Font.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit()
    }

    // MARK: Colors (semantic, dynamic)
    enum Color {
        static let background = dynamic(light: 0xF7F7F8, dark: 0x111113)
        static let surface = dynamic(light: 0xFFFFFF, dark: 0x18181B)
        static let surfaceRaised = dynamic(light: 0xFFFFFF, dark: 0x1F1F23)
        static let surfaceSunken = dynamic(light: 0xF0F0F2, dark: 0x0C0C0E)
        static let hover = dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.04, darkAlpha: 0.05)
        static let selected = dynamic(light: 0x4F6BF2, dark: 0x7A8CFF, lightAlpha: 0.10, darkAlpha: 0.16)
        static let border = dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.08, darkAlpha: 0.08)
        static let borderStrong = dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.14, darkAlpha: 0.14)

        static let textPrimary = dynamic(light: 0x18181B, dark: 0xEDEDEF)
        static let textSecondary = dynamic(light: 0x5B5B66, dark: 0xA0A0AB)
        static let textTertiary = dynamic(light: 0x8E8E99, dark: 0x6E6E78)

        static let accent = dynamic(light: 0x4F6BF2, dark: 0x7A8CFF)
        static let accentSoft = dynamic(light: 0x4F6BF2, dark: 0x7A8CFF, lightAlpha: 0.12, darkAlpha: 0.18)
        static let onAccent = SwiftUI.Color.white

        static let recording = dynamic(light: 0xE5484D, dark: 0xFF6369)
        static let success = dynamic(light: 0x2F9E6A, dark: 0x3DD68C)
        static let warning = dynamic(light: 0xC77C02, dark: 0xF5B33F)
        static let danger = dynamic(light: 0xD93D42, dark: 0xFF6369)
        static let info = dynamic(light: 0x2E7CD6, dark: 0x5EB1EF)
        static let ai = dynamic(light: 0x8B5CF6, dark: 0xA78BFA)

        /// Distinct, accessible hues for speakers (cycled by speaker ordinal).
        static let speakers: [SwiftUI.Color] = [
            dynamic(light: 0x4F6BF2, dark: 0x8C9BFF), // indigo
            dynamic(light: 0x0E9384, dark: 0x2DD4BF), // teal
            dynamic(light: 0xC2410C, dark: 0xFB923C), // orange
            dynamic(light: 0xBE185D, dark: 0xF472B6), // rose
            dynamic(light: 0x7C3AED, dark: 0xA78BFA), // violet
            dynamic(light: 0x15803D, dark: 0x4ADE80), // green
            dynamic(light: 0x0369A1, dark: 0x38BDF8), // sky
            dynamic(light: 0xA16207, dark: 0xFACC15), // amber
        ]

        static func speaker(_ index: Int) -> SwiftUI.Color {
            speakers[((index % speakers.count) + speakers.count) % speakers.count]
        }

        nonisolated static func dynamic(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1,
                                        darkAlpha: CGFloat = 1) -> SwiftUI.Color {
            SwiftUI.Color(nsColor: NSColor(name: nil) { @Sendable appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                let hex = isDark ? dark : light
                return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                               green: CGFloat((hex >> 8) & 0xFF) / 255,
                               blue: CGFloat(hex & 0xFF) / 255,
                               alpha: isDark ? darkAlpha : lightAlpha)
            })
        }
    }

    // MARK: Elevation
    enum Elevation {
        case flat, raised, overlay

        var shadowRadius: CGFloat {
            switch self { case .flat: 0; case .raised: 2; case .overlay: 18 }
        }
        var shadowY: CGFloat {
            switch self { case .flat: 0; case .raised: 1; case .overlay: 8 }
        }
        var shadowOpacity: Double {
            switch self { case .flat: 0; case .raised: 0.06; case .overlay: 0.18 }
        }
    }

    // MARK: Motion
    enum Motion {
        static let quick = Animation.snappy(duration: 0.16)
        static let standard = Animation.smooth(duration: 0.24)
        static let emphasized = Animation.spring(response: 0.38, dampingFraction: 0.82)
        static let pulse = Animation.easeInOut(duration: 0.9).repeatForever(autoreverses: true)
    }
}

extension View {
    func elevation(_ level: DS.Elevation) -> some View {
        shadow(color: .black.opacity(level.shadowOpacity), radius: level.shadowRadius, x: 0, y: level.shadowY)
    }
}
