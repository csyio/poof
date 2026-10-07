import AppKit
import ArgumentParser
import Foundation
import PoofCore

@main
struct Poof: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Remove macOS apps and everything they leave behind.",
        version: poofVersion,
        subcommands: [Scan.self, Orphans.self, Dev.self, LoginItems.self, Remove.self, Restore.self, Purge.self, AdminMove.self]
    )
}

struct Scan: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List an app's files without changing anything."
    )

    @Argument(help: "App name (e.g. \"chrome\") or path to a .app bundle.")
    var app: String

    func run() throws {
        let bundle = try findApp(app)
        print("\(bundle.name)  \(bundle.bundleID)  team: \(bundle.teamID ?? "unsigned")\n")
        let items = LeftoverScanner().scan(bundle)
        printItems(items)
        printTotal(items, suffix: "Nothing was removed.")
        if !UserContext.isRoot {
            print("Run with sudo to include login and background items.")
        }
    }
}

struct Orphans: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List files left by apps that are no longer installed. With --remove, quarantine them.",
        discussion: """
        --remove moves only the items Poof is sure about. Add --include-unsure to also move \
        preferences and caches that a command-line tool or library may have created.
        """
    )

    @Flag(help: "Move the orphaned files to quarantine. Undo with `poof restore`.")
    var remove = false

    @Flag(help: "With --remove, also move items Poof is not sure about.")
    var includeUnsure = false

    @OptionGroup var options: RemovalOptions

    func run() throws {
        let items = OrphanScanner().scan()
        let certain = items.filter(\.isCertain)
        let unsure = items.filter { !$0.isCertain }

        guard remove else {
            if !certain.isEmpty {
                print("Left by removed apps:\n")
                printItems(certain)
            }
            if !unsure.isEmpty {
                print("\(certain.isEmpty ? "" : "\n")Probably left by removed apps. Check these before removing,")
                print("a command-line tool or library may have created them:\n")
                printItems(unsure)
            }
            if items.isEmpty { print("No orphaned files found.") } else { printTotal(items, suffix: "Nothing was removed.") }
            return
        }

        let selected = includeUnsure ? items : certain
        if selected.isEmpty {
            print("No orphaned files to remove.")
            return
        }
        try performRemoval(of: selected, name: "Orphaned files", bundleID: nil, retry: "poof orphans --remove\(includeUnsure ? " --include-unsure" : "")", options: options)
        if !includeUnsure && !unsure.isEmpty {
            print("\n\(unsure.count) items Poof is not sure about were kept. Review them with `poof orphans`.")
        }
    }
}

struct Dev: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List caches and build output left by developer tools. With --remove, quarantine them.",
        discussion: """
        --remove moves caches and the build output of deleted projects. Add --include-review \
        for archives, toolchains and build folders of idle projects. Data a tool tracks itself \
        (simulators, Homebrew, Go) is never moved; Poof prints the tool's own command instead. \
        Quarantined items still use disk space until `poof purge`.
        """
    )

    @Option(help: "Also look for dependency and build folders (node_modules, .build, target...) in projects under this folder.")
    var projects: String?

    @Option(help: "With --projects, only report projects untouched for this many days.")
    var idleDays = 30

    @Flag(help: "Move the items to quarantine. Undo with `poof restore`.")
    var remove = false

    @Flag(help: "With --remove, also move items marked for review.")
    var includeReview = false

    @OptionGroup var options: RemovalOptions

    func run() throws {
        let root = projects.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        let items = DeveloperScanner().scan(projects: root, idleDays: idleDays)
        let commands = items.filter { $0.cleanupCommand != nil }
        let caches = items.filter { $0.cleanupCommand == nil && $0.isCertain }
        let review = items.filter { $0.cleanupCommand == nil && !$0.isCertain }

        guard remove else {
            for (title, group) in [("Caches and build output of deleted projects (safe to remove):", caches),
                                   ("Review first:", review)] where !group.isEmpty {
                print(title + "\n")
                printItems(group)
                print("")
            }
            if !commands.isEmpty {
                print("Clean with the tool's own command:\n")
                for item in commands {
                    print("\(format(item.size).padding(toLength: 10, withPad: " ", startingAt: 0)) \(item.detail ?? item.url.path)")
                    print("           \(item.cleanupCommand ?? "")")
                }
                print("")
            }
            if items.isEmpty { print("No developer leftovers found.") } else { printTotal(items, suffix: "Nothing was removed.") }
            return
        }

        let selected = caches + (includeReview ? review : [])
        guard !selected.isEmpty else {
            print("Nothing to remove.")
            return
        }
        try performRemoval(of: selected, name: "Developer files", bundleID: nil,
                           retry: "poof dev --remove\(includeReview ? " --include-review" : "")", options: options)
        print("Quarantined items still use disk space. Free it with `poof purge <session>` once you are sure.")
    }
}

