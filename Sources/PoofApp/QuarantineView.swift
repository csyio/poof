import PoofCore
import SwiftUI

struct QuarantineView: View {
    @Environment(AppModel.self) private var model
    @State private var purging: Quarantine.Session?
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            SectionHeader(style: .quarantine, stats: stats) {
                Button {
                    NSWorkspace.shared.open(Quarantine().root)
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                .disabled(model.sessions.isEmpty)
            }

            if let message {
                Banner(symbol: "info", tone: .caution, title: message) {
                    Button { self.message = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .help("Dismiss")
                }
                .padding([.horizontal, .top], Space.m)
            }

            if model.sessions.isEmpty {
                EmptyState(symbol: "archivebox", title: "Quarantine is empty",
                           caption: "Apps and files you remove with Poof appear here, so you can put them back.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Space.m) {
                        ForEach(model.sessions, id: \.id) { session in
                            SessionRow(session: session) {
                                Task {
                                    let errors = await model.restore(session.id)
                                    message = errors.isEmpty ? "\(session.appName) was put back." : errors.joined(separator: "\n")
                                }
                            } onPurge: {
                                purging = session
                            }
                        }
                    }
                    .padding(Space.xl)
                }
            }
        }
        .onAppear { model.refreshSessions() }
        .confirmationDialog(
            "Delete \(purging?.appName ?? "") permanently?",
            isPresented: Binding(get: { purging != nil }, set: { if !$0 { purging = nil } }),
            presenting: purging
        ) { session in
            Button("Delete \(formatSize(session.totalSize))", role: .destructive) {
                Task { message = await model.purge(session.id) }
            }
        } message: { _ in
            Text("This cannot be undone.")
        }
    }

    private var stats: [Stat] {
        let sessions = model.sessions
        return [
            Stat(label: "Removals", value: "\(sessions.count)", symbol: "archivebox.fill", tint: .gray),
            Stat(label: "Items", value: "\(sessions.reduce(0) { $0 + $1.entries.count })", symbol: "doc.on.doc.fill", tint: .blue),
            Stat(label: "Space used", value: tileSize(sessions.reduce(Int64(0)) { $0 + $1.totalSize }), symbol: "externaldrive.fill", tint: Brand.accent),
        ]
    }
}

struct SessionRow: View {
    let session: Quarantine.Session
    let onRestore: () -> Void
    let onPurge: () -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.m) {
                IconTile(symbol: "archivebox.fill", tint: .gray, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.appName).font(.headline)
                    Text("\(session.entries.count) items · \(formatSize(session.totalSize)) · removed \(session.date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                Button(action: onRestore) {
                    Label("Put Back", systemImage: "arrow.uturn.backward")
                }
                Button("Delete…", role: .destructive, action: onPurge)
            }
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(session.entries.enumerated()), id: \.element.storedName) { index, entry in
                        if index > 0 { Divider() }
                        HStack {
                            Text(abbreviate(entry.originalPath)).lineLimit(1).truncationMode(.middle).help(entry.originalPath)
                            Spacer()
                            Text(formatSize(entry.size)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .font(.callout)
                        .padding(.vertical, 5)
                    }
                }
                .padding(.top, Space.xs)
            } label: {
                Text(expanded ? "Hide items" : "Show items")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 44)
        }
        .card()
    }
}
