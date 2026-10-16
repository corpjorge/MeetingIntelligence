import SwiftUI

enum Tone {
    case neutral, accent, success, warning, danger, recording, ai, info

    var color: Color {
        switch self {
        case .neutral: DS.Color.textSecondary
        case .accent: DS.Color.accent
        case .success: DS.Color.success
        case .warning: DS.Color.warning
        case .danger: DS.Color.danger
        case .recording: DS.Color.recording
        case .ai: DS.Color.ai
        case .info: DS.Color.info
        }
    }
}

struct StatusPill: View {
    let text: String
    var tone: Tone = .neutral
    var systemImage: String?

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 9, weight: .bold)) }
            Text(text).font(DS.Font.captionEmphasis)
        }
        .padding(.horizontal, DS.Space.s)
        .padding(.vertical, DS.Space.xxs + 1)
        .lineLimit(1)
        .fixedSize()
        .foregroundStyle(tone.color)
        .background(tone.color.opacity(0.12), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

struct EmptyStateView<Actions: View>: View {
    let systemImage: String
    let title: String
    let message: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: DS.Space.m) {
            Image(systemName: systemImage)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(DS.Color.textTertiary)
                .frame(width: 56, height: 56)
                .background(DS.Color.surfaceSunken, in: RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous))
            Text(title).font(DS.Font.headline).foregroundStyle(DS.Color.textPrimary)
            Text(message)
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            HStack(spacing: DS.Space.s) { actions }.padding(.top, DS.Space.xs)
        }
        .padding(DS.Space.xxl)
        .frame(maxWidth: .infinity)
    }
}

extension EmptyStateView where Actions == EmptyView {
    init(systemImage: String, title: String, message: String) {
        self.init(systemImage: systemImage, title: title, message: message) { EmptyView() }
    }
}

struct LoadingStateView: View {
    let message: String
    var progress: Double?

    var body: some View {
        VStack(spacing: DS.Space.m) {
            if let progress {
                ProgressView(value: progress).progressViewStyle(.linear).frame(maxWidth: 260)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(message).font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary)
        }
        .padding(DS.Space.xl)
        .frame(maxWidth: .infinity)
    }
}

struct InlineBanner<Action: View>: View {
    var tone: Tone = .info
    let systemImage: String
    let title: String
    var message: String?
    @ViewBuilder var action: Action

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tone.color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(title).font(DS.Font.bodyEmphasis).foregroundStyle(DS.Color.textPrimary)
                if let message {
                    Text(message).font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: DS.Space.s)
            action
        }
        .padding(DS.Space.m)
        .background(tone.color.opacity(0.08), in: RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
            .strokeBorder(tone.color.opacity(0.22), lineWidth: DS.Layout.hairline))
        .accessibilityElement(children: .combine)
    }
}

extension InlineBanner where Action == EmptyView {
    init(tone: Tone = .info, systemImage: String, title: String, message: String? = nil) {
        self.init(tone: tone, systemImage: systemImage, title: title, message: message) { EmptyView() }
    }
}