struct LoginItems: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "login-items",
        abstract: "List apps and helpers that start at login or run in the background. Needs sudo.",
        discussion: """
        Reads macOS's background task database, which only root can read. Nothing is changed: \
        macOS drops records whose app is gone, and you turn items off in System Settings > \
        General > Login Items & Extensions.
        """
    )

    @Flag(help: "Include Spotlight, Quick Look and other plug-in records.")
    var all = false

    @Flag(help: "Print JSON (used by Poof.app).")
    var json = false

    @Option(help: .hidden)
    var from: String?

    func run() throws {
        let items: [LoginItem]
        do {
            if let from {
                items = LoginItem.parse(dump: try String(contentsOfFile: from, encoding: .utf8), uid: UserContext.uid)
            } else {
                items = try LoginItem.load()
            }
        } catch let error as LoginItem.Failure {
            throw ValidationError(error.description)
        }
        let shown = items.filter { all || $0.isUserFacing }

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            print(String(decoding: try encoder.encode(shown), as: UTF8.self))
            return
        }

        let missing = shown.filter { !$0.targetExists }
        let on = shown.filter { $0.enabled && $0.targetExists }
        let off = shown.filter { !$0.enabled && $0.targetExists }
        for (title, group) in [("Points at a file that no longer exists:", missing),
                               ("On:", on), ("Off:", off)] where !group.isEmpty {
            print(title + "\n")
            for item in group.sorted(by: { ($0.developer ?? "~", $0.name) < ($1.developer ?? "~", $1.name) }) {
                let developer = item.developer.map { " · \($0)" } ?? ""
                print("  \(item.name)  (\(item.type))\(developer)")
                if let path = item.executablePath ?? item.path { print("    \(path)") }
            }
            print("")
        }
        print("\(shown.count) items: \(on.count) on, \(off.count) off, \(missing.count) pointing at missing files.")
        print("Turn items off in System Settings > General > Login Items & Extensions.")
    }
}

struct RemovalOptions: ParsableArguments {
    @Flag(help: "Show what would happen without moving anything.")
    var dryRun = false

    @Flag(name: .shortAndLong, help: "Do not ask for confirmation.")
    var yes = false

    @Flag(help: "With --yes, also move items containing saved passwords, bookmarks or keys.")
    var allowSensitive = false
}

struct Remove: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Move an app and its files to Poof's quarantine. Undo with `poof restore`.",
        discussion: """
        Nothing is deleted: items are moved to ~/Library/Application Support/Poof/Quarantine \
        and stay there until `poof purge`. Files other apps also use, and system extensions, \
        are kept. Files in system folders need sudo.
        """
    )

    @Argument(help: "App name (e.g. \"chrome\") or path to a .app bundle.")
    var app: String

    @OptionGroup var options: RemovalOptions

    func run() throws {
        let bundle = try findApp(app)
        if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bundle.bundleID }) {
            throw ValidationError("\(bundle.name) is running. Quit it first.")
        }
        print("\(bundle.name)  \(bundle.bundleID)\n")
        try performRemoval(of: LeftoverScanner().scan(bundle), name: bundle.name, bundleID: bundle.bundleID,
                           retry: "poof remove \(shellQuote(app))", options: options)
    }
}

