import AppKit
import Observation
import PoofCore

enum SidebarItem: Hashable {
    case orphans
    case developer
    case loginItems
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
}

@MainActor
@Observable
final class AppModel {
    var apps: [AppBundle] = []
    var isLoadingApps = false
    var selection: SidebarItem? = .orphans
    var sessions: [Quarantine.Session] = []
    var hasFullDiskAccess = FullDiskAccess.isGranted

    private let quarantine = Quarantine()

    func app(at path: String) -> AppBundle? {
        apps.first { $0.url.path == path }
    }

    func loadApps() async {
        isLoadingApps = true
        apps = await Task.detached { AppBundle.installedApps() }.value
        isLoadingApps = false
    }

    func refreshSessions() {
        sessions = quarantine.sessions()
    }

    func refreshAccess() {
        hasFullDiskAccess = FullDiskAccess.isGranted
    }

    /// Selects an app dropped onto the window, adding it to the list if it lives elsewhere.
    func open(_ url: URL) {
        guard url.pathExtension == "app", let bundle = try? AppBundle(at: url) else { return }
        if app(at: url.path) == nil { apps.append(bundle) }
        selection = .app(url.path)
    }

    func plan(for app: AppBundle) async -> [Remover.PlannedItem] {
        await Task.detached {
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

    func isRunning(_ app: AppBundle) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == app.bundleID }
    }

    /// Moves the chosen items into one quarantine session: the user's own files in-process,
    /// files in system folders through the bundled CLI behind macOS's administrator prompt.
    func remove(_ items: [Remover.PlannedItem], name: String, bundleID: String?) async -> RemovalResult {
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
            return RemovalResult(
                sessionID: session.entries.isEmpty ? nil : session.id,
                movedCount: session.entries.count,
                movedSize: session.totalSize,
                failures: failures,
                cancelledAdmin: cancelled
            )
        }.value
        refreshSessions()
        return result
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
