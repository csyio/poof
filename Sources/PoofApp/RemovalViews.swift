import AppKit
import PoofCore
import SwiftUI

/// The files Poof found for one app, and the button that moves them to quarantine.
struct AppDetailView: View {
    @Environment(AppModel.self) private var model
    let app: AppBundle
    @State private var plan: [Remover.PlannedItem]?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.displayName).font(.title2.bold())
                    Text(app.bundleID).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    if let team = app.teamID {
                        Text("Team \(team)").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                Spacer()
            }
            .padding(20)
            Divider()

            if let plan {
                RemovalList(
                    plan: plan,
                    preselected: Set(plan.filter { $0.action == .move }.map(\.id)),
                    name: app.displayName,
                    bundleID: app.bundleID,
                    blockedReason: model.isRunning(app) ? "\(app.displayName) is running. Quit it to remove it." : nil,
                    onFinished: { await rescan() }
                )
            } else {
                ProgressView("Looking for \(app.displayName)'s files…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await rescan() }
    }

    private func rescan() async {
        if FileManager.default.fileExists(atPath: app.url.path) {
            plan = await model.plan(for: app)
        } else {
            plan = []
        }
    }
}

/// Files left by apps that are already gone.
struct OrphansView: View {
    @Environment(AppModel.self) private var model
    @State private var plan: [Remover.PlannedItem]?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Leftovers").font(.title2.bold())
                    Text("Files from apps that are no longer installed.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await rescan() }
                } label: {
                    Label("Scan Again", systemImage: "arrow.clockwise")
                }
                .disabled(plan == nil)
            }
            .padding(20)
            Divider()

            if let plan {
                if plan.isEmpty {
                    ContentUnavailableView("No leftovers found", systemImage: "checkmark.seal",
                                           description: Text("Every file Poof checked belongs to an installed app."))
                } else {
                    RemovalList(
                        plan: plan,
                        // Only items Poof is sure about start checked.
                        preselected: Set(plan.filter { $0.action == .move && $0.item.isCertain }.map(\.id)),
                        name: "Leftovers",
                        bundleID: nil,
                        blockedReason: nil,
                        onFinished: { await rescan() }
                    )
                }
            } else {
                ProgressView("Scanning…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await rescan() }
    }

    private func rescan() async {
        plan = nil
        plan = await model.planOrphans()
    }
}

/// Checkable list of planned items with a footer that runs the removal.
struct RemovalList: View {
    @Environment(AppModel.self) private var model
    let plan: [Remover.PlannedItem]
    let name: String
    let bundleID: String?
    let blockedReason: String?
    let onFinished: () async -> Void

    @State private var selected: Set<String>
    @State private var confirming = false
    @State private var working = false
    @State private var result: RemovalResult?

    init(plan: [Remover.PlannedItem], preselected: Set<String>, name: String, bundleID: String?,
         blockedReason: String?, onFinished: @escaping () async -> Void) {
        self.plan = plan
        self.name = name
        self.bundleID = bundleID
        self.blockedReason = blockedReason
        self.onFinished = onFinished
        _selected = State(initialValue: preselected)
    }

    private var movable: [Remover.PlannedItem] { plan.filter { $0.action == .move } }
    private var kept: [Remover.PlannedItem] { plan.filter { $0.action != .move } }
    private var chosen: [Remover.PlannedItem] { movable.filter { selected.contains($0.id) } }