/// Shows the plan, asks for confirmation and moves the items into one quarantine session.
func performRemoval(of items: [Leftover], name: String, bundleID: String?, retry: String, options: RemovalOptions) throws {
    let remover = Remover()
    let plan = remover.plan(items)
    let moving = plan.filter { $0.action == .move }
    let keeping = plan.filter { $0.action != .move }
    let sensitive = moving.filter { !$0.sensitiveFiles.isEmpty }

    print("Move to quarantine:")
    printItems(moving.map(\.item))
    if !keeping.isEmpty {
        print("\nKeep:")
        for planned in keeping {
            if case .skip(let reason) = planned.action {
                print("  \(planned.item.url.path)\n    \(reason)")
            }
        }
    }
    if !sensitive.isEmpty {
        print("\n! These items contain personal data that is hard to get back once purged:")
        for planned in sensitive {
            print("  \(planned.item.url.path)")
            for file in planned.sensitiveFiles.prefix(5) { print("    \(file)") }
            if planned.sensitiveFiles.count > 5 { print("    and \(planned.sensitiveFiles.count - 5) more") }
        }
        print("  Export anything you need (for example passwords from the app's settings) before purging.")
    }
    let needsAdmin = keeping.contains { $0.action == Remover.needsAdminSkip }
    if needsAdmin {
        print("\nSome items need administrator rights. To remove everything at once, run:")
        print("  sudo \(retry)")
    }
    printTotal(moving.map(\.item), suffix: "Nothing has been moved yet.")

    if options.dryRun || moving.isEmpty { return }
    if options.yes {
        if !sensitive.isEmpty && !options.allowSensitive {
            throw ValidationError("Items contain personal data. Re-run with --allow-sensitive to move them anyway.")
        }
    } else {
        let question = sensitive.isEmpty ? "Move \(moving.count) items to quarantine? [y/N] " : "Type \"yes\" to move them, including personal data: "
        print("\n" + question, terminator: "")
        let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        guard sensitive.isEmpty ? ["y", "yes"].contains(answer) : answer == "yes" else {
            print("Nothing was removed.")
            return
        }
    }

    let (session, outcomes) = try remover.execute(plan, appName: name, bundleID: bundleID)
    let failed = outcomes.compactMap { planned, outcome -> (Leftover, String)? in
        if case .failed(let reason) = outcome { return (planned.item, reason) }
        return nil
    }
    let moved = outcomes.filter { if case .moved = $0.1 { true } else { false } }
    print("\nMoved \(moved.count) items (\(format(moved.reduce(0) { $0 + $1.0.item.size }))) to quarantine.")
    for (item, reason) in failed {
        print("  Could not move \(item.url.path)\n    \(reason)")
    }
    if !moved.isEmpty {
        print("Undo: poof restore \(session.id)")
    }
}

struct Restore: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Put removed items back. Without an ID, lists what is in quarantine."
    )

    @Argument(help: "Session ID from `poof restore` or the output of `poof remove`.")
    var session: String?

    @Flag(help: "Restore the most recent removal.")
    var last = false

    func run() throws {
        let quarantine = Quarantine()
        let sessions = quarantine.sessions()
        guard let id = session ?? (last ? sessions.first?.id : nil) else {
            listSessions(sessions)
            return
        }
        let results = try quarantine.restore(id)
        let restored = results.filter { $0.1 == nil }.count
        print("Restored \(restored) of \(results.count) items.")
        for (entry, error) in results {
            if let error { print("  \(entry.originalPath)\n    \(error)") }
        }
    }
}

