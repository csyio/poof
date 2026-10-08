import AppKit
import Observation
import PoofCore

enum SidebarItem: Hashable {
    case appsOverview
    case orphans
    case developer
    case loginItems
    case extensions
    case quarantine
    case app(String)  // bundle path
}

/// What a finished removal reports back to the screen that started it.
struct RemovalResult: Sendable {
    let sessionID: String?
    let movedCount: Int
    let movedSize: Int64
    let failures: [(path: String, reason: String)]
    let cancelledAdmin: Bool
    /// Something was moved that can change the app list or other apps' verdicts: an app
    /// bundle, a launch agent or a launch daemon.
    var changedAppList = false
}

@MainActor
@Observable
final class AppModel {
    var apps: [AppBundle] = []
    var isLoadingApps = false
    var selection: SidebarItem? = .orphans
    var sessions: [Quarantine.Session] = []
    var hasFullDiskAccess = FullDiskAccess.isGranted
    /// Insights by app bundle path, computed once per app list load.
    var insights: [String: AppInsight] = [:]
    var isLoadingInsights = false
    var appsFilter = ""
    var appsSort = [KeyPathComparator(\InsightRow.idle, order: .reverse)]

    private let quarantine = Quarantine()
    private var insightsTask: Task<Void, Never>?
    /// Counts every insight gathering as it starts, a full load or one app's, so an older
    /// result never overwrites a newer one.
    @ObservationIgnored private var insightsSerial = 0
    /// When the newest full load started.
    @ObservationIgnored private var latestLoad = 0
    /// When each single-app inspection started, by app path.
    @ObservationIgnored private var insightStamps: [String: Int] = [:]
    /// Apps that were selected when a removal moved them, so their screen (and its Undo
    /// banner) stays open after the app list is reloaded without them.
    private var removedApps: [String: AppBundle] = [:]
    /// Apps dropped onto the window from outside the standard folders, kept in the list
    /// across reloads for as long as they exist.
    @ObservationIgnored private var openedApps: [AppBundle] = []

    func app(at path: String) -> AppBundle? {
        apps.first { $0.url.path == path } ?? removedApps[path]
    }

    func loadApps() async {
        #if DEBUG
        if DemoData.isEnabled {
            apps = DemoData.apps
            insights = DemoData.insights()
            hasFullDiskAccess = true
            return
        }
        #endif
        isLoadingApps = true
        let opened = openedApps
        let (installed, kept) = await Task.detached { () -> ([AppBundle], [AppBundle]) in
            let installed = AppBundle.installedApps()
            let listed = Set(installed.map(\.url.path))
            let kept = opened.filter { !listed.contains($0.url.path) && FileManager.default.fileExists(atPath: $0.url.path) }
            return (installed, kept)
        }.value
        openedApps = kept
        apps = installed + kept
        // An app put back (Undo) is listed again: its screen follows the installed copy.
        let listed = Set(apps.map(\.url.path))
        removedApps = removedApps.filter { !listed.contains($0.key) }
        isLoadingApps = false
        insightsTask = Task { await loadInsights() }
    }

