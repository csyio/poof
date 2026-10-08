import Foundation
import Testing
@testable import PoofCore

/// Package receipts with install times, for the "installed at the same time" relation.
private struct TimedPackages: PackageDatabase {
    var receipts: [String: [String]] = [:]
    var times: [String: Date] = [:]
    func packageIDs() -> [String] { receipts.keys.sorted() }
    func files(of packageID: String) -> [String] { receipts[packageID] ?? [] }
    func installTime(of packageID: String) -> Date? { times[packageID] }
}

/// A folder of fake app bundles that is deleted when the test ends.
private final class Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("poof-insight-\(UUID())")
    let fm = FileManager.default

    deinit { try? fm.removeItem(at: root) }

    func path(_ relative: String) -> URL { root.appendingPathComponent(relative) }

    @discardableResult
    func app(_ relative: String, id: String, info: [String: Any] = [:]) throws -> URL {
        let url = path(relative)
        try fm.createDirectory(at: url.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        var plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundlePackageType": "APPL",
                                    "CFBundleName": url.deletingPathExtension().lastPathComponent]
        plist.merge(info) { _, new in new }
        try (plist as NSDictionary).write(to: url.appendingPathComponent("Contents/Info.plist"))
        return url
    }

    func file(_ relative: String, _ contents: String = "") throws {
        let url = path(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    func plist(_ relative: String, _ dict: [String: Any]) throws {
        let url = path(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (dict as NSDictionary).write(to: url)
    }

    func quarantine(_ url: URL, _ value: String) {
        let bytes = Array(value.utf8)
        _ = bytes.withUnsafeBytes { setxattr(url.path, "com.apple.quarantine", $0.baseAddress, $0.count, 0, 0) }
    }

    /// `signatures` stands in for code signatures by path; everything else reads as unsigned.
    /// `launchd` stands in for launchctl: by default it has nothing loaded.
    func sources(packages: any PackageDatabase = TimedPackages(), running: Set<String> = [],
                 spotlight: SpotlightDates = SpotlightDates(), signatures: [String: CodeSignature] = [:],
                 launchd: LaunchdJobs = LaunchdJobs(user: [], system: [])) -> InsightSources {
        var sources = InsightSources(home: path("home"), systemRoot: root, packages: packages, measureSize: true,
                                     runningBundleIDs: { running }, spotlight: { _ in spotlight }, launchdJobs: { launchd })
        // Folder listings give /private/var paths for the /var temporary folder; compare resolved paths.
        let resolved = Dictionary(signatures.map { (URL(fileURLWithPath: $0.key).resolvingSymlinksInPath().path, $0.value) },
                                  uniquingKeysWith: { first, _ in first })
        sources.codeSignature = { resolved[$0.resolvingSymlinksInPath().path] ?? .unsigned }
        return sources
    }
}

struct AppInsightTests {
    let now = Date(timeIntervalSince1970: 1_791_000_000)

    func ago(_ days: Int) -> Date { now.addingTimeInterval(-Double(days) * 86_400) }

    func signals(_ configure: (inout AppSignals) -> Void = { _ in }) -> AppSignals {
        var s = AppSignals(name: "Foo", bundleID: "com.example.foo", path: "/Applications/Foo.app")
        s.signer = .developerID("Example Inc")
        s.teamID = "ABCDE12345"
        configure(&s)
        return s
    }

    // MARK: Vendor and signature

    @Test func parsesDeveloperIDCertificate() {
        let signer = Signer(leafCommonName: "Developer ID Application: Raycast Technologies Inc (SY64MV22J9)", isSigned: true,
                            trust: .developerID)
        #expect(signer == .developerID("Raycast Technologies Inc"))
        #expect(signer.vendor == "Raycast Technologies Inc")
        // Parentheses that are not a team ID stay.
        #expect(Signer(leafCommonName: "Developer ID Application: Foo (Europe) Ltd", isSigned: true, trust: .developerID).vendor
            == "Foo (Europe) Ltd")
    }

    @Test func recognisesAppStoreAppleAndUnsignedApps() {
        #expect(Signer(leafCommonName: "Apple Mac OS Application Signing", isSigned: true, trust: .appStore) == .appStore)
        #expect(Signer(leafCommonName: "Software Signing", isSigned: true, trust: .apple) == .apple)
        #expect(Signer(leafCommonName: "Software Signing", isSigned: true, trust: .apple).vendor == "Apple")
        #expect(Signer(leafCommonName: "Apple Development: Jane Doe (ABC123XYZ9)", isSigned: true, trust: .appleIssued)
            == .development("Jane Doe"))
        #expect(Signer(leafCommonName: nil, isSigned: true, trust: .none) == .adHoc)
        #expect(Signer(leafCommonName: nil, isSigned: false, trust: .none) == .unsigned)
        #expect(Signer.appStore.vendor == nil)
    }

    @Test func distributionCertificatesAreNotDevelopmentOnes() {
        let apple = Signer(leafCommonName: "Apple Distribution: Example Inc (ABCDE12345)", isSigned: true, trust: .appleIssued)
        #expect(apple == .distribution("Example Inc"))
        #expect(apple.vendor == "Example Inc")
        let legacy = Signer(leafCommonName: "3rd Party Mac Developer Application: Example Inc (ABCDE12345)", isSigned: true,
                            trust: .appleIssued)
        #expect(legacy == .distribution("Example Inc"))
        let sentence = AppInsight.evaluate(signals { $0.signer = apple }).findings.first { $0.contains("certificate") }
        #expect(sentence?.contains("App Store distribution certificate") == true)
        #expect(sentence?.contains("development") == false)
    }

    /// A certificate's name proves nothing until its chain is verified: a self-signed
    /// "Software Signing" must not make an app part of macOS.
    @Test func unverifiedCertificateNamesAreNotTrusted() {
        for name in ["Software Signing", "macOS Software Signing", "Developer ID Application: Apple Inc. (ABCDE12345)",
                     "Apple Mac OS Application Signing", "Apple Development: Jane Doe (ABC123XYZ9)"] {
            let signer = Signer(leafCommonName: name, isSigned: true, trust: .none)
            #expect(signer == .unverified(name))
            #expect(signer.vendor == nil)
            #expect(AppOrigin(OriginEvidence(), signer: signer) == .unknown)
        }
        let insight = AppInsight.evaluate(signals { $0.signer = .unverified("Software Signing"); $0.lastUsed = ago(400) }, now: now)
        #expect(insight.verdict == .unused(days: 400))
        #expect(insight.findings.contains { $0.contains("could not verify") })
        // A name an Apple-verified chain does not explain is shown as is, never as Apple.
        #expect(Signer(leafCommonName: "Software Signing", isSigned: true, trust: .appleIssued) == .other("Software Signing"))
    }

    /// Reads real signatures, so it runs on any Mac: macOS's own Calculator is Apple's, and a
    /// bundle with no signature has neither a signer nor a team ID.
    @Test func readsAndVerifiesRealSignatures() throws {
        let calculator = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        if FileManager.default.fileExists(atPath: calculator.path) {
            #expect(CodeSignature.read(calculator).signer == .apple)
        }
        let fx = Fixture()
        let unsigned = try fx.app("Applications/Plain.app", id: "com.example.plain")
        #expect(CodeSignature.read(unsigned) == .unsigned)
        #expect(try AppBundle(at: unsigned).teamID == nil)
    }

    @Test func readsVendorFromCopyrightForAppStoreApps() {
        #expect(AppSignals.vendor(fromCopyright: "Copyright © 2014-2026 Telegram FZ-LLC. All rights reserved.") == "Telegram FZ-LLC")
        #expect(AppSignals.vendor(fromCopyright: "© 2024 Example GmbH") == "Example GmbH")
        #expect(AppSignals.vendor(fromCopyright: "Copyright 2024") == nil)
        // A description in the copyright field is not a vendor.
        #expect(AppSignals.vendor(fromCopyright: "Key mapper for the Lyra keyboard") == nil)
        var s = signals { $0.signer = .appStore; $0.copyright = "Copyright (c) 2023, Acme Corp." }
        #expect(s.vendor == "Acme Corp")
        s.signer = .developerID("Signed Name")
        #expect(s.vendor == "Signed Name")
        // Only App Store apps fall back to the copyright line.
        s.signer = .adHoc
        #expect(s.vendor == nil)
    }

    @Test func humanisesCategories() {
        #expect(AppSignals.humanize(category: "public.app-category.developer-tools") == "Developer Tools")
        #expect(AppSignals.humanize(category: "public.app-category.utilities") == "Utilities")
    }

    // MARK: Quarantine

    @Test func parsesQuarantineAttribute() throws {
        let info = try #require(QuarantineInfo(attribute: "01c1;6a855ae7;Edge;88BDA545-F7A6-411A-A3D3-72488DEC228C"))
        #expect(info.agent == "Edge")
        #expect(info.date == Date(timeIntervalSince1970: TimeInterval(0x6a855ae7)))
        #expect(QuarantineInfo(attribute: "0181;6ab94181;;99801FE7")?.agent == nil)
        #expect(QuarantineInfo(attribute: "garbage") == nil)
    }

    // MARK: Verdicts from synthetic signals

    @Test func appleAppsAreNeverCandidates() {
        let insight = AppInsight.evaluate(signals { $0.signer = .apple; $0.lastUsed = ago(900) }, now: now)
        #expect(insight.verdict == .partOfMacOS)
        #expect(insight.recommendation.contains("cannot be removed"))
        let system = AppInsight.evaluate(signals { $0.origin.isInSystemFolder = true }, now: now)
        #expect(system.verdict == .partOfMacOS)
    }

    @Test func embeddedAppIsAComponent() {
        let insight = AppInsight.evaluate(signals { $0.embeddedIn = ["Host"]; $0.lastUsed = ago(400) }, now: now)
        #expect(insight.verdict == .componentOf("Host"))
        #expect(insight.recommendation.contains("Remove Host instead"))
    }

    @Test func backgroundServicesExplainWhatTheyLikelySupport() {
        let vpn = AppInsight.evaluate(signals {
            $0.background = [
                BackgroundItem(kind: .launchDaemon, identifier: "com.example.foo.daemon"),
                BackgroundItem(kind: .systemExtension, identifier: "com.example.foo.filter", detail: "network extension"),
            ]
        }, now: now)
        #expect(vpn.verdict == .runsInBackground(["a launch daemon", "a network extension"]))
        #expect(vpn.recommendation.contains("VPN"))
        #expect(vpn.recommendation.contains("Keep it unless you no longer use that product"))

        let driver = AppInsight.evaluate(signals {
            $0.background = [BackgroundItem(kind: .kernelExtension, identifier: "com.example.driver")]
        }, now: now)
        #expect(driver.recommendation.contains("device"))
    }

    @Test func updatersAloneDoNotCountAsBackgroundServices() {
        let insight = AppInsight.evaluate(signals {
            $0.background = [BackgroundItem(kind: .launchAgent, identifier: "com.example.foo.updater")]
            $0.lastUsed = ago(3)
        }, now: now)
        #expect(insight.verdict == .recentlyUsed(days: 3))
        #expect(insight.findings.contains { $0.contains("automatic updater") })
    }

    @Test func homebrewAppsPointToBrew() {
        let insight = AppInsight.evaluate(signals {
            $0.origin.homebrewCask = "foo"
            $0.origin.quarantine = QuarantineInfo(agent: "Homebrew", date: nil)
            $0.lastUsed = ago(200)
        }, now: now)
        #expect(insight.verdict == .managedByHomebrew(cask: "foo"))
        #expect(insight.origin == .homebrew(cask: "foo"))
        #expect(insight.recommendation.contains("`brew uninstall --cask foo`"))
        #expect(insight.recommendation.hasPrefix("Not opened in 200 days."))
    }

    @Test func unusedDownloadIsACandidate() {
        let insight = AppInsight.evaluate(signals {
            $0.origin.quarantine = QuarantineInfo(agent: "Chrome", date: ago(500))
            $0.lastUsed = ago(214)
        }, now: now)
        #expect(insight.verdict == .unused(days: 214))
        #expect(insight.verdict.isRemovalCandidate)
        #expect(insight.recommendation == "Not opened in 214 days, downloaded with Chrome and nothing else depends on it: a good candidate to remove.")
        #expect(insight.findings.first?.hasPrefix("Downloaded with Chrome on ") == true)
    }

    @Test func appInstalledWithOthersIsOnlyAWeakCandidate() {
        let insight = AppInsight.evaluate(signals {
            $0.origin.packageIDs = ["com.example.pkg"]
            $0.package = PackageRelations(otherApps: ["Foo Helper"])
            $0.lastUsed = ago(120)
        }, now: now)
        #expect(insight.verdict == .unused(days: 120))
        #expect(insight.verdict.isRemovalCandidate)
        #expect(insight.recommendation.contains("installed together with Foo Helper; removing it leaves it in place"))
        #expect(insight.recommendation.contains("check what else its installer added first"))
        #expect(!insight.recommendation.contains("nothing else depends"))
        #expect(!insight.findings.contains { $0.contains("no other app depends") })
    }

    @Test func neverOpenedAppCountsFromWhenItWasAdded() {
        let old = AppInsight.evaluate(signals { $0.dateAdded = ago(150) }, now: now)
        #expect(old.verdict == .unused(days: 150))
        #expect(old.recommendation.hasPrefix("No record of being opened in the 150 days since it was added"))
        let recent = AppInsight.evaluate(signals { $0.dateAdded = ago(5) }, now: now)
        #expect(recent.verdict == .unknownOrigin)
    }

    @Test func helpersWithoutUsageRecordAreFlaggedForChecking() {
        let helper = AppInsight.evaluate(signals { $0.dateAdded = ago(120); $0.companions = ["Main App"] }, now: now)
        #expect(helper.verdict == .unused(days: 120))
        #expect(helper.recommendation.contains("behind the scenes for Main App"))
        #expect(!helper.recommendation.contains("good candidate"))
        let menuBar = AppInsight.evaluate(signals { $0.dateAdded = ago(120); $0.isBackgroundOnly = true }, now: now)
        #expect(menuBar.recommendation.contains("another app"))
        #expect(menuBar.findings.contains { $0.contains("no Dock icon") })
    }

    @Test func runningAppIsInUse() {
        let insight = AppInsight.evaluate(signals { $0.isRunning = true; $0.lastUsed = ago(300) }, now: now)
        #expect(insight.verdict == .recentlyUsed(days: 0))
        #expect(insight.lastUsedText == "running")
    }

    @Test func fallsBackToOriginWithoutUsageRecord() {
        #expect(AppInsight.evaluate(signals { $0.origin.hasAppStoreReceipt = true; $0.signer = .appStore }, now: now).verdict == .fromAppStore)
        #expect(AppInsight.evaluate(signals(), now: now).verdict == .unknownOrigin)
        #expect(AppInsight.evaluate(signals { $0.origin.packageIDs = ["com.example.pkg"] }, now: now).verdict == .noUsageRecord)
    }

    @Test func thresholdIsConfigurable() {
        let s = signals { $0.lastUsed = ago(40) }
        #expect(AppInsight.evaluate(s, now: now).verdict == .recentlyUsed(days: 40))
        #expect(AppInsight.evaluate(s, now: now, unusedAfterDays: 30).verdict == .unused(days: 40))
    }

    @Test func neverClaimsRemovalIsSafe() {
        let variants: [AppSignals] = [
            signals { $0.lastUsed = ago(400); $0.origin.quarantine = QuarantineInfo(agent: nil, date: nil) },
            signals { $0.lastUsed = ago(400); $0.origin.hasAppStoreReceipt = true },
            signals { $0.dateAdded = ago(400) },
            signals { $0.origin.homebrewCask = "foo" },
            signals(),
        ]
        for s in variants {
            let insight = AppInsight.evaluate(s, now: now)
            #expect(!insight.recommendation.lowercased().contains("safe to remove"))
        }
    }

    // MARK: Formatting

    @Test func formatsLastUsed() {
        #expect(AppInsight.relativeDays(0) == "today")
        #expect(AppInsight.relativeDays(1) == "yesterday")
        #expect(AppInsight.relativeDays(45) == "45 days ago")
        #expect(AppInsight.relativeDays(214) == "7 months ago")
        #expect(AppInsight.relativeDays(800) == "2 years ago")
        #expect(AppInsight.evaluate(signals(), now: now).lastUsedText == "never")
        #expect(AppInsight.evaluate(signals { $0.lastUsed = ago(12) }, now: now).lastUsedText == "12 days ago")
    }

    @Test func countsCalendarDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let midnight = 1_791_000_000 - 1_791_000_000 % 86_400
        let evening = Date(timeIntervalSince1970: TimeInterval(midnight + 82_800))  // 23:00 UTC
        let nextMorning = evening.addingTimeInterval(7_200)  // 01:00 the next day
        #expect(AppInsight.days(from: evening, to: nextMorning, calendar: calendar) == 1)
        #expect(AppInsight.days(from: nextMorning, to: evening, calendar: calendar) == 0)
    }

    @Test func encodesJSON() throws {
        let insight = AppInsight.evaluate(signals { $0.lastUsed = ago(214) }, now: now)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(insight)) as? [String: Any]
        #expect(json?["verdict"] as? String == "unused")
        #expect(json?["vendor"] as? String == "Example Inc")
        #expect(json?["daysSinceUse"] as? Int == 214)
    }

    // MARK: Origin from fixture folders

    @Test func detectsAppStoreReceiptAndQuarantine() throws {
        let fx = Fixture()
        let store = try fx.app("Applications/Store.app", id: "com.example.store")
        try fx.file("Applications/Store.app/Contents/_MASReceipt/receipt", "receipt")
        let downloaded = try fx.app("Applications/Downloaded.app", id: "com.example.downloaded")
        fx.quarantine(downloaded, "0083;6a77718d;Chrome;3A53D057-D700-4EC2-8DED-7855153D3955")

        let storeEvidence = OriginEvidence.gather(at: store, systemRoot: fx.root, casks: [:])
        #expect(storeEvidence.hasAppStoreReceipt)
        #expect(AppOrigin(storeEvidence, signer: .appStore) == .appStore)
        // Anyone can create the receipt file: without the App Store's signature it proves nothing.
        #expect(AppOrigin(storeEvidence, signer: .developerID("X")) == .unknown)
        #expect(AppOrigin(storeEvidence, signer: .adHoc) == .unknown)
        var forged = AppSignals(name: "Store", bundleID: "com.example.store", path: store.path)
        forged.signer = .adHoc
        forged.origin = storeEvidence
        let insight = AppInsight.evaluate(forged, now: now)
        #expect(insight.origin == .unknown)
        #expect(insight.findings.contains { $0.contains("App Store receipt, but the App Store did not sign it") })
        var genuine = forged
        genuine.signer = .appStore
        #expect(!AppInsight.evaluate(genuine, now: now).findings.contains { $0.contains("receipt") })

        let evidence = OriginEvidence.gather(at: downloaded, systemRoot: fx.root, casks: [:])
        #expect(!evidence.hasAppStoreReceipt)
        #expect(evidence.quarantine?.agent == "Chrome")
        #expect(AppOrigin(evidence, signer: .adHoc) == .downloaded(agent: "Chrome", date: Date(timeIntervalSince1970: TimeInterval(0x6a77718d))))
    }

    @Test func detectsSystemAndSetappFolders() throws {
        let fx = Fixture()
        let system = try fx.app("System/Applications/Calculator.app", id: "com.example.calculator")
        let setapp = try fx.app("Applications/Setapp/Tool.app", id: "com.example.tool")
        #expect(OriginEvidence.gather(at: system, systemRoot: fx.root, casks: [:]).isInSystemFolder)
        let evidence = OriginEvidence.gather(at: setapp, systemRoot: fx.root, casks: [:])
        #expect(evidence.isInSetapp)
        #expect(AppOrigin(evidence, signer: .developerID("X")) == .setapp)
    }

    @Test func indexesHomebrewCasks() throws {
        let fx = Fixture()
        let app = try fx.app("Applications/Foo Bar.app", id: "com.example.foobar")
        try fx.fm.createDirectory(at: fx.path("Caskroom/foo-bar/1.2.3"), withIntermediateDirectories: true)
        try fx.fm.createSymbolicLink(at: fx.path("Caskroom/foo-bar/1.2.3/Foo Bar.app"), withDestinationURL: app)
        // A cask whose link is gone but whose receipt names the app, renamed through "target".
        try fx.file("Caskroom/other/.metadata/INSTALL_RECEIPT.json", """
        {"uninstall_artifacts": [{"uninstall": [{"quit": "x"}]}, {"app": ["Source.app", {"target": "Renamed.app"}]}, {"app": ["Plain.app"]}]}
        """)
        // Not a cask token: never turned into a `brew` command.
        try fx.fm.createDirectory(at: fx.path("Caskroom/bad; rm -rf ~/1.0"), withIntermediateDirectories: true)
        try fx.fm.createSymbolicLink(at: fx.path("Caskroom/bad; rm -rf ~/1.0/Evil.app"), withDestinationURL: app)
        let index = HomebrewCasks.index(caskrooms: [fx.path("Caskroom"), fx.path("missing")], appDir: fx.path("Applications"))
        #expect(index["evil.app"] == nil)
        #expect(index["foo bar.app"]?.map(\.cask) == ["foo-bar"])
        #expect(index["renamed.app"]?.map(\.cask) == ["other"])
        #expect(index["plain.app"]?.map(\.cask) == ["other"])
        #expect(index["source.app"] == nil)
        #expect(OriginEvidence.gather(at: app, systemRoot: fx.root, casks: index).homebrewCask == "foo-bar")

        // Receipt-only apps count where the cask installs apps.
        let plain = try fx.app("Applications/Plain.app", id: "com.example.plain")
        #expect(OriginEvidence.gather(at: plain, systemRoot: fx.root, casks: index).homebrewCask == "other")
        // A second copy with the same name elsewhere is not Homebrew's, by link or by receipt.
        let copy = try fx.app("home/Applications/Foo Bar.app", id: "com.example.foobar")
        let plainCopy = try fx.app("home/Applications/Plain.app", id: "com.example.plain")
        #expect(OriginEvidence.gather(at: copy, systemRoot: fx.root, casks: index).homebrewCask == nil)
        #expect(OriginEvidence.gather(at: plainCopy, systemRoot: fx.root, casks: index).homebrewCask == nil)

        // `--appdir` recorded in the cask's config moves where its receipt apps are expected.
        try fx.file("Caskroom/other/.metadata/config.json", #"{"default": {"appdir": "/Applications"}, "explicit": {"appdir": "\#(fx.path("home/Applications").path)"}}"#)
        let moved = HomebrewCasks.index(caskrooms: [fx.path("Caskroom")], appDir: fx.path("Applications"))
        #expect(OriginEvidence.gather(at: plainCopy, systemRoot: fx.root, casks: moved).homebrewCask == "other")
        #expect(OriginEvidence.gather(at: plain, systemRoot: fx.root, casks: moved).homebrewCask == nil)
    }

    /// `~` in a recorded `--appdir` is the user's home from `UserContext`, not root's under sudo.
    @Test func expandsTildeInAppDirWithTheUsersHome() throws {
        let fx = Fixture()
        let home = fx.path("home")
        try fx.file("tilde.json", #"{"explicit": {"appdir": "~/Applications"}}"#)
        #expect(HomebrewCasks.configuredAppDir(fx.path("tilde.json"), home: home)?.path == home.path + "/Applications")
        try fx.file("bare.json", #"{"explicit": {"appdir": "~"}}"#)
        #expect(HomebrewCasks.configuredAppDir(fx.path("bare.json"), home: home)?.path == home.path)
        try fx.file("relative.json", #"{"explicit": {"appdir": "Applications"}}"#)
        #expect(HomebrewCasks.configuredAppDir(fx.path("relative.json"), home: home) == nil)
    }

    /// /Applications at depth 1 enters /Applications/Utilities, which is listed on its own too.
    @Test func listsEachInstalledAppOnce() throws {
        let fx = Fixture()
        try fx.app("Applications/Foo.app", id: "com.example.foo")
        try fx.app("Applications/Utilities/Tool.app", id: "com.example.tool")
        try fx.app("Applications/Suite/Suite.app", id: "com.example.suite")
        let dirs = [fx.path("Applications"), fx.path("Applications/Utilities"), fx.path("Applications/../Applications/Utilities")]
        let names = AppBundle.appURLs(in: dirs).map(\.lastPathComponent)
        #expect(names.sorted() == ["Foo.app", "Suite.app", "Tool.app"])
    }

    // MARK: Gathering end to end, on fixtures only

    @Test func gathersRelationshipsFromFixtures() throws {
        let fx = Fixture()
        let vpn = try fx.app("Applications/Example VPN.app", id: "com.example.vpn",
                             info: ["CFBundleShortVersionString": "2.1", "LSApplicationCategoryType": "public.app-category.utilities"])
        let companion = try fx.app("Applications/Example Tools.app", id: "com.example.tools")
        // Another app ships the VPN's bundle ID inside itself.
        let host = try fx.app("Applications/Suite.app", id: "com.suite.app")
        try fx.app("Applications/Suite.app/Contents/Library/LoginItems/Helper.app", id: "com.example.helper")
        let helperApp = try fx.app("Applications/Helper.app", id: "com.example.helper")

        try fx.plist("home/Library/LaunchAgents/com.example.vpn.agent.plist",
                     ["Label": "com.example.vpn.agent", "ProgramArguments": ["/usr/bin/true"]])
        try fx.plist("Library/LaunchDaemons/com.other.daemon.plist",
                     ["Label": "com.other.daemon", "Program": vpn.path + "/Contents/MacOS/daemon"])
        try fx.plist("Library/LaunchDaemons/com.unrelated.plist",
                     ["Label": "com.unrelated", "Program": "/usr/local/bin/unrelated"])
        try fx.plist("Library/SystemExtensions/db.plist", ["extensions": [[
            "identifier": "com.example.vpn.tunnel",
            "categories": ["com.apple.system_extension.network_extension"],
            "state": "activated_enabled",
            "originPath": vpn.path + "/Contents/Library/SystemExtensions/tunnel.systemextension",
        ]]])
        let installedAt = Date(timeIntervalSince1970: 1_790_000_000)
        let packages = TimedPackages(
            receipts: [
                "com.example.vpn.pkg": ["Applications/Example VPN.app/Contents/Info.plist", "Library/Application Support/Example/config"],
                "com.example.drivers": ["Library/Application Support/ExampleDrivers/x"],
                "com.example.old": ["Library/Application Support/ExampleOld/x"],
            ],
            times: ["com.example.vpn.pkg": installedAt, "com.example.drivers": installedAt.addingTimeInterval(60),
                    "com.example.old": installedAt.addingTimeInterval(-86_400 * 30)]
        )

        let apps = [
            AppBundle(url: vpn, name: "Example VPN", bundleID: "com.example.vpn", teamID: "TEAM123456"),
            AppBundle(url: companion, name: "Example Tools", bundleID: "com.example.tools", teamID: "TEAM123456"),
            AppBundle(url: host, name: "Suite", bundleID: "com.suite.app", teamID: "OTHER12345"),
            AppBundle(url: helperApp, name: "Helper", bundleID: "com.example.helper", teamID: nil),
        ]
        let verified = CodeSignature(signer: .developerID("Example"), teamID: "TEAM123456")
        let insights = AppInsight.inspectAll(
            apps, sources: fx.sources(packages: packages, running: ["com.example.tools"],
                                      spotlight: SpotlightDates(lastUsed: ago(10), added: ago(30)),
                                      signatures: [vpn.path: verified]),
            now: now
        )
        #expect(insights.map(\.name) == ["Example VPN", "Example Tools", "Suite", "Helper"])

        let s = insights[0].signals
        #expect(s.version == "2.1")
        #expect(s.category == "Utilities")
        #expect(s.companions == ["Example Tools"])
        #expect(s.origin.packageIDs == ["com.example.vpn.pkg"])
        #expect(s.package.otherFiles == ["/Library/Application Support/Example"])
        #expect(s.package.relatedPackages == ["com.example.drivers"])
        #expect(Set(s.background.map(\.identifier)) == ["com.example.vpn.agent", "com.other.daemon", "com.example.vpn.tunnel"])
        #expect(s.background.first { $0.identifier == "com.other.daemon" }?.kind == .launchDaemon)
        #expect(s.size != nil)
        #expect(insights[0].origin == .installer(packageID: "com.example.vpn.pkg"))
        #expect(insights[0].recommendation.contains("VPN"))

        #expect(insights[1].signals.isRunning)
        #expect(insights[1].verdict == .recentlyUsed(days: 0))
        #expect(insights[3].verdict == .componentOf("Suite"))
        #expect(insights[2].signals.embeddedIn.isEmpty)
    }

    // MARK: Signature trust and background parts, on fixtures

    /// Companions and kernel extensions are linked by team ID, so only a verified one counts:
    /// a self-signed app claiming another developer's team gets neither.
    @Test func unverifiedTeamIDLinksNothing() throws {
        let fx = Fixture()
        let real = try fx.app("Applications/Real.app", id: "com.vendor.real")
        let fake = try fx.app("Applications/Fake.app", id: "com.fake.app")
        try fx.app("Library/Extensions/Driver.kext", id: "com.vendor.driver")
        let kext = fx.path("Library/Extensions/Driver.kext")
        let apps = [
            AppBundle(url: real, name: "Real", bundleID: "com.vendor.real", teamID: "VENDOR1234"),
            AppBundle(url: fake, name: "Fake", bundleID: "com.fake.app", teamID: nil),
        ]
        let signatures = [
            real.path: CodeSignature(signer: .developerID("Vendor"), teamID: "VENDOR1234"),
            // Says "Developer ID" and team VENDOR1234, but the chain does not verify.
            fake.path: CodeSignature(signer: .unverified("Developer ID Application: Vendor (VENDOR1234)"), teamID: nil),
            kext.path: CodeSignature(signer: .developerID("Vendor"), teamID: "VENDOR1234"),
        ]
        let insights = AppInsight.inspectAll(apps, sources: fx.sources(signatures: signatures), now: now)
        let realSignals = insights[0].signals
        #expect(realSignals.teamID == "VENDOR1234")
        #expect(realSignals.background.map(\.identifier) == ["com.vendor.driver"])
        #expect(realSignals.background.first?.kind == .kernelExtension)

        let fakeSignals = insights[1].signals
        #expect(fakeSignals.teamID == nil)
        #expect(fakeSignals.companions.isEmpty)
        #expect(fakeSignals.background.isEmpty)
        #expect(fakeSignals.vendor == nil)
    }

    /// A VPN from the App Store ships its tunnel as an app extension and starts at login from
    /// a helper inside the bundle (WireGuard); neither is a system extension.
    @Test func findsBackgroundPartsInsideTheBundle() throws {
        let fx = Fixture()
        let vpn = try fx.app("Applications/Tunnel.app", id: "com.example.tunnel")
        try fx.plist("Applications/Tunnel.app/Contents/PlugIns/Tunnel Extension.appex/Contents/Info.plist", [
            "CFBundleIdentifier": "com.example.tunnel.network-extension",
            "NSExtension": ["NSExtensionPointIdentifier": "com.apple.networkextension.packet-tunnel"],
        ])
        // A widget is an app extension too, but nothing that runs on its own.
        try fx.plist("Applications/Tunnel.app/Contents/PlugIns/Widget.appex/Contents/Info.plist", [
            "CFBundleIdentifier": "com.example.tunnel.widget",
            "NSExtension": ["NSExtensionPointIdentifier": "com.apple.widgetkit-extension"],
        ])
        try fx.app("Applications/Tunnel.app/Contents/Library/LoginItems/Tunnel Helper.app", id: "com.example.tunnel.login-helper")
        // An agent registered from inside the bundle (SMAppService).
        try fx.plist("Applications/Tunnel.app/Contents/Library/LaunchAgents/com.example.tunnel.agent.plist",
                     ["Label": "com.example.tunnel.agent", "BundleProgram": "Contents/MacOS/agent"])

        // The VPN configuration names the tunnel, and launchd has the agent loaded.
        try fx.plist("Library/Preferences/com.apple.networkextension.plist", [
            "$objects": ["$null", "Example VPN", "com.example.tunnel.network-extension"],
        ])

        let apps = [AppBundle(url: vpn, name: "Tunnel", bundleID: "com.example.tunnel", teamID: nil)]
        // Only the login helper runs, not the app itself.
        let insight = try #require(AppInsight.inspectAll(
            apps, sources: fx.sources(running: ["com.example.tunnel.login-helper"],
                                      spotlight: SpotlightDates(lastUsed: ago(300)),
                                      launchd: LaunchdJobs(user: ["com.example.tunnel.agent"], system: [])),
            now: now).first)
        #expect(insight.signals.background.allSatisfy { $0.isActive == true })
        let background = insight.signals.background
        #expect(Set(background.map(\.identifier)) == ["com.example.tunnel.network-extension", "com.example.tunnel.login-helper",
                                                      "com.example.tunnel.agent"])
        #expect(background.first { $0.identifier.hasSuffix("network-extension") }?.kind == .appExtension)
        #expect(background.first { $0.identifier.hasSuffix("login-helper") }?.kind == .loginItem)
        #expect(background.first { $0.identifier.hasSuffix("agent") }?.kind == .launchAgent)
        #expect(insight.signals.isRunning)
        guard case .runsInBackground(let phrases) = insight.verdict else {
            Issue.record("expected a background verdict, got \(insight.verdict)")
            return
        }
        #expect(phrases.contains("a network extension"))
        #expect(insight.recommendation.contains("VPN"))
        #expect(!insight.verdict.isRemovalCandidate)
    }

    /// A helper several apps embed says nothing about which of them is running.
    @Test func sharedHelperRunningDoesNotMakeEveryAppRun() throws {
        let fx = Fixture()
        let word = try fx.app("Applications/Word.app", id: "com.example.word")
        let excel = try fx.app("Applications/Excel.app", id: "com.example.excel")
        try fx.app("Applications/Word.app/Contents/Library/LoginItems/Reporter.app", id: "com.example.reporter")
        try fx.app("Applications/Excel.app/Contents/Library/LoginItems/Reporter.app", id: "com.example.reporter")
        try fx.app("Applications/Word.app/Contents/Library/LoginItems/Word Helper.app", id: "com.example.word.helper")
        let apps = [AppBundle(url: word, name: "Word", bundleID: "com.example.word", teamID: nil),
                    AppBundle(url: excel, name: "Excel", bundleID: "com.example.excel", teamID: nil)]

        let shared = AppInsight.inspectAll(apps, sources: fx.sources(running: ["com.example.reporter"]), now: now)
        #expect(shared.allSatisfy { !$0.signals.isRunning })
        #expect(shared.map(\.signals.runningIdentifiers) == [["com.example.word", "com.example.word.helper"], ["com.example.excel"]])
        let own = AppInsight.inspectAll(apps, sources: fx.sources(running: ["com.example.word.helper"]), now: now)
        #expect(own.map(\.signals.isRunning) == [true, false])
    }

    /// Parts shipped inside a bundle run only once macOS has them switched on (Teams carries a
    /// respawn agent it never loads; OneDrive a login item helper). Those that are off neither
    /// make the app a background app nor keep it from being unused.
    @Test func bundledBackgroundPartsCountOnlyWhenEnabled() throws {
        let fx = Fixture()
        let teams = try fx.app("Applications/Chat.app", id: "com.example.chat")
        try fx.plist("Applications/Chat.app/Contents/Library/LaunchAgents/com.example.chat.agent.plist",
                     ["Label": "com.example.chat.agent", "BundleProgram": "Contents/MacOS/agent"])
        try fx.plist("Applications/Chat.app/Contents/Library/LaunchAgents/com.example.chat.respawn.plist",
                     ["Label": "com.example.chat.respawn", "BundleProgram": "Contents/MacOS/respawn"])
        let drive = try fx.app("Applications/Drive.app", id: "com.example.drive")
        try fx.app("Applications/Drive.app/Contents/Library/LoginItems/Drive Launcher.app", id: "com.example.drive.launcher")
        try fx.plist("Applications/Drive.app/Contents/PlugIns/Tunnel.appex/Contents/Info.plist", [
            "CFBundleIdentifier": "com.example.drive.tunnel",
            "NSExtension": ["NSExtensionPointIdentifier": "com.apple.networkextension.packet-tunnel"],
        ])
        try fx.plist("Library/Preferences/com.apple.networkextension.plist", ["$objects": ["$null", "com.other.vpn"]])
        let daemon = try fx.app("Applications/Daemon.app", id: "com.example.daemon")
        try fx.plist("Applications/Daemon.app/Contents/Library/LaunchDaemons/com.example.daemon.helper.plist",
                     ["Label": "com.example.daemon.helper", "BundleProgram": "Contents/MacOS/helper"])
        // An agent installed into ~/Library/LaunchAgents is loaded at login by definition.
        let agent = try fx.app("Applications/Agent.app", id: "com.example.agentapp")
        try fx.plist("home/Library/LaunchAgents/com.example.agentapp.plist",
                     ["Label": "com.example.agentapp", "Program": agent.path + "/Contents/MacOS/agent"])

        let apps = [teams, drive, daemon, agent].map {
            AppBundle(url: $0, name: $0.deletingPathExtension().lastPathComponent,
                      bundleID: Bundle(url: $0)!.bundleIdentifier!, teamID: nil)
        }
        // launchd has the chat agent loaded; the system domain could not be read.
        let insights = AppInsight.inspectAll(
            apps, sources: fx.sources(spotlight: SpotlightDates(lastUsed: ago(300)),
                                      launchd: LaunchdJobs(user: ["com.example.chat.agent"], system: nil)),
            now: now)

        let chat = insights[0]
        #expect(chat.verdict == .runsInBackground(["a launch agent"]))
        #expect(chat.signals.background.first { $0.identifier == "com.example.chat.respawn" }?.isActive == false)
        #expect(chat.findings.contains { $0.contains("if enabled") && $0.contains("com.example.chat.respawn") })
        #expect(!chat.findings.contains { $0.hasPrefix("Runs in the background") && $0.contains("respawn") })

        let driveInsight = insights[1]
        #expect(driveInsight.verdict == .unused(days: 300))
        #expect(driveInsight.signals.background.allSatisfy { $0.isActive == false })
        #expect(driveInsight.findings.contains { $0.contains("if enabled") && $0.contains("com.example.drive.launcher") })

        // Unknown state inside the bundle is not taken as running either, nor stated as off.
        let daemonInsight = insights[2]
        #expect(daemonInsight.signals.background.first?.isActive == nil)
        #expect(daemonInsight.verdict == .unused(days: 300))
        #expect(daemonInsight.findings.contains {
            $0.hasPrefix("May run in the background if enabled (Poof could not read launchd)") && $0.contains("com.example.daemon.helper")
        })
        #expect(!daemonInsight.findings.contains { $0.contains("not enabled now") })
        #expect(!chat.findings.contains { $0.hasPrefix("May run") })

        #expect(insights[3].verdict == .runsInBackground(["a launch agent"]))
    }

    /// `launchctl print` output: only the top-level services block counts.
    @Test func parsesLaunchctlServices() {
        let output = """
        gui/501 = {
        \ttype = login
        \tservices = {
        \t\t   85417   (pe) \tcom.apple.syncdefaultsd
        \t\t       0      - \tcom.microsoft.teams2.agent
        \t\t    1251      0 \tcom.example.with space
        \t}
        \tendpoints = {
        \t\t 0xc5303    M   D   com.example.endpoint
        \t}
        }
        """
        #expect(LaunchdJobs.parseServices(output) == ["com.apple.syncdefaultsd", "com.microsoft.teams2.agent", "com.example.with space"])
        #expect(LaunchdJobs.parseServices("Could not find domain") == nil)
        let jobs = LaunchdJobs(user: ["a"], system: nil)
        #expect(jobs.isLoaded("a", daemon: false) == true)
        #expect(jobs.isLoaded("b", daemon: false) == false)
        #expect(jobs.isLoaded("a", daemon: true) == nil)
    }

    /// macOS starts an app's extensions on its own (WhatsApp's notification service runs for a
    /// push message): only the app or an `.app` helper inside it running means it is in use.
    @Test func runningExtensionsDoNotMeanTheAppRuns() throws {
        let fx = Fixture()
        let chat = try fx.app("Applications/Chat.app", id: "com.example.chat")
        try fx.app("Applications/Chat.app/Contents/PlugIns/ServiceExtension.appex", id: "com.example.chat.ServiceExtension")
        try fx.app("Applications/Chat.app/Contents/XPCServices/Worker.xpc", id: "com.example.chat.worker")
        try fx.app("Applications/Chat.app/Contents/Library/LoginItems/Chat Helper.app", id: "com.example.chat.helper")
        let apps = [AppBundle(url: chat, name: "Chat", bundleID: "com.example.chat", teamID: nil)]

        let extensions = AppInsight.inspectAll(
            apps, sources: fx.sources(running: ["com.example.chat.ServiceExtension", "com.example.chat.worker"]), now: now)
        #expect(extensions.map(\.signals.isRunning) == [false])
        let helper = AppInsight.inspectAll(apps, sources: fx.sources(running: ["com.example.chat.helper"]), now: now)
        #expect(helper.map(\.signals.isRunning) == [true])

        // The app's own live check uses the same rule, and the insight carries the IDs.
        #expect(apps[0].runningIdentifiers(among: apps) == ["com.example.chat", "com.example.chat.helper"])
        #expect(helper.first?.signals.runningIdentifiers == ["com.example.chat", "com.example.chat.helper"])
    }

    /// `poof why Telegram.app` run from /Applications gives a relative path; the app must not
    /// be its own companion or host.
    @Test func sameAppByAnotherPathIsNotItsOwnCompanion() throws {
        let fx = Fixture()
        let app = try fx.app("Applications/Chat.app", id: "com.example.chat")
        let other = try fx.app("Applications/Other.app", id: "com.example.other")
        let indirect = URL(fileURLWithPath: fx.path("Applications/../Applications/Chat.app").path)
        let found = try AppBundle.find(indirect.path)
        #expect(found.url.path == app.standardizedFileURL.path)

        let relative = URL(fileURLWithPath: "Chat.app", relativeTo: fx.path("Applications"))
        let signature = CodeSignature(signer: .developerID("Example"), teamID: "TEAM123456")
        let installed = [AppBundle(url: app, name: "Chat", bundleID: "com.example.chat", teamID: "TEAM123456"),
                         AppBundle(url: other, name: "Other", bundleID: "com.example.other", teamID: "TEAM123456")]
        let insight = AppInsight.inspect(
            AppBundle(url: relative, name: "Chat", bundleID: "com.example.chat", teamID: "TEAM123456"), installed: installed,
            sources: fx.sources(signatures: [app.path: signature, other.path: signature]), now: now)
        #expect(insight.signals.companions == ["Other"])
        #expect(insight.signals.embeddedIn.isEmpty)
    }

    /// Anyone can write "com.apple." into an Info.plist: only Apple's signature (its own or the
    /// App Store's) makes an app Apple's.
    @Test func appleBundleIDNeedsAppleSignature() throws {
        #expect(AppBundle.isApples(bundleID: "com.apple.Safari", signer: .apple))
        #expect(AppBundle.isApples(bundleID: "com.apple.dt.Xcode", signer: .appStore))
        #expect(!AppBundle.isApples(bundleID: "com.apple.Safari", signer: .adHoc))
        #expect(!AppBundle.isApples(bundleID: "com.apple.Safari", signer: .developerID("Someone")))
        #expect(!AppBundle.isApples(bundleID: "com.example.app", signer: .apple))

        let fx = Fixture()
        let fake = try fx.app("Applications/Updater.app", id: "com.apple.SoftwareUpdater")
        let packages = TimedPackages(receipts: ["com.apple.softwareupdater.pkg": ["Applications/Updater.app/Contents/Info.plist"]])
        let insight = try #require(AppInsight.inspectAll(
            [AppBundle(url: fake, name: "Updater", bundleID: "com.apple.SoftwareUpdater", teamID: nil)],
            sources: fx.sources(packages: packages), now: now).first)
        // Its installer receipt is read like any other app's, and the claim is pointed out.
        #expect(insight.origin == .installer(packageID: "com.apple.softwareupdater.pkg"))
        #expect(insight.verdict != .partOfMacOS)
        #expect(insight.findings.contains { $0.contains("claims an Apple bundle ID (com.apple.SoftwareUpdater) but is not signed by Apple") })
    }

    // MARK: Terminal output

    @Test func sanitizesTextForTheTerminal() {
        #expect("Plain name 1.2".sanitizedForTerminal == "Plain name 1.2")
        #expect("Café 日本".sanitizedForTerminal == "Café 日本")
        // An ESC sequence that would clear the line and hide what follows.
        #expect("Evil\u{1B}[2K\u{1B}[1A".sanitizedForTerminal == "Evil\u{FFFD}[2K\u{FFFD}[1A")
        #expect("a\tb\nc\rd".sanitizedForTerminal == "a b c d")
        #expect("bell\u{07} del\u{7F} c1\u{9B}".sanitizedForTerminal == "bell\u{FFFD} del\u{FFFD} c1\u{FFFD}")
        #expect("abc\u{202E}fdp.exe".sanitizedForTerminal == "abc\u{FFFD}fdp.exe")
        // JSON escapes ESC as \u001b, which decodes back into a real ESC.
        let decoded = try? JSONSerialization.jsonObject(with: Data(#"{"name": "x\u001b]0;pwned\u0007"}"#.utf8)) as? [String: String]
        #expect(decoded?["name"]?.sanitizedForTerminal == "x\u{FFFD}]0;pwned\u{FFFD}")
    }
}
