import PoofCore
import SwiftUI

struct QuarantineView: View {
    @Environment(AppModel.self) private var model
    @State private var purging: Quarantine.Session?
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Quarantine").font(.title2.bold())
                    Text("Removed items wait here until you put them back or delete them.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Show in Finder") {
                    NSWorkspace.shared.open(Quarantine().root)
                }
                .disabled(model.sessions.isEmpty)
            }
            .padding(20)
            Divider()

            if let message {
                HStack {
                    Text(message)
                    Spacer()
                    Button { self.message = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                }
                .padding(12)
                .background(.orange.opacity(0.08))
            }

            if model.sessions.isEmpty {
                ContentUnavailableView("Quarantine is empty", systemImage: "archivebox",
                                       description: Text("Apps and files you remove with Poof appear here."))
                    .frame(maxHeight: .infinity)
            } else {
                List {
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
                .listStyle(.inset)
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
}

struct SessionRow: View {
    let session: Quarantine.Session
    let onRestore: () -> Void
    let onPurge: () -> Void
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(session.entries, id: \.storedName) { entry in
                HStack {
                    Text(abbreviate(entry.originalPath)).lineLimit(1).truncationMode(.middle).help(entry.originalPath)
                    Spacer()
                    Text(formatSize(entry.size)).monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.appName).font(.headline)
                    Text("\(session.entries.count) items, \(formatSize(session.totalSize)), removed \(session.date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Put Back", action: onRestore)
                Button("Delete…", role: .destructive, action: onPurge)
            }
        }
        .padding(.vertical, 4)
    }
}
