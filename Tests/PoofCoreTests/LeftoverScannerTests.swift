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
}
