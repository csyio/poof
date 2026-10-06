import ArgumentParser
import Foundation
import PoofCore

@main
struct Poof: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Remove macOS apps and everything they leave behind.",
        version: poofVersion,
        subcommands: [Scan.self]
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
        let leftovers = LeftoverScanner().scan(bundle)

        print("\(bundle.name)  \(bundle.bundleID)  team: \(bundle.teamID ?? "unsigned")\n")
        for item in leftovers {
            let size = ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)
            let lock = item.isSystem ? " [admin]" : ""
            print("\(size.padding(toLength: 10, withPad: " ", startingAt: 0)) \(item.url.path)  (\(item.reason.rawValue))\(lock)")
            if !item.sharedWith.isEmpty {
                print("           ! also used by: \(item.sharedWith.joined(separator: ", "))")
            }
        }
        let total = leftovers.reduce(0) { $0 + $1.size }
        print("\n\(leftovers.count) items, \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file)) total. Nothing was removed.")
    }
}
