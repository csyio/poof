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
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Login Items").font(.title2.bold())
                    Text("What starts at login or runs in the background. macOS removes these records when their app is gone.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
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
            .padding(20)
            Divider()

            if loading {
                ProgressView("Reading login items…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let items {
                list(items)
            } else {
                ContentUnavailableView {
                    Label("Login items need your password", systemImage: "lock")
                } description: {
                    Text(error ?? "macOS lets only administrators read this list. Poof reads it and changes nothing.")
                } actions: {
                    Button("Load Login Items") { Task { await load() } }
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    private func list(_ items: [LoginItem]) -> some View {
        let missing = items.filter { !$0.targetExists }
        let on = items.filter { $0.enabled && $0.targetExists }
        let off = items.filter { !$0.enabled && $0.targetExists }
        return List {
            if !missing.isEmpty {
                Section {
                    ForEach(missing, id: \.identifier) { LoginItemRow(item: $0) }
                } header: {
                    Text("Points at a file that no longer exists")
                } footer: {
                    Text("Poof's Leftovers section can remove the launch agents and daemons behind these.")
                }
            }
            Section("On") { ForEach(sorted(on), id: \.identifier) { LoginItemRow(item: $0) } }
            Section("Off") { ForEach(sorted(off), id: \.identifier) { LoginItemRow(item: $0) } }
        }
        .listStyle(.inset)
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
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: target ?? "/System/Applications/Utilities/Terminal.app"))
                .resizable()
                .frame(width: 22, height: 22)
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
                Label("Missing", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            if let target, item.targetExists {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: target)]) }
            }
        }
    }
}
