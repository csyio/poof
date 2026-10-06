import ArgumentParser
import Foundation
import PoofCore

@main
struct Poof: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Remove macOS apps and everything they leave behind.",
        version: poofVersion,
        subcommands: [Scan.self, Orphans.self]
    )
}

struct Scan: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List an app's files without changing anything."
    )

    @Argument(help: "App name (e.g. \"chrome\") or path to a .app bundle.")
    var app: String

    func run() throws {
        let bundle: AppBundle
        do { bundle = try AppBundle.find(app) } catch let error as PoofError {
            throw ValidationError(error.description)
        }
        print("\(bundle.name)  \(bundle.bundleID)  team: \(bundle.teamID ?? "unsigned")\n")
        printItems(LeftoverScanner().scan(bundle))
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
        if items.isEmpty { print("No orphaned files found.") }
    }
}

func printItems(_ leftovers: [Leftover]) {
        for item in leftovers {
            let size = ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)
            let lock = item.isSystem ? " [admin]" : ""
            print("\(size.padding(toLength: 10, withPad: " ", startingAt: 0)) \(item.url.path)  (\(item.reason.rawValue))\(lock)")
            if let detail = item.detail {
                print("           \(detail)")
            }
            if !item.sharedWith.isEmpty {
                print("           ! also used by: \(item.sharedWith.joined(separator: ", "))")
            }
        }
        let total = leftovers.reduce(0) { $0 + $1.size }
        print("\n\(leftovers.count) items, \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file)) total. Nothing was removed.")
}
