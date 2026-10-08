import AppKit
import PoofCore
import SwiftUI

/// A System Settings style rounded square with a white symbol.
struct IconTile<Fill: ShapeStyle>: View {
    let symbol: String
    let fill: Fill
    var size: CGFloat = 22

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(fill)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.52, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .shadow(color: .black.opacity(0.12), radius: 0.5, y: 0.5)
            .accessibilityHidden(true)
    }
}

extension IconTile where Fill == AnyGradient {
    init(symbol: String, tint: Color, size: CGFloat = 22) {
        self.init(symbol: symbol, fill: tint.gradient, size: size)
    }
}

/// A word in a tinted capsule: verdicts, flags and warnings.
struct Badge: View {
    let text: String
    var symbol: String?
    var tone: Tone = .neutral
    var large = false

    init(_ text: String, symbol: String? = nil, tone: Tone = .neutral, large: Bool = false) {
        self.text = text
        self.symbol = symbol
        self.tone = tone
        self.large = large
    }

    var body: some View {
        HStack(spacing: large ? 5 : 3) {
            if let symbol {
                Image(systemName: symbol).imageScale(.small)
            }
            Text(text).lineLimit(1)
        }
        .font(large ? .callout.weight(.semibold) : .caption.weight(.medium))
        .padding(.horizontal, large ? 10 : 7)
        .padding(.vertical, large ? 4 : 2)
        .foregroundStyle(tone.color)
        .background(tone.fill, in: Capsule())
        .fixedSize()
    }
}

struct VerdictBadge: View {
    let verdict: Verdict
    var large = false

    var body: some View {
        Badge(verdict.title, symbol: large ? verdict.symbol : nil, tone: verdict.tone, large: large)
    }
}

/// A size for a stat tile: "0 KB" rather than the formatter's "Zero KB".
func tileSize(_ bytes: Int64) -> String {
    bytes == 0 ? "0 KB" : formatSize(bytes)
}

/// One number in a section header.
struct Stat: Identifiable {
    let label: String
    let value: String
    let symbol: String
    var tint: Color = .secondary

    var id: String { label }
}

struct StatTile: View {
    let stat: Stat

    var body: some View {
        HStack(spacing: Space.s) {
            Image(systemName: stat.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(stat.tint)
                .frame(width: 24, height: 24)
                .background(stat.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 0) {
                Text(stat.value)
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(stat.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.s + 2)
        .padding(.vertical, Space.xs + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(stat.tint.opacity(0.07), in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                .strokeBorder(stat.tint.opacity(0.18), lineWidth: 0.5)
        }
    }
}

/// Title, description, actions and stat tiles at the top of a section.
struct SectionHeader<Actions: View>: View {
    let style: SectionStyle
    var description: String?
    var stats: [Stat] = []
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(alignment: .top, spacing: Space.m) {
                IconTile(symbol: style.symbol, tint: style.tint, size: 36)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    HStack(alignment: .center, spacing: Space.s) {
                        Text(style.title)
                            .font(.title2.weight(.bold))
                            .lineLimit(1)
                            .layoutPriority(1)
                        Spacer(minLength: Space.s)
                        HStack(spacing: Space.s) { actions() }
                            .fixedSize()
                    }
                    Text(description ?? style.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            if !stats.isEmpty {
                HStack(spacing: Space.s) {
                    ForEach(stats) { StatTile(stat: $0) }
                }
            }
        }
        .padding(.horizontal, Space.xl)
        .padding(.top, Space.l)
        .padding(.bottom, Space.m + 2)
        .background {
            LinearGradient(colors: [style.tint.opacity(0.09), style.tint.opacity(0.0)], startPoint: .top, endPoint: .bottom)
        }
        .overlay(alignment: .bottom) { Divider() }
    }
}

extension SectionHeader where Actions == EmptyView {
    init(style: SectionStyle, description: String? = nil, stats: [Stat] = []) {
        self.init(style: style, description: description, stats: stats) { EmptyView() }
    }
}

/// Rounded, lightly filled container with a hairline border.
struct CardBackground: ViewModifier {
    var padding: CGFloat? = Space.m

    func body(content: Content) -> some View {
        content
            .padding(padding ?? 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5)
            }
    }
}

extension View {
    func card(padding: CGFloat? = Space.m) -> some View {
        modifier(CardBackground(padding: padding))
    }
}

/// A titled card holding rows, like a grouped section in System Settings.
struct GroupCard<Content: View, Trailing: View>: View {
    let title: String
    var footer: String?
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Spacer()
                trailing()
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Space.xs)
            LazyVStack(alignment: .leading, spacing: 0) {
                content()
            }
            .card(padding: nil)
            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Space.xs)
            }
        }
    }
}

extension GroupCard where Trailing == EmptyView {
    init(title: String, footer: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, footer: footer, trailing: { EmptyView() }, content: content)
    }
}

/// Hairline between rows of a card, inset past the row's icon.
struct RowDivider: View {
    var inset: CGFloat = 44

    var body: some View {
        Divider().padding(.leading, inset)
    }
}

/// Large symbol on the brand gradient, a title, one line, and an optional button.
struct EmptyState: View {
    let symbol: String
    let title: String
    var caption: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: Space.m) {
            ZStack {
                Circle()
                    .fill(Brand.gradient)
                    .opacity(0.14)
                    .frame(width: 92, height: 92)
                Circle()
                    .strokeBorder(Brand.gradient, lineWidth: 1)
                    .opacity(0.25)
                    .frame(width: 92, height: 92)
                Image(systemName: symbol)
                    .font(.system(size: 38, weight: .medium))
                    .foregroundStyle(Brand.gradient)
            }
            .padding(.bottom, Space.xs)
            Text(title)
                .font(.title3.weight(.semibold))
            if let caption {
                Text(caption)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.top, Space.xs)
            }
        }
        .padding(Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A spinner with a line of text, centred in the space it gets.
struct LoadingState: View {
    let text: String

    var body: some View {
        VStack(spacing: Space.m) {
            ProgressView()
            Text(text).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A tinted notice with an icon, text and buttons.
struct Banner<Actions: View>: View {
    let symbol: String
    let tone: Tone
    let title: String
    var message: String?
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(spacing: Space.m) {
            IconTile(symbol: symbol, tint: tone.solid, size: 30)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(title).font(.headline)
                if let message {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: Space.s)
            HStack(spacing: Space.s) { actions() }
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s + 2)
        .background(tone.color.opacity(0.10), in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                .strokeBorder(tone.color.opacity(0.28), lineWidth: 0.5)
        }
    }
}

/// The Finder icon of a file or app.
struct FileIcon: View {
    let path: String
    var size: CGFloat = 20

    var body: some View {
        #if DEBUG
        if let demo = DemoData.icon(for: path) {
            DemoIcon(spec: demo, size: size)
        } else {
            system
        }
        #else
        system
        #endif
    }

    private var system: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: path))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}
