import ArgumentParser
import Foundation
import PoofCore

struct Extensions: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "extensions",
        abstract: "List the extensions installed in your browsers and flag the ones worth a look.",
        discussion: """
        Reads Chrome, Edge, Brave, Arc, Vivaldi, Opera and other Chromium browsers, Firefox, and \
        the extensions that apps provide to Safari. Nothing is changed: remove an extension in \
        the browser's own extensions page, or remove the app that supplies it. A flag is a reason \
        to look, not a verdict: Poof cannot tell whether an extension is harmful.
        """
    )

    @Flag(help: "Only show extensions that have a flag.")
    var flagged = false

    @Flag(help: "Print JSON (used by Poof.app).")
    var json = false

    func run() throws {
        let browsers = BrowserExtensionScanner().scan()

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            print(String(decoding: try encoder.encode(browsers), as: UTF8.self))
            return
        }

        var total = 0, flaggedTotal = 0
        for browser in browsers {
            total += browser.extensionCount
            flaggedTotal += browser.flaggedCount
            let shown = browser.profiles.map { profile in
                (profile, flagged ? profile.extensions.filter(\.isFlagged) : profile.extensions)
            }.filter { !$0.1.isEmpty }
            if flagged, shown.isEmpty, browser.note == nil || (browser.isInstalled && !browser.profiles.isEmpty) { continue }

            let status = browser.isInstalled ? "" : "  (not installed)"
            say("\(browser.name)\(status)")
            if let note = browser.note { say("  \(note)") }
            for (profile, extensions) in shown {
                let title = profile.directory.isEmpty ? profile.name
                    : (profile.name == profile.directory ? profile.name : "\(profile.name) (\(profile.directory))")
                say("  \(title): \(extensions.count) \(extensions.count == 1 ? "extension" : "extensions"), \(format(extensions.reduce(0) { $0 + $1.size }))")
                for item in extensions {
                    printExtension(item)
                }
            }
            print("")
        }

        if total == 0 {
            print("No browser extensions found.")
        } else {
            let count = browsers.filter { $0.extensionCount > 0 }.count
            print("\(total) \(total == 1 ? "extension" : "extensions") in \(count) \(count == 1 ? "browser" : "browsers"), \(flaggedTotal) with a flag. Nothing was changed.")
        }
        print("Remove an extension in its browser's extensions page, or by removing the app that provides it.")
    }

    private func printExtension(_ item: BrowserExtension) {
        let version = item.version.isEmpty ? "" : " \(item.version)"
        let state = item.state == .unknown ? "state unknown" : item.state.rawValue
        let origin = item.providedBy.map { "provided by \($0)" } ?? item.source.label
        say("    \(item.name)\(version)  [\(state)]  \(origin)  \(format(item.size))")
        say("      \(item.kind), id \(item.extensionID)")
        // The browser's note already says when the browser is gone; it is not repeated per extension.
        for flag in item.shownFlags {
            say("      ! \(flag.message)")
        }
    }

    /// Names, versions and IDs come from files in the browser profiles, which any extension or
    /// program can write: print them made safe for the terminal.
    private func say(_ text: String) {
        print(text.sanitizedForTerminal)
    }
}