struct Purge: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Permanently delete items in quarantine. This cannot be undone."
    )

    @Argument(help: "Session ID to delete.")
    var session: String?

    @Option(help: "Delete every session older than this many days.")
    var olderThan: Int?

    @Flag(help: "Delete every session.")
    var all = false

    @Flag(name: .shortAndLong, help: "Do not ask for confirmation.")
    var yes = false

    func run() throws {
        let quarantine = Quarantine()
        let sessions = quarantine.sessions()
        let targets: [Quarantine.Session]
        if let session {
            targets = sessions.filter { $0.id == session }
            guard !targets.isEmpty else { throw ValidationError("No quarantine session \"\(session)\"") }
        } else if let days = olderThan {
            let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
            targets = sessions.filter { $0.date < cutoff }
        } else if all {
            targets = sessions
        } else {
            throw ValidationError("Name a session, or use --older-than <days> or --all.")
        }
        guard !targets.isEmpty else {
            print("Nothing to purge.")
            return
        }

        listSessions(targets)
        if !yes {
            print("\nPermanently delete these? This cannot be undone. [y/N] ", terminator: "")
            guard ["y", "yes"].contains(readLine()?.lowercased() ?? "") else {
                print("Nothing was deleted.")
                return
            }
        }
        for target in targets {
            do {
                try quarantine.purge(target.id)
            } catch {
                print("Could not delete \(target.id): \(error.localizedDescription). Items from system folders need sudo.")
            }
        }
        print("Deleted \(format(targets.reduce(0) { $0 + $1.totalSize })).")
    }
}

/// Used by Poof.app, which runs it as root through macOS's administrator prompt to move
/// the items in system folders into a quarantine session the app already started.
struct AdminMove: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "admin-move",
        abstract: "Move items into an existing quarantine session (used by Poof.app).",
        shouldDisplay: false
    )

    @Option(help: "Quarantine session ID.")
    var session: String

    @Argument(help: "Paths to move.")
    var paths: [String]

    func run() throws {
        let quarantine = Quarantine()
        guard var target = quarantine.session(session) else {
            throw ValidationError("No quarantine session \"\(session)\"")
        }
        let remover = Remover(quarantine: quarantine, canWriteSystem: true)
        let plan = paths.map { path in
            let url = URL(fileURLWithPath: path)
            let item = Leftover(url: url, reason: .appBundle, size: LeftoverScanner.size(of: url))
            return Remover.PlannedItem(item: item, action: .move, sensitiveFiles: [])
        }
        // Always exits 0: AppleScript's `do shell script` hides stdout when a command fails,
        // so failures are reported as "path<TAB>reason" lines instead.
        for (planned, outcome) in remover.move(plan, into: &target) {
            if case .failed(let reason) = outcome {
                print("\(planned.item.url.path)\t\(reason)")
            }
        }
    }
}

func findApp(_ query: String) throws -> AppBundle {
    do { return try AppBundle.find(query) } catch let error as PoofError {
        throw ValidationError(error.description)
    }
}

func listSessions(_ sessions: [Quarantine.Session]) {
    guard !sessions.isEmpty else {
        print("Quarantine is empty.")
        return
    }
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    for session in sessions {
        print("\(session.id)\n  \(session.appName), \(session.entries.count) items, \(format(session.totalSize)), removed \(formatter.string(from: session.date))")
    }
}

func printItems(_ leftovers: [Leftover]) {
    for item in leftovers {
        let lock = item.isSystem ? " [admin]" : ""
        print("\(format(item.size).padding(toLength: 10, withPad: " ", startingAt: 0)) \(item.url.path)  (\(item.reason.rawValue))\(lock)")
        if let detail = item.detail {
            print("           \(detail)")
        }
        if !item.sharedWith.isEmpty {
            print("           ! also used by: \(item.sharedWith.joined(separator: ", "))")
        }
    }
}

func printTotal(_ leftovers: [Leftover], suffix: String) {
    print("\n\(leftovers.count) items, \(format(leftovers.reduce(0) { $0 + $1.size })) total. \(suffix)")
}

func format(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

func shellQuote(_ text: String) -> String {
    text.contains(" ") ? "\"\(text)\"" : text
}
