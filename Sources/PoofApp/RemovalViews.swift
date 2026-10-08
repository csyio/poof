import AppKit
import PoofCore
import SwiftUI

/// The files Poof found for one app, and the button that moves them to quarantine.
struct AppDetailView: View {
    @Environment(AppModel.self) private var model
    let app: AppBundle
    @State private var plan: [Remover.PlannedItem]?

    /// Removal waits for the insight: it lists the helpers that count as the app running.
    private var blockedReason: String? {
        if model.isRunning(app) { return "\(app.displayName) is running. Quit it to remove it." }
        if model.isInstalled(app), !model.hasInsight(app) { return "Checking whether \(app.displayName) is running…" }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            if let plan {
                RemovalList(
                    plan: plan,
                    preselected: Set(plan.filter { $0.action == .move }.map(\.id)),
                    name: app.displayName,
                    bundleID: app.bundleID,
                    blockedReason: blockedReason,
                    onFinished: { await rescan() },
                    certainTitle: "Files",
                    header: AnyView(header)
                )
            } else {
                ScrollView {
                    header
                    HStack(spacing: Space.s) {
                        ProgressView().controlSize(.small)
                        Text("Looking for \(app.displayName)'s files…").foregroundStyle(.secondary)
                    }
                    .padding(Space.xl)
                }
            }
        }
        .task { await rescan() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            AppHero(app: app)
            AppInsightPanel(app: app)
                .padding(.horizontal, Space.xl)
                .padding(.bottom, Space.xs)
        }
    }

    private func rescan() async {
        if model.isInstalled(app) {
            plan = await model.plan(for: app)
        } else {
            plan = []
        }
    }
}

/// Icon, name, developer and the facts that matter at a glance.
struct AppHero: View {
    @Environment(AppModel.self) private var model
    let app: AppBundle

    private var insight: AppInsight? { model.insights[app.url.path] }

