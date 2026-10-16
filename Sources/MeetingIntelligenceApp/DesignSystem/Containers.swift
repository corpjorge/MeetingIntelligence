import SwiftUI

/// Base surface: hairline border, continuous corners, optional elevation.
struct SurfaceCard<Content: View>: View {
    var padding: CGFloat = DS.Space.l
    var elevation: DS.Elevation = .flat
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Color.surface, in: RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                .strokeBorder(DS.Color.border, lineWidth: DS.Layout.hairline))
            .elevation(elevation)
    }
}

struct SectionHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.m) {
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(title).font(DS.Font.headline).foregroundStyle(DS.Color.textPrimary)
                if let subtitle {
                    Text(subtitle).font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary)
                }
            }
            Spacer(minLength: DS.Space.m)
            trailing
        }
        .accessibilityElement(children: .combine)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// Page scaffold shared by top-level screens: title block + scrollable content.
struct PageScaffold<Actions: View, Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var actions: Actions
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                HStack(alignment: .bottom, spacing: DS.Space.m) {
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        Text(title).font(DS.Font.display).foregroundStyle(DS.Color.textPrimary)
                        if let subtitle {
                            Text(subtitle).font(DS.Font.body).foregroundStyle(DS.Color.textSecondary)
                        }
                    }
                    Spacer()
                    HStack(spacing: DS.Space.s) { actions }
                }
                content
            }
            .padding(.horizontal, DS.Space.xxl)
            .padding(.vertical, DS.Space.xl)
            .frame(maxWidth: DS.Layout.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(DS.Color.background)
    }
}

/// Hover highlight for list rows.
struct HoverHighlight: ViewModifier {
    var isSelected = false
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                    .fill(isSelected ? DS.Color.selected : (hovering ? DS.Color.hover : .clear)))
            .onHover { hovering = $0 }
            .animation(DS.Motion.quick, value: hovering)
    }
}

extension View {
    func hoverHighlight(selected: Bool = false) -> some View { modifier(HoverHighlight(isSelected: selected)) }
}

struct KeyValueRow: View {
    let key: String
    let value: String
    var monospaced = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key).font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary)
            Spacer(minLength: DS.Space.l)
            Text(value)
                .font(monospaced ? DS.Font.mono : DS.Font.callout)
                .foregroundStyle(DS.Color.textPrimary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}

struct MetricTile: View {
    let title: String
    let value: String
    var caption: String?
    var systemImage: String?

    var body: some View {
        SurfaceCard(padding: DS.Space.l) {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                HStack(spacing: DS.Space.xs) {
                    if let systemImage { Image(systemName: systemImage).foregroundStyle(DS.Color.textTertiary) }
                    Text(title).font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary)
                }
                Text(value).font(DS.Font.metric).foregroundStyle(DS.Color.textPrimary)
                if let caption {
                    Text(caption).font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Underlined tab bar used inside detail screens.
struct DSTabBar<Tab: Hashable & Identifiable>: View {
    let tabs: [Tab]
    @Binding var selection: Tab
    let title: (Tab) -> String
    let icon: (Tab) -> String
    @Namespace private var underline

    var body: some View {
        // Full labels when they fit; otherwise icons only (titles stay in help + accessibility).
        ViewThatFits(in: .horizontal) {
            bar(.iconAndTitle)
            bar(.title)
            bar(.icon)
        }
        .overlay(alignment: .bottom) { Rectangle().fill(DS.Color.border).frame(height: DS.Layout.hairline) }
    }

    private enum Variant { case iconAndTitle, title, icon }

    private func bar(_ variant: Variant) -> some View {
        HStack(spacing: DS.Space.xs) {
            ForEach(tabs) { tab in
                let selected = tab == selection
                Button {
                    withAnimation(DS.Motion.standard) { selection = tab }
                } label: {
                    VStack(spacing: DS.Space.s) {
                        Group {
                            switch variant {
                            case .iconAndTitle:
                                HStack(spacing: DS.Space.xs + 1) {
                                    Image(systemName: icon(tab))
                                    Text(title(tab))
                                }
                            case .title: Text(title(tab))
                            case .icon: Image(systemName: icon(tab)).frame(minWidth: 28)
                            }
                        }
                            .font(DS.Font.bodyEmphasis)
                            .lineLimit(1)
                            .fixedSize()
                            .foregroundStyle(selected ? DS.Color.textPrimary : DS.Color.textSecondary)
                            .padding(.horizontal, variant == .icon ? DS.Space.s : DS.Space.xs + 2)
                            .padding(.top, DS.Space.xs)
                        ZStack {
                            Rectangle().fill(.clear).frame(height: 2)
                            if selected {
                                Capsule().fill(DS.Color.accent).frame(height: 2)
                                    .matchedGeometryEffect(id: "underline", in: underline)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(title(tab))
                .accessibilityLabel(title(tab))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
    }
}
