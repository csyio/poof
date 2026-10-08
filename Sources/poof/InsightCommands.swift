import ArgumentParser
import Foundation
import PoofCore

struct Apps: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List installed apps with where they came from, when they were last used, and Poof's verdict.",
        discussion: """
        Last used comes from Spotlight, which records apps opened through Finder, the Dock \
        or `open`. Apple's own apps are not listed. Run `poof why <app>` for the reasons \
        behind a verdict.
        """
    )

    @Option(help: ArgumentHelp("Only list apps not opened for at least this many days.", valueName: "days"))
    var unused: Int?

    @Flag(help: "Print JSON.")
    var json = false

    func run() throws {
        let apps = AppBundle.installedApps()
        let threshold = unused ?? AppInsight.defaultUnusedDays
        var insights = AppInsight.inspectAll(apps, unusedAfterDays: threshold)
        if let unused {
            insights = insights.filter { ($0.idleDays ?? -1) >= unused && !$0.signals.isRunning }
                .sorted { ($0.idleDays ?? 0) > ($1.idleDays ?? 0) }
        }

        if json {
            print(try encodeJSON(insights))
            return
        }
        guard !insights.isEmpty else {
            print(unused.map { "No app has gone unused for \($0) days." } ?? "No apps found.")
            return
        }

        let columns: [(title: String, width: Int)] = [("Name", 26), ("Developer", 24), ("Origin", 11), ("Last used", 13), ("Size", 9), ("Verdict", 0)]
        print(row(columns.map(\.title), widths: columns.map(\.width)))
        for insight in insights {
            print(row([
                insight.name,
                insight.vendor ?? "-",
                insight.origin.label,
                insight.lastUsedText,
                insight.signals.size.map(format) ?? "-",
                insight.verdict.word,
            ], widths: columns.map(\.width)))
        }
        let candidates = insights.filter(\.verdict.isRemovalCandidate).count
        if let unused {
            // The list holds every app idle that long, Homebrew and background apps included;
            // only some of them are suggested for removal.
            let them = candidates == 1 ? "is" : "are"
            print("\n\(insights.count) \(insights.count == 1 ? "app has" : "apps have") gone unused for \(unused) days or more; \(candidates) of them \(them) suggested for removal. Nothing was changed.")
        } else {
            // Idle as `--unused` counts it; the candidates are the idle apps nothing else explains.
            let idle = insights.filter { ($0.idleDays ?? -1) >= threshold && !$0.signals.isRunning }.count
            let them = candidates == 1 ? "is" : "are"
            print("\n\(insights.count) apps, \(idle) not opened in \(threshold) days or more; \(candidates) of them \(them) suggested for removal. Nothing was changed.")
        }
        print("Run `poof why <app>` to see the reasons behind a verdict.")
    }

    /// Names and developers come from the apps' own files, so they are made safe to print first.
    func row(_ values: [String], widths: [Int]) -> String {
        zip(values.map(\.sanitizedForTerminal), widths).map { value, width in
            guard width > 0 else { return value }
            let cut = value.count > width - 1 ? String(value.prefix(width - 2)) + "…" : value
            return cut.padding(toLength: width, withPad: " ", startingAt: 0)
        }.joined()
    }
}

struct Why: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Explain why an app is on this Mac and whether removing it is likely to matter."
    )

    @Argument(help: "App name (e.g. \"chrome\") or path to a .app bundle.")
    var app: String

    @Flag(help: "Print JSON.")
    var json = false

    func run() throws {
        let bundle = try findApp(app)
        let installed = AppBundle.installedApps()
        // Compared by path: the same app can come with a different URL form or signature read.
        let path = bundle.url.standardizedFileURL.path
        let isListed = installed.contains { $0.url.standardizedFileURL.path == path }
        let insight = AppInsight.inspect(bundle, installed: isListed ? installed : installed + [bundle])
        if json {
            print(try encodeJSON(insight))
            return
        }

        let s = insight.signals
        // Everything below except the labels comes from the app's files: print it made safe.
        let say = { (text: String) in print(text.sanitizedForTerminal) }
        say([s.name, s.version, s.bundleID].compactMap { $0 }.joined(separator: "  "))
        if let vendor = insight.vendor {
            say("Developer:  \(vendor)\(s.teamID.map { " (team \($0))" } ?? "")")
        }
        if let category = s.category { say("Category:   \(category)") }
        say("Origin:     \(insight.origin.label)")
        var usage = [s.isRunning ? "running now" : insight.daysSinceUse == nil ? "no record of being opened" : "last used \(insight.lastUsedText)"]
        if let added = s.dateAdded { usage.append("added \(AppInsight.relativeDays(AppInsight.days(from: added, to: Date())))") }
        if let size = s.size { usage.append(format(size)) }
        say("Usage:      \(usage.joined(separator: ", "))")
        say("Location:   \(s.path)")

        print("\nWhat Poof found:")
        for finding in insight.findings { say("  - \(finding)") }
        print("\nVerdict: \(insight.verdict.word)")
        say("  \(insight.recommendation)")
        if !insight.verdict.isRemovalCandidate, insight.verdict != .partOfMacOS {
            print("\nTo see its files: poof scan \(shellQuote(app))")
        } else if insight.verdict.isRemovalCandidate {
            print("\nTo see what would be removed: poof remove \(shellQuote(app)) --dry-run")
        }
    }
}

func encodeJSON<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    encoder.dateEncodingStrategy = .iso8601
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}
