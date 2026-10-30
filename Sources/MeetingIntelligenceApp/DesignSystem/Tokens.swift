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
        static let none: CGFloat = 0
        static let xxxs: CGFloat = 1
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
        static let meterSegment: CGFloat = 1.5
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

        static let sidebarMinWidth: CGFloat = 210
        static let sidebarMaxWidth: CGFloat = 300
        /// Single-column pages (recording setup and live view).
        static let singleColumnMaxWidth: CGFloat = 720
        static let detailMaxWidth: CGFloat = 820
        static let chatMaxWidth: CGFloat = readingMaxWidth + 120
        static let transcriptMaxWidth: CGFloat = readingMaxWidth + 160
        static let dashboardColumnMinWidth: CGFloat = 300
        static let toastMaxWidth: CGFloat = 520
        /// Floating banner with actions (e.g. a new app version).
        static let bannerMaxWidth: CGFloat = 640
        static let menuBarWidth: CGFloat = 280
        /// Timecode column to the left of transcript text.
        static let timecodeGutter: CGFloat = 64
        static let editorMinHeight: CGFloat = 64
        static let videoPreviewHeight: CGFloat = 200
        static let videoPlayerHeight: CGFloat = 360
        static let emptyStateMessageMaxWidth: CGFloat = 380

        enum Window {
            static let minWidth: CGFloat = 1000
            static let minHeight: CGFloat = 640
            static let defaultWidth: CGFloat = 1240
            static let defaultHeight: CGFloat = 800
            static let settingsWidth: CGFloat = 680
            static let settingsHeight: CGFloat = 560
        }

        enum Sheet {
            static let s: CGFloat = 380
            static let m: CGFloat = 480
            static let l: CGFloat = 520
            static let xl: CGFloat = 560
            static let listHeight: CGFloat = 320
            static let reviewHeight: CGFloat = 560
        }

        enum Control {
            static let searchFieldHeight: CGFloat = 32
            static let searchFieldCompactHeight: CGFloat = 30
            static let searchFieldMinWidth: CGFloat = 240
            static let searchFieldMaxWidth: CGFloat = 360
            static let segmentedPickerMaxWidth: CGFloat = 460
            static let filterPickerWidth: CGFloat = 340
            static let pickerNarrowWidth: CGFloat = 190
            static let pickerWidth: CGFloat = 220
            static let pickerWideWidth: CGFloat = 260
            static let fieldNarrowMaxWidth: CGFloat = 280
            static let fieldMaxWidth: CGFloat = 320
            static let progressBarMaxWidth: CGFloat = 240
            static let loadingProgressMaxWidth: CGFloat = 260
            static let meterLabelWidth: CGFloat = 190
            /// Level meter numeric readout and compact (menu bar) meter label.
            static let meterCompactWidth: CGFloat = 52
        }
    }

    // MARK: Component sizes
    enum Size {
        // Status and recording indicator dots
        static let dotXS: CGFloat = 6
        static let dotS: CGFloat = 7
        static let dotM: CGFloat = 8
        static let dotL: CGFloat = 12
        static let recordingDot: CGFloat = 10

        // Speaker avatars (the regular one is `Layout.avatarSize`)
        static let avatarSmall: CGFloat = 20
        static let avatarMedium: CGFloat = 36
        static let avatarLarge: CGFloat = 52
        static let avatarSymbolScale: CGFloat = 0.42
        static let avatarInitialsScale: CGFloat = 0.38

        static let appIcon: CGFloat = 22
        static let featureIcon: CGFloat = 24
        /// Icon on a rounded sunken tile.
        static let iconTileSmall: CGFloat = 28
        static let iconTile: CGFloat = 30
        static let playButton: CGFloat = 30
        static let dateBadge: CGFloat = 38
        static let emptyStateIconTile: CGFloat = 56
        static let bannerIconWidth: CGFloat = 18
        static let buttonHeightSmall: CGFloat = 24
        static let buttonHeight: CGFloat = 28
        static let buttonHeightLarge: CGFloat = 36
        static let levelMeterHeight: CGFloat = 8
        static let tabIconMinWidth: CGFloat = 28
        static let tabUnderline: CGFloat = 2
    }

    // MARK: Strokes
    enum Stroke {
        static let emphasis: CGFloat = 2
        static let dropTarget = StrokeStyle(lineWidth: emphasis, dash: [6])
        static let recordingHalo: CGFloat = 3
    }

    // MARK: Opacity
    enum Opacity {
        static let disabled: Double = 0.5
        static let disabledButton: Double = 0.45
        static let pressedFill: Double = 0.88
        static let pillFill: Double = 0.12
        static let bannerFill: Double = 0.08
        static let bannerBorder: Double = 0.22
        static let destructiveFill: Double = 0.08
        static let destructivePressedFill: Double = 0.14
        static let avatarFill: Double = 0.16
        static let recordingHalo: Double = 0.4
    }

    enum Scale {
        static let pressed: CGFloat = 0.98
        static let recordingPulse: CGFloat = 1.9
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
        static let dateBadgeMonth = SwiftUI.Font.system(size: 9, weight: .semibold)
        static let dateBadgeDay = SwiftUI.Font.system(size: 15, weight: .semibold, design: .rounded)
        /// Play/pause glyph of the transport bar.
        static let transportIcon = SwiftUI.Font.system(size: 13, weight: .semibold)
        /// Leading icon of a sheet header.
        static let headerIcon = SwiftUI.Font.system(size: 24)
        static let heroIcon = SwiftUI.Font.system(size: 40)
        static let pillIcon = SwiftUI.Font.system(size: 9, weight: .bold)
        static let emptyStateIcon = SwiftUI.Font.system(size: 28, weight: .light)
        static let bannerIcon = SwiftUI.Font.system(size: 14, weight: .semibold)
        static let iconButton = SwiftUI.Font.system(size: 13, weight: .medium)
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

        /// Background of a transcript row that contains a search match.
        static let searchMatch: SwiftUI.Color = warning.opacity(0.08)
        /// Background of the matched text itself.
        static let searchMatchHighlight: SwiftUI.Color = warning.opacity(0.3)
        /// Vertical rule beside an evidence quote.
        static let evidenceRule: SwiftUI.Color = accent.opacity(0.5)

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
        static let meterLevel = Animation.linear(duration: 0.08)
    }
}

extension View {
    func elevation(_ level: DS.Elevation) -> some View {
        shadow(color: .black.opacity(level.shadowOpacity), radius: level.shadowRadius, x: 0, y: level.shadowY)
    }
}
