import AppKit
import PoofCore
import SwiftUI

/// Apps and helpers that start at login or run in the background. Read-only: macOS owns
/// these records, so the view only shows them and links to System Settings.
struct LoginItemsView: View {
    @State private var items: [LoginItem]?
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            SectionHeader(style: .loginItems, stats: stats) {
                Button("Open Login Items Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button {
                    Task { await load() }
                } label: {
                    Label(items == nil ? "Load…" : "Reload", systemImage: "arrow.clockwise")
                }
                .disabled(loading)
            }

            if loading {
                LoadingState(text: "Reading login items…")
            } else if let items {
                list(items)
            } else {
                EmptyState(
                    symbol: "lock.fill",
                    title: "Login items need your password",
                    caption: error ?? "macOS lets only administrators read this list. Poof reads it and changes nothing.",
                    actionTitle: "Load Login Items",
                    action: { Task { await load() } })
            }
        }
    }

    private var stats: [Stat] {
        guard let items else { return [] }
        let on = items.filter { $0.enabled && $0.targetExists }.count
        let off = items.filter { !$0.enabled && $0.targetExists }.count
        let missing = items.filter { !$0.targetExists }.count
        return [
            Stat(label: "Items", value: "\(items.count)", symbol: "list.bullet", tint: .green),
            Stat(label: "On", value: "\(on)", symbol: "power", tint: .blue),
            Stat(label: "Off", value: "\(off)", symbol: "pause.fill", tint: .gray),
            Stat(label: "Missing target", value: "\(missing)", symbol: "exclamationmark.triangle.fill", tint: .orange),
        ]
    }

    private func list(_ items: [LoginItem]) -> some View {
        let missing = items.filter { !$0.targetExists }
        let on = items.filter { $0.enabled && $0.targetExists }
        let off = items.filter { !$0.enabled && $0.targetExists }
        return ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                if !missing.isEmpty {
                    group("Points at a file that no longer exists", missing,
                          footer: "Poof's Leftovers section can remove the launch agents and daemons behind these.")
                }
                if !on.isEmpty { group("On", sorted(on)) }
                if !off.isEmpty { group("Off", sorted(off)) }
            }
            .padding(Space.xl)
        }
    }

    private func group(_ title: String, _ items: [LoginItem], footer: String? = nil) -> some View {
        GroupCard(title: title, footer: footer) {
            Text("\(items.count)").monospacedDigit()
        } content: {
            ForEach(Array(items.enumerated()), id: \.element.identifier) { index, item in
                if index > 0 { RowDivider(inset: 52) }
                LoginItemRow(item: item)
            }
        }
    }

    private func sorted(_ items: [LoginItem]) -> [LoginItem] {
        items.sorted { ($0.developer ?? "~", $0.name) < ($1.developer ?? "~", $1.name) }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        let result = await Task.detached { () -> Result<[LoginItem], Error> in
            Result {
                let output = try PrivilegedRunner.run(["login-items", "--json"])
                return try JSONDecoder().decode([LoginItem].self, from: Data(output.utf8))
            }
        }.value
        switch result {
        case .success(let loaded):
            items = loaded
            error = nil
        case .failure(PrivilegedRunner.Failure.cancelled):
            error = "The password prompt was cancelled."
        case .failure(let failure):
            error = "\(failure)"
        }
    }
}

struct LoginItemRow: View {
    let item: LoginItem

    private var target: String? { item.path ?? item.executablePath }

    var body: some View {
        HStack(spacing: Space.m) {
            FileIcon(path: target ?? "/System/Applications/Utilities/Terminal.app", size: 28)
                .opacity(item.targetExists ? 1 : 0.4)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).lineLimit(1)
                Text([item.type, item.developer].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                if let target {
                    Text(abbreviate(target)).font(.caption).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle).help(target)
                }
            }
            Spacer()
            if !item.targetExists {
                Badge("Missing", symbol: "exclamationmark.triangle.fill", tone: .caution)
            }
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s)
        .contentShape(Rectangle())
        .contextMenu {
            if let target, item.targetExists {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: target)]) }
            }
        }
    }
}
