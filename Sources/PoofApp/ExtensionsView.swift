import AppKit
import PoofCore
import SwiftUI

/// Extensions installed in every browser profile on this Mac. Read-only: Poof lists them and
/// flags the ones worth a look, and the person removes them in the browser.
struct ExtensionsView: View {
    @State private var browsers: [BrowserInstall]?
    @State private var loading = false
    @State private var flaggedOnly = false

    var body: some View {
        VStack(spacing: 0) {
            SectionHeader(style: .extensions, stats: stats) {
                Toggle("Flagged only", isOn: $flaggedOnly).toggleStyle(.checkbox)
                Button {
                    Task { await load() }
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                .disabled(loading)
            }

            if let browsers {
                content(browsers)
            } else {
                LoadingState(text: "Reading browser profiles…")
            }
        }
        .task { if browsers == nil { await load() } }
    }

    private var stats: [Stat] {
        let all = browsers ?? []
        let ready = browsers != nil
        let count = all.reduce(0) { $0 + $1.extensionCount }
        let flagged = all.reduce(0) { $0 + $1.flaggedCount }
        let withExtensions = all.filter { $0.extensionCount > 0 }.count
        return [
            Stat(label: "Extensions", value: ready ? "\(count)" : "—", symbol: "puzzlepiece.extension.fill", tint: .teal),
            Stat(label: "Flagged", value: ready ? "\(flagged)" : "—", symbol: "flag.fill", tint: .orange),
            Stat(label: "Browsers", value: ready ? "\(withExtensions)" : "—", symbol: "globe", tint: .blue),
        ]
    }

    @ViewBuilder
    private func content(_ browsers: [BrowserInstall]) -> some View {
        let shown = browsers.filter { browser in
            // A note (an uninstalled browser's leftover extensions) shows even when nothing is
            // flagged, as `poof extensions --flagged` does.
            (browser.note != nil && (!flaggedOnly || !browser.isInstalled || browser.profiles.isEmpty))
                || browser.profiles.contains { !visible($0).isEmpty }
        }
        if shown.isEmpty {
            EmptyState(
                symbol: flaggedOnly ? "flag.slash" : "puzzlepiece.extension",
                title: flaggedOnly ? "Nothing flagged" : "No extensions found",
                caption: flaggedOnly ? "None of your browser extensions has a flag." : "Poof found no extensions in Chrome, Edge, Brave, Arc, Vivaldi, Opera, Firefox or Safari.")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Space.xl) {
                    ForEach(shown) { browser in
                        VStack(alignment: .leading, spacing: Space.s) {
                            BrowserHeader(browser: browser)
                                .padding(.horizontal, Space.xs)
                            let profiles = browser.profiles.filter { !visible($0).isEmpty }
                            if !profiles.isEmpty {
                                VStack(alignment: .leading, spacing: 0) {
                                    ForEach(Array(profiles.enumerated()), id: \.element.id) { index, profile in
                                        if browser.family != .safari {
                                            Text(profile.name)
                                                .font(.subheadline.weight(.semibold))
                                                .foregroundStyle(.secondary)
                                                .padding(.horizontal, Space.m)
                                                .padding(.top, index == 0 ? Space.m : Space.l)
                                                .padding(.bottom, Space.xs)
                                        }
                                        let items = visible(profile)
                                        ForEach(Array(items.enumerated()), id: \.element.id) { itemIndex, item in
                                            if itemIndex > 0 { RowDivider(inset: 50) }
                                            ExtensionRow(item: item)
                                        }
                                    }
                                }
                                .card(padding: nil)
                            }
                            if let note = browser.note {
                                Text(note)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.horizontal, Space.xs)
                            }
                        }
                    }
                }
                .padding(Space.xl)
            }
        }
    }

    private func visible(_ profile: BrowserProfile) -> [BrowserExtension] {
        flaggedOnly ? profile.extensions.filter(\.isFlagged) : profile.extensions
    }

    private func load() async {
        loading = true
        defer { loading = false }
        browsers = await Task.detached { BrowserExtensionScanner().scan() }.value
    }
}

private struct BrowserHeader: View {
    let browser: BrowserInstall

    var body: some View {
        HStack(spacing: 8) {
            if let appPath = browser.appPath {
                FileIcon(path: appPath, size: 22)
            } else {
                IconTile(symbol: "globe", tint: .gray, size: 22)
            }
            Text(browser.name).font(.headline)
            if !browser.isInstalled {
                Badge("Not installed", tone: .caution)
            }
            Spacer()
            Text("\(browser.extensionCount) \(browser.extensionCount == 1 ? "extension" : "extensions")")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

private struct ExtensionRow: View {
    let item: BrowserExtension

    private var summary: String {
        var parts: [String] = []
        if item.state != .unknown { parts.append(item.state == .enabled ? "On" : "Off") }
        parts.append(item.providedBy.map { "Provided by \($0)" } ?? String(item.source.label.prefix(1)).uppercased() + item.source.label.dropFirst())
        parts.append(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: Space.m) {
            IconTile(symbol: "puzzlepiece.extension.fill", tint: item.state == .disabled ? .gray : .teal, size: 26)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.name).lineLimit(1)
                    if !item.version.isEmpty { Text(item.version).font(.caption).foregroundStyle(.secondary) }
                    if item.kind != "Extension" { Text(item.kind).font(.caption).foregroundStyle(.tertiary) }
                }
                Text(summary).font(.caption).foregroundStyle(.secondary)
                Text(item.extensionID).font(.caption2).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                // The browser-level note already says the browser is gone; do not repeat it per row.
                ForEach(item.shownFlags, id: \.message) { flag in
                    FlagLabel(text: flag.message, symbol: "flag.fill", tone: .caution)
                }
            }
            Spacer()
            if item.state == .disabled {
                Badge("Off")
            }
        }
        .opacity(item.state == .disabled ? 0.75 : 1)
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Reveal in Finder") { reveal() }
        }
    }

    /// Selects the extension, or its folder when the file is missing. Only ever selects in
    /// Finder: opening the path could launch an app, and the path comes from browser files.
    private func reveal() {
        let url = URL(fileURLWithPath: item.path)
        let target = FileManager.default.fileExists(atPath: url.path) ? url : url.deletingLastPathComponent()
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }
}
