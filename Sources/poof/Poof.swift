import AppKit
import ArgumentParser
import Foundation
import PoofCore

@main
struct Poof: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Remove macOS apps and everything they leave behind.",
        version: poofVersion,
        subcommands: [Scan.self, Orphans.self, Remove.self, Restore.self, Purge.self]
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
    }
}

struct Orphans: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List files left by apps that are no longer installed, without changing anything."
    )

    func run() throws {
        let items = OrphanScanner().scan()
        let certain = items.filter(\.isCertain)
        let unsure = items.filter { !$0.isCertain }
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
    }
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

    @Flag(help: "Show what would happen without moving anything.")
    var dryRun = false

    @Flag(name: .shortAndLong, help: "Do not ask for confirmation.")
    var yes = false

    @Flag(help: "With --yes, also move items containing saved passwords, bookmarks or keys.")
    var allowSensitive = false

    func run() throws {
        let bundle = try findApp(app)
        if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bundle.bundleID }) {
            throw ValidationError("\(bundle.name) is running. Quit it first.")
        }

        let remover = Remover()
        let plan = remover.plan(LeftoverScanner().scan(bundle))
        let moving = plan.filter { $0.action == .move }
        let keeping = plan.filter { $0.action != .move }
        let sensitive = moving.filter { !$0.sensitiveFiles.isEmpty }

        print("\(bundle.name)  \(bundle.bundleID)\n")
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
        let needsAdmin = keeping.contains { $0.item.isSystem && $0.item.sharedWith.isEmpty && $0.item.reason != .systemExtension }
        if needsAdmin {
            print("\nSome items need administrator rights. To remove everything at once, run:")
            print("  sudo poof remove \(shellQuote(app))")
        }
        printTotal(moving.map(\.item), suffix: "Nothing has been moved yet.")

        if dryRun || moving.isEmpty { return }
        if yes {
            if !sensitive.isEmpty && !allowSensitive {
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

        let (session, outcomes) = try remover.execute(plan, appName: bundle.name, bundleID: bundle.bundleID)
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