    var body: some View {
        VStack(spacing: 0) {
            if let result {
                ResultBanner(result: result) { self.result = nil }
            }
            List {
                let certain = movable.filter(\.item.isCertain)
                let unsure = movable.filter { !$0.item.isCertain }
                if !certain.isEmpty {
                    Section(unsure.isEmpty ? "Files" : "Left by removed apps") {
                        ForEach(certain) { row($0) }
                    }
                }
                if !unsure.isEmpty {
                    Section {
                        ForEach(unsure) { row($0) }
                    } header: {
                        Text("Check before removing")
                    } footer: {
                        Text("A command-line tool or library may have created these, or the vendor still has apps installed.")
                    }
                }
                if !kept.isEmpty {
                    Section("Kept") {
                        ForEach(kept) { row($0) }
                    }
                }
            }
            .listStyle(.inset)

            Divider()
            HStack(spacing: 12) {
                if let blockedReason {
                    Label(blockedReason, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(chosen.count) of \(movable.count) selected, \(formatSize(chosen.reduce(0) { $0 + $1.item.size }))")
                        .foregroundStyle(.secondary)
                    if chosen.contains(where: \.item.isSystem) {
                        Label("Needs your password", systemImage: "lock")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button("Move to Quarantine", role: .destructive) { confirming = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(chosen.isEmpty || working || blockedReason != nil)
            }
            .padding(12)
        }
        .sheet(isPresented: $confirming) {
            ConfirmRemovalSheet(items: chosen, name: name) {
                confirming = false
                Task { await run() }
            }
        }
    }

    private func row(_ planned: Remover.PlannedItem) -> some View {
        ItemRow(
            planned: planned,
            isOn: Binding(
                get: { selected.contains(planned.id) },
                set: { if $0 { selected.insert(planned.id) } else { selected.remove(planned.id) } }
            )
        )
    }

    private func run() async {
        working = true
        let items = chosen
        result = await model.remove(items, name: name, bundleID: bundleID)
        working = false
        await onFinished()
    }
}

struct ItemRow: View {
    let planned: Remover.PlannedItem
    @Binding var isOn: Bool

    private var item: Leftover { planned.item }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: $isOn)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(planned.action != .move)
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable()
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(abbreviate(item.url.path))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(item.url.path)
                HStack(spacing: 6) {
                    Text(item.reason.rawValue)
                    if let detail = item.detail { Text("· \(detail)").lineLimit(1) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if case .skip(let reason) = planned.action {
                    Label(reason, systemImage: "hand.raised")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if !planned.sensitiveFiles.isEmpty {
                    Label("Contains \(planned.sensitiveFiles.prefix(3).map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Spacer()
            if item.isSystem {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.secondary)
                    .help("In a system folder: needs your password")
            }
            Text(formatSize(item.size))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .opacity(planned.action == .move ? 1 : 0.6)
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.url.path, forType: .string)
            }
        }
    }
}

struct ConfirmRemovalSheet: View {
    let items: [Remover.PlannedItem]
    let name: String
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var acknowledged = false

    private var sensitive: [Remover.PlannedItem] { items.filter { !$0.sensitiveFiles.isEmpty } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Move \(items.count) items to quarantine?").font(.title3.bold())
            Text("\(formatSize(items.reduce(0) { $0 + $1.item.size })) from \(name). Nothing is deleted: you can put everything back from Quarantine until you delete it there.")
                .fixedSize(horizontal: false, vertical: true)
            if !sensitive.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Personal data", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline)
                        .foregroundStyle(.red)
                    Text("These items contain saved passwords, bookmarks, cookies or keys. Export anything you need before you delete them from Quarantine.")
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(sensitive) { planned in
                        Text(abbreviate(planned.item.url.path)).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                    }
                    Toggle("I understand this includes personal data", isOn: $acknowledged)
                }
                .padding(10)
                .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            if items.contains(where: \.item.isSystem) {
                Label("macOS will ask for your password to move files from system folders.", systemImage: "lock")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Move to Quarantine", role: .destructive, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!sensitive.isEmpty && !acknowledged)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

struct ResultBanner: View {
    @Environment(AppModel.self) private var model
    let result: RemovalResult
    let onDismiss: () -> Void
    @State private var undoErrors: [String]?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: result.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(result.failures.isEmpty ? .green : .orange)
                Text(summary)
                Spacer()
                if let id = result.sessionID, undoErrors == nil {
                    Button("Undo") {
                        Task { undoErrors = await model.restore(id) }
                    }
                }
                Button { onDismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
            }
            if result.cancelledAdmin {
                Text("Files in system folders were kept because the password prompt was cancelled.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(Array(result.failures.enumerated()), id: \.offset) { _, failure in
                Text("\(abbreviate(failure.path)): \(failure.reason)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            if let undoErrors {
                Text(undoErrors.isEmpty ? "Everything was put back." : "Some items could not be put back: \(undoErrors.joined(separator: "; "))")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.green.opacity(0.08))
        .overlay(alignment: .bottom) { Divider() }
    }

    private var summary: String {
        result.movedCount == 0 ? "Nothing was moved." : "Moved \(result.movedCount) items (\(formatSize(result.movedSize))) to quarantine."
    }
}

func formatSize(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

func abbreviate(_ path: String) -> String {
    let home = UserContext.home.path
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
}