    var body: some View {
        HStack(alignment: .center, spacing: Space.l) {
            FileIcon(path: app.url.path, size: 64)
                .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(app.displayName)
                    .font(.title.weight(.bold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                HStack(spacing: Space.xs) {
                    if let insight {
                        Badge(insight.origin.label, symbol: insight.origin.symbol)
                        if let version = insight.signals.version {
                            Badge("Version \(version)")
                        }
                        if let size = insight.signals.size {
                            Badge(formatSize(size), symbol: "internaldrive")
                        }
                    }
                    // Checked live: the insight was gathered when the list loaded.
                    if model.isRunning(app) {
                        Badge("Running", symbol: "circle.fill", tone: .positive)
                    }
                }
                .padding(.top, Space.xxs)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.xl)
        .padding(.top, Space.xl)
        .padding(.bottom, Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            LinearGradient(colors: [tint.opacity(0.13), tint.opacity(0.0)], startPoint: .top, endPoint: .bottom)
        }
    }

    private var tint: Color { insight.map { $0.verdict.tone.solid } ?? .gray }

    /// "Developer · com.example.app · Team ABCDE12345"
    private var subtitle: String {
        var parts: [String] = []
        if let vendor = insight?.vendor { parts.append(vendor) }
        parts.append(app.bundleID)
        if let team = app.teamID { parts.append("Team \(team)") }
        return parts.joined(separator: " · ")
    }
}

/// Files left by apps that are already gone.
struct OrphansView: View {
    @Environment(AppModel.self) private var model
    @State private var plan: [Remover.PlannedItem]?

    var body: some View {
        VStack(spacing: 0) {
            SectionHeader(style: .leftovers, stats: PlanStats.tiles(plan)) {
                Button {
                    Task { await rescan() }
                } label: {
                    Label("Scan Again", systemImage: "arrow.clockwise")
                }
                .disabled(plan == nil)
            }

            if let plan {
                if plan.isEmpty {
                    EmptyState(symbol: "checkmark.seal.fill", title: "No leftovers found",
                               caption: "Every file Poof checked belongs to an installed app.")
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
                LoadingState(text: "Scanning…")
            }
        }
        .task { await rescan() }
    }

    private func rescan() async {
        plan = nil
        plan = await model.planOrphans()
    }
}

/// Caches and build output of developer tools.
struct DeveloperView: View {
    @Environment(AppModel.self) private var model
    @State private var plan: [Remover.PlannedItem]?
    @State private var projects: URL?

    var body: some View {
        VStack(spacing: 0) {
            SectionHeader(
                style: .developer,
                description: projects.map { "Caches, build output, and idle projects in \(abbreviate($0.path))." },
                stats: PlanStats.tiles(plan, unsureLabel: "Review first", showSensitive: false)
            ) {
                Button("Choose Projects Folder…") { chooseProjects() }
                Button {
                    Task { await rescan() }
                } label: {
                    Label("Scan Again", systemImage: "arrow.clockwise")
                }
                .disabled(plan == nil)
            }

            if let plan {
                if plan.isEmpty {
                    EmptyState(symbol: "checkmark.seal.fill", title: "Nothing to clean",
                               caption: "No caches or build output worth removing right now.")
                } else {
                    RemovalList(
                        plan: plan,
                        preselected: Set(plan.filter { $0.action == .move && $0.item.isCertain }.map(\.id)),
                        name: "Developer files",
                        bundleID: nil,
                        blockedReason: nil,
                        onFinished: { await rescan() },
                        certainTitle: "Caches and build output of deleted projects",
                        unsureTitle: "Review first",
                        unsureFooter: "Build output of existing projects (their next build starts from scratch), archives, and build folders of projects untouched for 30 days."
                    )
                }
            } else {
                LoadingState(text: "Measuring developer caches…")
            }
        }
        .task { await rescan() }
    }

    private func rescan() async {
        plan = nil
        plan = await model.planDeveloper(projects: projects)
    }

    private func chooseProjects() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Scan Projects"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        projects = url
        Task { await rescan() }
    }
}

/// Header tiles for a removal plan: what could be freed and what needs a closer look.
enum PlanStats {
    static func tiles(_ plan: [Remover.PlannedItem]?, unsureLabel: String = "Check first", showSensitive: Bool = true) -> [Stat] {
        let movable = plan?.filter { $0.action == .move }
        let size = movable.map { tileSize($0.reduce(0) { $0 + $1.item.size }) } ?? "—"
        let count = movable.map { "\($0.count)" } ?? "—"
        let unsure = movable.map { "\($0.filter { !$0.item.isCertain }.count)" } ?? "—"
        let sensitive = movable.map { "\($0.filter { !$0.sensitiveFiles.isEmpty }.count)" } ?? "—"
        var tiles = [
            Stat(label: "Can be freed", value: size, symbol: "externaldrive.fill", tint: Brand.accent),
            Stat(label: "Items found", value: count, symbol: "doc.on.doc.fill", tint: .blue),
            Stat(label: unsureLabel, value: unsure, symbol: "eye.fill", tint: .orange),
        ]
        if showSensitive {
            tiles.append(Stat(label: "Personal data", value: sensitive, symbol: "exclamationmark.lock.fill", tint: .red))
        }
        return tiles
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
    let certainTitle: String
    let unsureTitle: String
    let unsureFooter: String
    /// Scrolls with the list, above the groups.
    let header: AnyView?

    @State private var selected: Set<String>
    @State private var confirming = false
    @State private var working = false
    @State private var result: RemovalResult?

    init(plan: [Remover.PlannedItem], preselected: Set<String>, name: String, bundleID: String?,
         blockedReason: String?, onFinished: @escaping () async -> Void,
         certainTitle: String = "Left by removed apps",
         unsureTitle: String = "Check before removing",
         unsureFooter: String = "A command-line tool or library may have created these, or the vendor still has apps installed.",
         header: AnyView? = nil) {
        self.plan = plan
        self.name = name
        self.bundleID = bundleID
        self.blockedReason = blockedReason
        self.onFinished = onFinished
        self.certainTitle = certainTitle
        self.unsureTitle = unsureTitle
        self.unsureFooter = unsureFooter
        self.header = header
        _selected = State(initialValue: preselected)
    }

    private var movable: [Remover.PlannedItem] { plan.filter { $0.action == .move } }
    private var kept: [Remover.PlannedItem] { plan.filter { $0.action != .move } }
    private var chosen: [Remover.PlannedItem] { movable.filter { selected.contains($0.id) } }

    var body: some View {
        VStack(spacing: 0) {
            if let result {
                // Undo puts the files back: scan again so the list shows them.
                ResultBanner(result: result, onDismiss: { self.result = nil }, onRestored: onFinished)
                    .padding([.horizontal, .top], Space.m)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let header { header }
                    VStack(alignment: .leading, spacing: Space.xl) {
                        let certain = movable.filter(\.item.isCertain)
                        let unsure = movable.filter { !$0.item.isCertain }
                        if plan.isEmpty {
                            Label("Poof found no files for this app.", systemImage: "checkmark.circle")
                                .foregroundStyle(.secondary)
                                .card()
                        }
                        if !certain.isEmpty {
                            group(certainTitle, items: certain)
                        }
                        if !unsure.isEmpty {
                            group(unsureTitle, items: unsure, footer: unsureFooter)
                        }
                        if !kept.isEmpty {
                            group("Kept", items: kept)
                        }
                    }
                    .padding(Space.xl)
                }
            }

            footer
        }
        .sheet(isPresented: $confirming) {
            ConfirmRemovalSheet(items: chosen, name: name) {
                confirming = false
                Task { await run() }
            }
        }
    }

    private func group(_ title: String, items: [Remover.PlannedItem], footer: String? = nil) -> some View {
        GroupCard(title: title, footer: footer) {
            Text("\(items.count) \(items.count == 1 ? "item" : "items") · \(formatSize(items.reduce(0) { $0 + $1.item.size }))")
                .monospacedDigit()
        } content: {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, planned in
                if index > 0 { RowDivider(inset: 74) }
                row(planned)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: Space.m) {
            if let blockedReason {
                Label(blockedReason, systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout.weight(.medium))
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(chosen.count) of \(movable.count) selected")
                        .font(.callout.weight(.semibold))
                    Text(formatSize(chosen.reduce(0) { $0 + $1.item.size }))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if chosen.contains(where: \.item.isSystem) {
                    Badge("Needs your password", symbol: "lock.fill")
                }
            }
            Spacer()
            if working {
                ProgressView().controlSize(.small)
                Text("Moving to Quarantine…").font(.callout).foregroundStyle(.secondary)
            }
            Button(role: .destructive) {
                confirming = true
            } label: {
                Label("Move to Quarantine…", systemImage: "archivebox")
            }
            .buttonStyle(.borderedProminent)
            .tint(Brand.accent)
            .controlSize(.large)
            .disabled(chosen.isEmpty || working || blockedReason != nil)
        }
        .padding(.horizontal, Space.xl)
        .padding(.vertical, Space.m)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
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

/// A sentence with an icon on a tinted background; wraps, unlike `Badge`.
struct FlagLabel: View {
    let text: String
    let symbol: String
    let tone: Tone

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
            Image(systemName: symbol).imageScale(.small)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(tone.color)
        .padding(.horizontal, Space.s)
        .padding(.vertical, 3)
        .background(tone.fill, in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
    }
}

struct ItemRow: View {
    let planned: Remover.PlannedItem
    @Binding var isOn: Bool

    private var item: Leftover { planned.item }

    var body: some View {
        HStack(alignment: .center, spacing: Space.m) {
            Toggle("", isOn: $isOn)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(planned.action != .move)
            FileIcon(path: item.url.path, size: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(abbreviate(item.url.path))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(item.url.path)
                Text(item.detail.map { "\(item.reason.rawValue) · \($0)" } ?? item.reason.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(item.detail ?? item.reason.rawValue)
                if case .skip(let reason) = planned.action {
                    FlagLabel(text: reason, symbol: "hand.raised.fill", tone: .neutral)
                }
                if !planned.sensitiveFiles.isEmpty {
                    FlagLabel(text: "Contains \(Array(Set(planned.sensitiveFiles.map { ($0 as NSString).lastPathComponent })).sorted().prefix(3).joined(separator: ", "))",
                              symbol: "exclamationmark.triangle.fill", tone: .danger)
                }
            }
            Spacer(minLength: Space.s)
            if item.isSystem {
                Badge("Admin", symbol: "lock.fill")
                    .help("In a system folder: needs your password")
            }
            Text(formatSize(item.size))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 64, alignment: .trailing)
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s)
        .opacity(planned.action == .move ? 1 : 0.65)
        .contentShape(Rectangle())
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
        VStack(alignment: .leading, spacing: Space.l) {
            HStack(alignment: .top, spacing: Space.m) {
                IconTile(symbol: "archivebox.fill", fill: Brand.gradient, size: 44)
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("Move \(items.count) items to quarantine?").font(.title3.bold())
                    Text("\(formatSize(items.reduce(0) { $0 + $1.item.size })) from \(name). Nothing is deleted: you can put everything back from Quarantine until you delete it there.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !sensitive.isEmpty {
                VStack(alignment: .leading, spacing: Space.s) {
                    Label("Personal data", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline)
                        .foregroundStyle(.red)
                    Text("These items contain saved passwords, bookmarks, cookies or keys. Export anything you need before you delete them from Quarantine.")
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(sensitive) { planned in
                            Text(abbreviate(planned.item.url.path)).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .padding(Space.s)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: Radius.small))
                    Toggle("I understand this includes personal data", isOn: $acknowledged)
                }
                .padding(Space.m)
                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                        .strokeBorder(Color.red.opacity(0.3), lineWidth: 0.5)
                }
            }
            if items.contains(where: \.item.isSystem) {
                Label("macOS will ask for your password to move files from system folders.", systemImage: "lock.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)
                Button("Move to Quarantine", role: .destructive, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.large)
                    .disabled(!sensitive.isEmpty && !acknowledged)
            }
        }
        .padding(Space.xl + Space.xs)
        .frame(width: 480)
    }
}

struct ResultBanner: View {
    @Environment(AppModel.self) private var model
    let result: RemovalResult
    let onDismiss: () -> Void
    /// Runs after Undo put the items back, so the screen can scan again.
    var onRestored: () async -> Void = {}
    @State private var undoErrors: [String]?

    private var tone: Tone { result.failures.isEmpty && !result.cancelledAdmin ? .positive : .caution }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.m) {
                IconTile(symbol: result.failures.isEmpty ? "checkmark" : "exclamationmark.triangle.fill",
                         tint: tone.solid, size: 30)
                VStack(alignment: .leading, spacing: 0) {
                    Text(summary).font(.headline)
                    if result.sessionID != nil, undoErrors == nil {
                        Text("Everything stays in Quarantine until you delete it there.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let id = result.sessionID, undoErrors == nil {
                    Button {
                        Task {
                            undoErrors = await model.restore(id)
                            await onRestored()
                        }
                    } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                    }
                }
                Button { onDismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Dismiss")
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
        .padding(Space.m)
        .background(tone.color.opacity(0.10), in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                .strokeBorder(tone.color.opacity(0.28), lineWidth: 0.5)
        }
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