    /// Gathers every app's insight in the background. A newer load wins over an older one.
    func loadInsights() async {
        #if DEBUG
        if DemoData.isEnabled { insights = DemoData.insights(); return }
        #endif
        insightsSerial += 1
        let started = insightsSerial
        latestLoad = started
        let apps = apps
        isLoadingInsights = true
        let results = await Task.detached(priority: .utility) { AppInsight.inspectAll(apps) }.value
        guard started == latestLoad else { return }
        var fresh = Dictionary(results.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // An app inspected on its own after this load started (its files were just removed)
        // has the newer insight.
        for (path, stamp) in insightStamps where stamp > started {
            if let newer = insights[path] { fresh[path] = newer }
        }
        insightStamps = insightStamps.filter { $0.value > started }
        insights = fresh
        isLoadingInsights = false
    }

    /// The cached insight, waiting for a running load first; apps dropped onto the window
    /// are inspected on their own.
    func insight(for app: AppBundle) async -> AppInsight {
        if insights[app.url.path] == nil, isLoadingInsights { await insightsTask?.value }
        if let cached = insights[app.url.path] { return cached }
        // Stamped like any other inspection, so an older result never overwrites a newer load.
        await reinspect(app)
        if let cached = insights[app.url.path] { return cached }
        let installed = apps
        return await Task.detached(priority: .userInitiated) { AppInsight.inspect(app, installed: installed) }.value
    }

    /// Whether the insight, and with it the list of helpers that count as the app running, is known yet.
    func hasInsight(_ app: AppBundle) -> Bool {
        insights[app.url.path] != nil
    }

    func refreshSessions() {
        #if DEBUG
        if DemoData.isEnabled { sessions = []; return }
        #endif
        sessions = quarantine.sessions()
    }

    func refreshAccess() {
        #if DEBUG
        if DemoData.isEnabled { return }
        #endif
        hasFullDiskAccess = FullDiskAccess.isGranted
    }

    /// Selects an app dropped onto the window, adding it to the list if it lives elsewhere.
    func open(_ url: URL) {
        guard url.pathExtension == "app", let bundle = try? AppBundle(at: url) else { return }
        if !apps.contains(where: { $0.url.path == url.path }) {
            apps.append(bundle)
            openedApps.append(bundle)
        }
        selection = .app(url.path)
    }

    /// Whether the app is still on disk, so its files can be scanned.
    func isInstalled(_ app: AppBundle) -> Bool {
        #if DEBUG
        if DemoData.isEnabled { return true }
        #endif
        return FileManager.default.fileExists(atPath: app.url.path)
    }

    func plan(for app: AppBundle) async -> [Remover.PlannedItem] {
        #if DEBUG
        if DemoData.isEnabled { return DemoData.plan(for: app) }
        #endif
        return await Task.detached {
            Remover(canWriteSystem: true).plan(LeftoverScanner().scan(app))
        }.value
    }

    func planOrphans() async -> [Remover.PlannedItem] {
        await Task.detached {
            Remover(canWriteSystem: true).plan(OrphanScanner().scan())
        }.value
    }

    func planDeveloper(projects: URL?) async -> [Remover.PlannedItem] {
        await Task.detached {
            Remover(canWriteSystem: true).plan(DeveloperScanner().scan(projects: projects))
        }.value
    }

    /// Checked live, with the identifiers the insight found: the app, or an `.app` helper
    /// inside it that no other app ships, is running. Extensions macOS starts on its own do not count.
    func isRunning(_ app: AppBundle) -> Bool {
        #if DEBUG
        if DemoData.isEnabled { return insights[app.url.path]?.signals.isRunning ?? false }
        #endif
        // Found with the insight, off the main actor; until then only the app's own ID counts.
        let found = insights[app.url.path]?.signals.runningIdentifiers ?? []
        let ids = found.isEmpty ? [app.bundleID] : found
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return ids.contains(where: running.contains)
    }

    /// Whether moving the item can change the app list or another app's verdict.
    nonisolated static func changesAppList(_ item: Leftover) -> Bool {
        item.reason == .appBundle || item.url.pathExtension == "app"
            || ["LaunchAgents", "LaunchDaemons"].contains(item.url.deletingLastPathComponent().lastPathComponent)
    }

    /// Moves the chosen items into one quarantine session: the user's own files in-process,
    /// files in system folders through the bundled CLI behind macOS's administrator prompt.
    func remove(_ items: [Remover.PlannedItem], name: String, bundleID: String?) async -> RemovalResult {
        #if DEBUG
        // The demo's apps and files are made up: report a removal without touching the disk.
        if DemoData.isEnabled {
            return RemovalResult(sessionID: nil, movedCount: items.count, movedSize: items.reduce(0) { $0 + $1.item.size },
                                 failures: [], cancelledAdmin: false)
        }
        #endif
        let quarantine = quarantine
        let result = await Task.detached { () -> RemovalResult in
            let remover = Remover(quarantine: quarantine, canWriteSystem: true)
            guard var session = try? quarantine.begin(appName: name, bundleID: bundleID) else {
                return RemovalResult(sessionID: nil, movedCount: 0, movedSize: 0,
                                     failures: [("Quarantine", "Could not create the quarantine folder")], cancelledAdmin: false)
            }
            var failures: [(String, String)] = []
            let userItems = items.filter { !$0.item.isSystem }
            let adminItems = items.filter(\.item.isSystem)

            for (planned, outcome) in remover.move(userItems, into: &session) {
                if case .failed(let reason) = outcome { failures.append((planned.item.url.path, reason)) }
            }

            var cancelled = false
            if !adminItems.isEmpty {
                do {
                    let output = try PrivilegedRunner.run(["admin-move", "--session", session.id] + adminItems.map(\.item.url.path))
                    failures += PrivilegedRunner.failures(in: output)
                } catch PrivilegedRunner.Failure.cancelled {
                    cancelled = true
                } catch {
                    failures += adminItems.map { ($0.item.url.path, "\(error)") }
                }
                // The CLI wrote to the manifest; read it back.
                session = quarantine.session(session.id) ?? session
            }

            if session.entries.isEmpty { try? quarantine.purge(session.id) }
            let moved = Set(session.entries.map(\.originalPath))
            return RemovalResult(
                sessionID: session.entries.isEmpty ? nil : session.id,
                movedCount: session.entries.count,
                movedSize: session.totalSize,
                failures: failures,
                cancelledAdmin: cancelled,
                changedAppList: items.contains { moved.contains($0.item.url.path) && AppModel.changesAppList($0.item) }
            )
        }.value
        refreshSessions()
        if result.changedAppList {
            // An app or a launch agent gone can change the app list and other apps' verdicts
            // (background items, companions): reload both.
            if case .app(let path)? = selection, let current = app(at: path) { removedApps[path] = current }
            await loadApps()
        } else if result.movedCount > 0, let app = affectedApp(bundleID: bundleID) {
            // Only that app's own files went: look at it again, not at every app.
            await reinspect(app)
        }
        return result
    }

    /// Inspects one app again. Its result is dropped when a full load or another inspection
    /// of the app started after it, since that one saw the newer state.
    private func reinspect(_ app: AppBundle) async {
        insightsSerial += 1
        let stamp = insightsSerial
        let path = app.url.path
        insightStamps[path] = stamp
        let installed = apps
        let result = await Task.detached(priority: .userInitiated) { AppInsight.inspect(app, installed: installed) }.value
        guard insightStamps[path] == stamp, latestLoad < stamp else { return }
        insights[path] = result
    }

    /// The app a removal was about: the selected one, or the one with that bundle ID.
    private func affectedApp(bundleID: String?) -> AppBundle? {
        if case .app(let path)? = selection, let app = apps.first(where: { $0.url.path == path }),
           bundleID == nil || app.bundleID == bundleID {
            return app
        }
        return bundleID.flatMap { id in apps.first { $0.bundleID == id } }
    }

    func restore(_ id: String) async -> [String] {
        let quarantine = quarantine
        let errors = await Task.detached { () -> [String] in
            do {
                return try quarantine.restore(id).compactMap { entry, error in
                    error.map { "\(entry.originalPath): \($0)" }
                }
            } catch {
                return ["\(error)"]
            }
        }.value
        refreshSessions()
        await loadApps()
        return errors
    }

    /// Items moved from system folders belong to root, so deleting them may need the prompt.
    func purge(_ id: String) async -> String? {
        let quarantine = quarantine
        let error = await Task.detached { () -> String? in
            do {
                try quarantine.purge(id)
                return nil
            } catch {
                do {
                    _ = try PrivilegedRunner.run(["purge", id, "--yes"])
                    return nil
                } catch PrivilegedRunner.Failure.cancelled {
                    return "Some items came from system folders and need your password to delete."
                } catch {
                    return "\(error)"
                }
            }
        }.value
        refreshSessions()
        return error
    }
}

enum FullDiskAccess {
    /// Readable only with Full Disk Access. Opening it is the reliable test: TCC blocks
    /// the open, while `access()` can still say yes.
    static var isGranted: Bool {
        FileHandle(forReadingAtPath: "/Library/Application Support/com.apple.TCC/TCC.db") != nil
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Runs the bundled `poof` CLI as root after macOS asks for an administrator password.
enum PrivilegedRunner {
    enum Failure: Error, CustomStringConvertible {
        case cancelled
        case cliMissing
        case failed(String)

        var description: String {
            switch self {
            case .cancelled: "Cancelled"
            case .cliMissing: "The poof command-line tool is missing from the app bundle"
            case .failed(let message): message
            }
        }
    }

    /// Contents/Helpers/poof in the app bundle, or next to the app binary in a SwiftPM build.
    static var cliURL: URL? {
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/poof"),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("poof"),
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func run(_ arguments: [String]) throws -> String {
        guard let cli = cliURL else { throw Failure.cliMissing }
        // POOF_UID tells the CLI whose home and quarantine to use, since the
        // administrator prompt does not set SUDO_UID.
        let command = "POOF_UID=\(getuid()) " + ([cli.path] + arguments).map(shellQuote).joined(separator: " ")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        // Passing the command as an argument avoids escaping it inside AppleScript source.
        process.arguments = [
            "-e", "on run argv",
            "-e", "do shell script (item 1 of argv) with prompt (item 2 of argv) with administrator privileges",
            "-e", "end run",
            command, "Poof needs your password to move files from system folders.",
        ]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let stdout = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        if process.terminationStatus != 0 {
            if stderr.contains("(-128)") { throw Failure.cancelled }
            throw Failure.failed(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return stdout
    }

    /// Parses the "path<TAB>reason" lines admin-move prints for items it could not move.
    /// `do shell script` turns line endings into carriage returns, which `isNewline` covers.
    static func failures(in output: String) -> [(String, String)] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1)
            return parts.count == 2 ? (String(parts[0]), String(parts[1])) : nil
        }
    }

    static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
