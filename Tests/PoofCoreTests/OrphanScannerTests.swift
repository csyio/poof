import Foundation
import Testing
@testable import PoofCore

struct OrphanScannerTests {
    let scanner = OrphanScanner(
        home: URL(fileURLWithPath: "/nonexistent"),
        installedIDs: ["com.microsoft.Word", "com.google.antigravity", "com.fortinet.FortiClient"]
    )

    @Test func readsBundleIDsFromEntryNames() {
        #expect(OrphanScanner.bundleID(fromEntryName: "com.logi.ghub.plist") == "com.logi.ghub")
        #expect(OrphanScanner.bundleID(fromEntryName: "com.roblox.RobloxPlayer.savedState") == "com.roblox.RobloxPlayer")
        #expect(OrphanScanner.bundleID(fromEntryName: "com.apple.finder.plist") == nil)
        #expect(OrphanScanner.bundleID(fromEntryName: "Blackmagic Design") == nil)
        #expect(OrphanScanner.bundleID(fromEntryName: "com.Adobe.After Effects.plist") == nil)
        #expect(OrphanScanner.bundleID(fromEntryName: "CommCenter.plist") == nil)
    }

    @Test func treatsVendorFilesAsOwnedWhileAnyVendorAppIsInstalled() {
        #expect(scanner.isInstalledOrVendorPresent("com.microsoft.office"))
        #expect(scanner.isInstalledOrVendorPresent("com.microsoft.Word.widgetextension"))
        #expect(scanner.isInstalledOrVendorPresent("com.google.Keystone.Agent"))
        #expect(!scanner.isInstalledOrVendorPresent("com.logi.ghub"))
        #expect(!scanner.isInstalledOrVendorPresent("com.roblox.RobloxPlayer"))
    }

    @Test func findsOrphansInALibraryFolder() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("home-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let prefs = home.appendingPathComponent("Library/Preferences")
        let agents = home.appendingPathComponent("Library/LaunchAgents")
        try FileManager.default.createDirectory(at: prefs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        for name in ["com.logi.ghub.plist", "com.microsoft.office.plist", "com.apple.dock.plist", "org.swift.swiftpm.plist"] {
            try Data().write(to: prefs.appendingPathComponent(name))
        }
        try (["ProgramArguments": ["/Applications/Gone.app/Contents/MacOS/updater"]] as NSDictionary)
            .write(to: agents.appendingPathComponent("com.gone.updater.plist"))
        try (["Program": "/bin/sh"] as NSDictionary).write(to: agents.appendingPathComponent("com.fine.agent.plist"))
        let root = home.appendingPathComponent("root")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("bin/sh"))

        let scanner = OrphanScanner(home: home, systemRoot: root,
                                    installedIDs: ["com.microsoft.Word"])
        let found = scanner.scan().map { "\($0.url.lastPathComponent) \($0.reason)" }.sorted()
        #expect(found == [
            "com.gone.updater.plist brokenLaunchItem",
            "com.logi.ghub.plist orphanedBundleID",
        ])
    }

    @Test func skipsLibrariesAndToolsThatLookLikeApps() {
        #expect(isKnownNonApp("org.swift.swiftpm"))
        #expect(isKnownNonApp("com.github.Electron"))
        #expect(!isKnownNonApp("com.swiftapp.editor"))
    }

    @Test func installersDoNotCountAsInstalledApps() {
        #expect(OrphanScanner.isInstallerOrStaged("/Users/can/Downloads/lghub_installer.app"))
        #expect(OrphanScanner.isInstallerOrStaged("/Applications/FortiClientUninstaller.app"))
        #expect(OrphanScanner.isInstallerOrStaged("/Library/SystemExtensions/47CB/com.logi.ghub.hidfilter.dext"))
        #expect(!OrphanScanner.isInstallerOrStaged("/Applications/FortiClient.app"))
    }
}
