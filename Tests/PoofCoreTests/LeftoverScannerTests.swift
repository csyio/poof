import Foundation
import Testing
@testable import PoofCore

struct LeftoverScannerTests {
    let chrome = AppBundle(
        url: URL(fileURLWithPath: "/Applications/Google Chrome.app"),
        name: "Google Chrome", bundleID: "com.google.Chrome", teamID: "EQHXZ8M8AV"
    )
    let scanner = LeftoverScanner()

    func reason(_ path: String) -> Leftover.Reason? {
        scanner.match(URL(fileURLWithPath: path), app: chrome)
    }

    @Test func matchesBundleIDAndChildren() {
        #expect(reason("/u/Library/Preferences/com.google.Chrome.plist") == .bundleID)
        #expect(reason("/u/Library/Saved Application State/com.google.Chrome.savedState") == .bundleID)
        #expect(reason("/u/Library/Caches/com.google.Chrome.helper") == .bundleID)
    }

    @Test func ignoresSiblingsUnderSameVendor() {
        #expect(reason("/u/Library/Preferences/com.google.antigravity.plist") == nil)
        #expect(reason("/u/Library/Preferences/com.google.ChromeBeta.plist") == nil)
    }

    @Test func matchesTeamIDOnlyInGroupContainers() {
        #expect(reason("/u/Library/Group Containers/EQHXZ8M8AV.com.google.Chrome") == .teamID)
        #expect(reason("/u/Library/Group Containers/EQHXZ8M8AV.group.com.google.Chrome.shared") == .teamID)
        #expect(reason("/u/Library/Caches/EQHXZ8M8AV.com.google.Chrome") == nil)
    }

    @Test func ignoresOtherAppsFromSameDeveloper() {
        #expect(reason("/u/Library/Group Containers/EQHXZ8M8AV.com.google.antigravity") == nil)
        #expect(reason("/u/Library/Group Containers/EQHXZ8M8AV.Office") == nil)
    }

    @Test func matchesAppNameFolder() {
        #expect(reason("/u/Library/Application Support/Google Chrome") == .appName)
    }

    @Test func findsAppFolderInsideVendorFolder() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID())/Application Support")
        defer { try? FileManager.default.removeItem(at: support.deletingLastPathComponent()) }
        let google = support.appendingPathComponent("Google")
        let blackmagic = support.appendingPathComponent("Blackmagic Design")
        try FileManager.default.createDirectory(at: google.appendingPathComponent("Chrome"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: blackmagic.appendingPathComponent("Google Chrome"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: blackmagic.appendingPathComponent("Fusion"), withIntermediateDirectories: true)
        #expect(scanner.vendorFolder(google, app: chrome)?.lastPathComponent == "Chrome")
        #expect(scanner.vendorFolder(blackmagic, app: chrome)?.lastPathComponent == "Google Chrome")
        let fusion = AppBundle(url: URL(fileURLWithPath: "/Applications/Fusion.app"), name: "Fusion", bundleID: "x.fusion", teamID: nil)
        #expect(scanner.vendorFolder(google, app: fusion) == nil)
    }

    @Test func detectsLaunchItemRunningTheApp() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LaunchAgents-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let plist = dir.appendingPathComponent("com.vendor.updater.plist")
        let args = ["/Applications/Google Chrome.app/Contents/Helpers/updater", "--run"]
        try (["Label": "com.vendor.updater", "ProgramArguments": args] as NSDictionary).write(to: plist)
        #expect(scanner.launchItem(plist, runsFrom: [chrome.url.path]))
        #expect(!scanner.launchItem(plist, runsFrom: ["/Applications/Google"]))
    }

    @Test func recognizesCrashReportsByExecutable() {
        let exes = ["Resolve", "Google Chrome Helper"]
        #expect(LeftoverScanner.isCrashReport("Resolve_054C896E-8136-5519-8DA0-02A1B6833FB3.plist", of: exes))
        #expect(LeftoverScanner.isCrashReport("Resolve-2026-10-07-101500.ips", of: exes))
        #expect(LeftoverScanner.isCrashReport("Google Chrome Helper-2026-10-01-090000.ips", of: exes))
        #expect(!LeftoverScanner.isCrashReport("ResolveX_054C896E-8136-5519-8DA0-02A1B6833FB3.plist", of: exes))
        #expect(!LeftoverScanner.isCrashReport("Resolve_notes.plist", of: exes))
        #expect(!LeftoverScanner.isCrashReport("Resolve-2026.log", of: exes))
    }

    @Test func findsHelpersInsideTheBundleFromTheSameVendor() throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("Test-\(UUID()).app")
        defer { try? FileManager.default.removeItem(at: app) }
        func bundle(_ path: String, id: String, name: String) throws {
            let contents = app.appendingPathComponent(path).appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            try (["CFBundleIdentifier": id, "CFBundleName": name, "CFBundleExecutable": name] as NSDictionary)
                .write(to: contents.appendingPathComponent("Info.plist"))
        }
        try bundle("", id: "com.blackmagic-design.DaVinciResolve", name: "Resolve")
        try bundle("Contents/Applications/.hidden/DaVinci Resolve Welcome.app", id: "com.blackmagic-design.DaVinciResolveWelcome", name: "DaVinci Resolve Welcome")
        try bundle("Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate.app", id: "org.sparkle-project.Sparkle.Autoupdate", name: "Autoupdate")
        try bundle("Contents/Resources/Bundled.app", id: "com.blackmagic-design.InResources", name: "Bundled")

        let resolve = try AppBundle(at: app)
        let identity = resolve.identity()
        #expect(identity.bundleIDs == ["com.blackmagic-design.DaVinciResolve", "com.blackmagic-design.DaVinciResolveWelcome"])
        #expect(identity.names.contains("DaVinci Resolve Welcome"))
        #expect(!identity.bundleIDs.contains { $0.hasPrefix("org.sparkle") })

        let scanner = LeftoverScanner()
        let prefs = URL(fileURLWithPath: "/u/Library/Preferences/com.blackmagic-design.davinciresolvewelcome.DaVinci Resolve Welcome.plist")
        #expect(scanner.match(prefs, identity: .init(resolve)) == .bundleID)
        #expect(scanner.match(URL(fileURLWithPath: "/u/Library/Caches/org.sparkle-project.Sparkle"), identity: .init(resolve)) == nil)
    }

    @Test func helpersOtherAppsEmbedAreShared() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("office-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        func bundle(_ path: String, id: String, name: String) throws {
            let contents = root.appendingPathComponent(path).appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            try (["CFBundleIdentifier": id, "CFBundleName": name] as NSDictionary)
                .write(to: contents.appendingPathComponent("Info.plist"))
        }
        try bundle("Word.app", id: "com.microsoft.Word", name: "Word")
        try bundle("Word.app/Contents/SharedSupport/Microsoft Error Reporting.app", id: "com.microsoft.errorreporting", name: "Microsoft Error Reporting")
        try bundle("Word.app/Contents/PlugIns/Widget.appex", id: "com.microsoft.Word.widgetextension", name: "WordWidgetKit")
        try bundle("Excel.app", id: "com.microsoft.Excel", name: "Excel")
        try bundle("Excel.app/Contents/SharedSupport/Microsoft Error Reporting.app", id: "com.microsoft.errorreporting", name: "Microsoft Error Reporting")

        let word = try AppBundle(at: root.appendingPathComponent("Word.app"))
        let excel = try AppBundle(at: root.appendingPathComponent("Excel.app"))
        let shared = word.sharedHelpers(among: [word, excel])
        #expect(shared == ["com.microsoft.errorreporting": ["Excel"]])

        let identity = LeftoverScanner.Identity(word, shared: shared)
        let reporting = URL(fileURLWithPath: "/u/Library/Containers/com.microsoft.errorreporting")
        let widget = URL(fileURLWithPath: "/u/Library/Containers/com.microsoft.Word.widgetextension")
        #expect(identity.sharedWith(reporting) == ["Excel"])
        #expect(identity.sharedWith(widget).isEmpty)
    }
}
