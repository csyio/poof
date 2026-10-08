import Foundation
import Testing
@testable import PoofCore

struct BrowserExtensionTests {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("ext-\(UUID())")
    let now = Date(timeIntervalSince1970: 1_791_000_000)  // October 2026

    var support: URL { home.appendingPathComponent("Library/Application Support") }
    var apps: URL { home.appendingPathComponent("Applications") }

    @discardableResult
    func write(_ url: URL, _ text: String) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    func writeJSON(_ url: URL, _ object: Any) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }

    /// A fake .app whose Info.plist has the given bundle ID, optionally with plug-ins.
    @discardableResult
    func makeApp(_ name: String, bundleID: String, appexes: [(name: String, point: String)] = []) throws -> URL {
        let app = apps.appendingPathComponent("\(name).app")
        try writePlist(app.appendingPathComponent("Contents/Info.plist"), ["CFBundleIdentifier": bundleID])
        for appex in appexes {
            try writePlist(app.appendingPathComponent("Contents/PlugIns/\(appex.name).appex/Contents/Info.plist"), [
                "CFBundleIdentifier": "\(bundleID).\(appex.name.replacingOccurrences(of: " ", with: ""))",
                "CFBundleName": appex.name,
                "CFBundleShortVersionString": "2.1",
                "NSExtension": ["NSExtensionPointIdentifier": appex.point],
            ])
            try write(app.appendingPathComponent("Contents/PlugIns/\(appex.name).appex/Contents/MacOS/bin"), String(repeating: "x", count: 5000))
        }
        return app
    }

    func writePlist(_ url: URL, _ dict: [String: Any]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (dict as NSDictionary).write(to: url)
    }

    func scanner(apps appURLs: [URL]) -> BrowserExtensionScanner {
        BrowserExtensionScanner(home: home, appURLs: appURLs, now: now)
    }

    /// Chromium timestamp (microseconds since 1601) for a Unix time.
    func chrome(_ unix: Double) -> String { String(Int64((unix + 11_644_473_600) * 1_000_000)) }

    func chromeExtension(_ profile: String, id: String, version: String = "1.0", manifest: [String: Any]) throws {
        let dir = support.appendingPathComponent("Google/Chrome/\(profile)/Extensions/\(id)/\(version)_0")
        try writeJSON(dir.appendingPathComponent("manifest.json"), manifest.merging(["version": version]) { a, _ in a })
        try write(dir.appendingPathComponent("background.js"), "// code")
    }

    let blocker = String(repeating: "a", count: 32)
    let sideloaded = String(repeating: "b", count: 32)
    let disabled = String(repeating: "c", count: 32)
    let component = String(repeating: "d", count: 32)
    let old = String(repeating: "e", count: 32)

    func buildChrome() throws {
        let chrome = support.appendingPathComponent("Google/Chrome")
        try writeJSON(chrome.appendingPathComponent("Local State"), [
            "profile": ["info_cache": ["Default": ["name": "Personal"], "Profile 1": ["name": "Work"]]],
        ])

        // A localized name, with an older version folder next to the live one.
        try chromeExtension("Default", id: blocker, version: "0.9", manifest: ["name": "__MSG_appName__", "default_locale": "en"])
        try chromeExtension("Default", id: blocker, version: "1.2", manifest: ["name": "__MSG_APPNAME__", "default_locale": "en"])
        try writeJSON(chrome.appendingPathComponent("Default/Extensions/\(blocker)/1.2_0/_locales/en/messages.json"),
                      ["appName": ["message": "Fancy Blocker"]])
        try chromeExtension("Default", id: sideloaded, manifest: ["name": "Dev Helper"])
        try chromeExtension("Default", id: disabled, manifest: ["name": "Quiet One"])
        try chromeExtension("Default", id: component, manifest: ["name": "Chrome Internal"])
        try chromeExtension("Profile 1", id: old, manifest: ["name": "Forgotten"])
        try write(chrome.appendingPathComponent("Default/Extensions/Temp/junk"), "x")

        func record(_ fields: [String: Any]) -> [String: Any] { ["path": "x", "location": 1].merging(fields) { _, new in new } }
        try writeJSON(chrome.appendingPathComponent("Default/Secure Preferences"), [
            "extensions": ["settings": [
                blocker: record(["state": 1, "from_webstore": true, "last_update_time": self.chrome(1_780_000_000)]),
                sideloaded: record(["state": 1, "location": 4]),
                disabled: record(["state": 0, "disable_reasons": 1, "from_webstore": true,
                                  "last_update_time": self.chrome(1_780_000_000)]),
                component: record(["state": 1, "location": 5]),
            ]],
        ])
        // Older Chrome kept some records in Preferences instead.
        try writeJSON(chrome.appendingPathComponent("Profile 1/Preferences"), [
            "extensions": ["settings": [old: record(["state": 1, "from_webstore": true, "last_update_time": self.chrome(1_559_347_200)])]],
        ])
    }

    @Test func listsChromeProfilesWithNamesStateAndSource() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        try buildChrome()
        let chrome = try makeApp("Google Chrome", bundleID: "com.google.Chrome")

        let installs = scanner(apps: [chrome]).scan()
        let browser = try #require(installs.first { $0.name == "Google Chrome" })
        #expect(browser.isInstalled && browser.note == nil)
        #expect(browser.profiles.map(\.name) == ["Personal", "Work"])
        #expect(browser.profiles.map(\.directory) == ["Default", "Profile 1"])

        let personal = browser.profiles[0].extensions
        // The component extension is built in and left out; the rest are sorted by name.
        #expect(personal.map(\.name) == ["Dev Helper", "Fancy Blocker", "Quiet One"])
        let blocker = try #require(personal.first { $0.extensionID == self.blocker })
        #expect(blocker.version == "1.2")
        #expect(blocker.state == .enabled && blocker.source == .webStore)
        #expect(blocker.flags.isEmpty)
        #expect(blocker.size > 0)
        #expect(blocker.path.hasSuffix("Extensions/\(self.blocker)"))

        let dev = try #require(personal.first { $0.extensionID == sideloaded })
        #expect(dev.source == .sideloaded)
        #expect(dev.flags.map(\.kind) == [.sideloaded])

        let quiet = try #require(personal.first { $0.extensionID == disabled })
        #expect(quiet.state == .disabled)
        #expect(quiet.flags.map(\.kind) == [.disabled])
    }

    @Test func flagsExtensionsThatWereNotUpdatedForYears() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        try buildChrome()
        let chrome = try makeApp("Google Chrome", bundleID: "com.google.Chrome")

        let work = try #require(scanner(apps: [chrome]).scan().first?.profiles.last)
        let forgotten = try #require(work.extensions.first)
        #expect(forgotten.name == "Forgotten")
        #expect(forgotten.flags.map(\.kind) == [.notUpdated])
        #expect(forgotten.flags.first?.message == "Not updated since 2019-06.")
    }

    @Test func marksProfilesOfARemovedBrowserAsLeftovers() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        try buildChrome()

        // No Chrome app in the list: the profile folder is all that is left.
        let browser = try #require(scanner(apps: []).scan().first)
        #expect(!browser.isInstalled)
        #expect(browser.note?.contains("not installed") == true)
        #expect(browser.profiles.flatMap(\.extensions).allSatisfy { $0.flags.contains { $0.kind == .browserRemoved } })

        // The browser's note covers "not installed": it is neither shown per extension nor counted as a flag.
        let all = browser.profiles.flatMap(\.extensions)
        #expect(all.allSatisfy { !$0.shownFlags.contains { $0.kind == .browserRemoved } })
        let blockerItem = try #require(all.first { $0.extensionID == blocker })
        #expect(blockerItem.flags.map(\.kind) == [.browserRemoved])
        #expect(!blockerItem.isFlagged)
        #expect(browser.flaggedCount == all.filter { $0.flags.contains { $0.kind != .browserRemoved } }.count)
        #expect(browser.flaggedCount < all.count)
    }

    @Test func treatsMissingPreferencesAsUnknownAndKeepsTheExtension() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        try chromeExtension("Default", id: blocker, manifest: ["name": "Bare"])
        let chrome = try makeApp("Google Chrome", bundleID: "com.google.Chrome")

        let item = try #require(scanner(apps: [chrome]).scan().first?.profiles.first?.extensions.first)
        #expect(item.name == "Bare")
        #expect(item.state == .unknown && item.source == .unknown)
        #expect(item.flags.isEmpty)
    }

    @Test func readsManifestsWithAByteOrderMarkAndFallsBackToTheIDForUnresolvedNames() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let dir = support.appendingPathComponent("Microsoft Edge/Default/Extensions")
        try write(dir.appendingPathComponent("\(blocker)/2.0_0/manifest.json"),
                  "\u{FEFF}{\"name\": \"__MSG_missing__\", \"version\": \"2.0\", \"default_locale\": \"de\"}")
        try write(dir.appendingPathComponent("\(sideloaded)/1.0_0/manifest.json"), "\u{FEFF}{\"name\": \"Plain\", \"version\": \"1.0\"}")
        let edge = try makeApp("Microsoft Edge", bundleID: "com.microsoft.edgemac")

        let items = try #require(scanner(apps: [edge]).scan().first?.profiles.first?.extensions)
        #expect(Set(items.map(\.name)) == ["Plain", blocker])
    }

    @Test func classifiesPolicyAndStoreSourcesFromRecords() {
        func source(_ record: [String: Any], update: String? = nil) -> ExtensionSource {
            let manifest: [String: Any] = update.map { ["update_url": $0] } ?? [:]
            return BrowserExtensionScanner.chromiumSource(record: record, manifest: manifest, location: (record["location"] as? Int))
                .source
        }
        #expect(source(["location": 9]) == .policy)
        #expect(source(["location": 4]) == .sideloaded)
        #expect(source(["location": 1, "from_webstore": true]) == .webStore)
        #expect(source(["location": 1], update: "https://edge.microsoft.com/extensionwebstorebase/v1/crx") == .webStore)
        #expect(source(["location": 1], update: "https://example.com/update.xml") == .sideloaded)
        // Opera's store serves updates from its own host.
        #expect(source(["location": 1], update: "https://extension-updates.opera.com/api/omaha/update/") == .webStore)
        #expect(source(["location": 1], update: "https://addons.opera.com/extensions/update") == .webStore)
        #expect(source(["location": 2]) == .otherProgram)
    }

    @Test func readsFirefoxProfilesFromProfilesIni() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let firefox = support.appendingPathComponent("Firefox")
        try write(firefox.appendingPathComponent("profiles.ini"), """
        [Install2DB4CB2F2D4C4D4C]
        Default=Profiles/abc.default-release
        Locked=1

        [Profile1]
        Name=work
        IsRelative=1
        Path=Profiles/def.work

        [Profile0]
        Name=default-release
        IsRelative=1
        Path=Profiles/abc.default-release
        Default=1

        [General]
        StartWithLastProfile=1
        Version=2
        """)
        let profile = firefox.appendingPathComponent("Profiles/abc.default-release")
        try write(profile.appendingPathComponent("extensions/ublock@example.org.xpi"), String(repeating: "z", count: 8000))
        try write(profile.appendingPathComponent("extensions/local@example.org.xpi"), "x")
        func addon(_ id: String, _ name: String, _ extra: [String: Any] = [:]) -> [String: Any] {
            ["id": id, "type": "extension", "location": "app-profile", "version": "1.5", "active": true,
             "userDisabled": false, "appDisabled": false, "signedState": 2,
             "defaultLocale": ["name": name], "installDate": 1_600_000_000_000, "updateDate": 1_790_000_000_000,
             "sourceURI": "https://addons.mozilla.org/firefox/downloads/file/1/x.xpi"].merging(extra) { _, new in new }
        }
        try writeJSON(profile.appendingPathComponent("extensions.json"), ["addons": [
            addon("ublock@example.org", "Blocker"),
            addon("off@example.org", "Switched Off", ["active": false, "userDisabled": true]),
            addon("local@example.org", "Local File", ["signedState": 0, "sourceURI": "file:///tmp/local.xpi",
                                                       "updateDate": 1_500_000_000_000]),
            addon("theme@example.org", "A Theme", ["type": "theme"]),
            addon("builtin@example.org", "Built In", ["location": "app-builtin"]),
        ]])
        let app = try makeApp("Firefox", bundleID: "org.mozilla.firefox")

        let browser = try #require(scanner(apps: [app]).scan().first { $0.name == "Firefox" })
        #expect(browser.isInstalled)
        // The profile that has not been started yet has no extensions.json and lists nothing.
        #expect(browser.profiles.map(\.name) == ["default-release", "work"])
        #expect(browser.profiles.last?.extensions.isEmpty == true)
        let main = try #require(browser.profiles.first { $0.name == "default-release" })
        #expect(main.extensions.map(\.name) == ["Blocker", "Local File", "Switched Off"])

        let blocker = main.extensions[0]
        #expect(blocker.state == .enabled && blocker.source == .webStore && blocker.flags.isEmpty)
        #expect(blocker.size >= 8000)

        let local = main.extensions[1]
        #expect(local.source == .sideloaded)
        #expect(Set(local.flags.map(\.kind)) == [.sideloaded, .unsigned])

        let off = main.extensions[2]
        #expect(off.state == .disabled)
        #expect(off.flags.map(\.kind) == [.disabled])
    }

    /// signedState: 0 is unsigned, -2 a broken signature, -1 not checked yet, 2 signed.
    @Test func flagsOnlyFirefoxAddonsWithoutAValidSignature() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let firefox = support.appendingPathComponent("Firefox")
        try write(firefox.appendingPathComponent("profiles.ini"), "[Profile0]\nName=main\nIsRelative=1\nPath=Profiles/p.main\n")
        let profile = firefox.appendingPathComponent("Profiles/p.main")
        func addon(_ id: String, signed: Int) -> [String: Any] {
            ["id": id, "type": "extension", "location": "app-profile", "version": "1", "active": true, "signedState": signed,
             "defaultLocale": ["name": id], "updateDate": 1_790_000_000_000,
             "sourceURI": "https://addons.mozilla.org/firefox/downloads/file/1/x.xpi"]
        }
        try writeJSON(profile.appendingPathComponent("extensions.json"), ["addons": [
            addon("missing@x", signed: 0), addon("broken@x", signed: -2), addon("unknown@x", signed: -1), addon("signed@x", signed: 2),
        ]])
        let app = try makeApp("Firefox", bundleID: "org.mozilla.firefox")
        let items = try #require(scanner(apps: [app]).scan().first?.profiles.first?.extensions)
        let unsigned = Set(items.filter { $0.flags.contains { $0.kind == .unsigned } }.map(\.extensionID))
        #expect(unsigned == ["missing@x", "broken@x"])
    }

    /// Add-ons other programs drop into the shared Mozilla folders load in every profile; they
    /// are listed and flagged. extensions.json is only a file, so its ids and paths are checked.
    @Test func listsFirefoxAddonsFromSharedFoldersAndDistrustsRecordedPaths() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let firefox = support.appendingPathComponent("Firefox")
        try write(firefox.appendingPathComponent("profiles.ini"), "[Profile0]\nName=main\nIsRelative=1\nPath=Profiles/p.main\n")
        let profile = firefox.appendingPathComponent("Profiles/p.main")
        let shared = support.appendingPathComponent("Mozilla/Extensions/{ec8030f7-c20a-464f-9b0e-13a3a9e97384}/dropped@vendor.xpi")
        try write(shared, String(repeating: "d", count: 3000))
        // A big folder outside the profile that a forged path points at.
        try write(home.appendingPathComponent("Documents/big/file"), String(repeating: "b", count: 50_000))
        func addon(_ id: String, _ location: String, path: String? = nil) -> [String: Any] {
            var entry: [String: Any] = ["id": id, "type": "extension", "location": location, "version": "1", "active": true,
                                        "signedState": 2, "defaultLocale": ["name": id], "updateDate": 1_790_000_000_000]
            entry["path"] = path
            return entry
        }
        let app = try makeApp("Firefox", bundleID: "org.mozilla.firefox")
        // app-global add-ons sit inside the Firefox app, app-system-local ones in /Library.
        let global = try write(app.appendingPathComponent("Contents/Resources/extensions/global@vendor.xpi"), String(repeating: "g", count: 2000))
        let systemLibrary = home.appendingPathComponent("SystemLibrary")
        let local = try write(systemLibrary.appendingPathComponent("Application Support/Mozilla/Extensions/x/local@vendor.xpi"),
                              String(repeating: "l", count: 1000))
        try writeJSON(profile.appendingPathComponent("extensions.json"), ["addons": [
            addon("dropped@vendor", "app-system-user", path: shared.path),
            addon("global@vendor", "app-global", path: global.path),
            addon("local@vendor", "app-system-local", path: local.path),
            // Shared add-ons whose file is not where Firefox keeps them are skipped, not shown with a made-up path.
            addon("misplaced@vendor", "app-global", path: "/Library/Application Support/Mozilla/Extensions/x/misplaced@vendor.xpi"),
            addon("forgedlocal@vendor", "app-system-local", path: home.appendingPathComponent("Documents/big").path),
            addon("gone@vendor", "app-system-user", path: support.appendingPathComponent("Mozilla/Extensions/x/gone@vendor.xpi").path),
            addon("forged@x", "app-profile", path: home.appendingPathComponent("Documents/big").path),
            addon("climb@x", "app-profile", path: profile.appendingPathComponent("extensions/../../../../Documents/big").path),
            addon("../../escape", "app-profile"),
            addon("a/b", "app-profile"),
            addon("builtin@mozilla.org", "app-builtin"),
            addon("system@mozilla.org", "app-system-defaults"),
        ]])
        var firefoxScanner = scanner(apps: [app])
        firefoxScanner.systemLibrary = systemLibrary
        let items = try #require(firefoxScanner.scan().first?.profiles.first?.extensions)
        #expect(Set(items.map(\.extensionID)) == ["dropped@vendor", "global@vendor", "local@vendor", "forged@x", "climb@x"])
        #expect(items.first { $0.extensionID == "global@vendor" }?.path == global.path)
        #expect(items.first { $0.extensionID == "local@vendor" }?.path == local.path)
        #expect(items.first { $0.extensionID == "local@vendor" }?.size ?? 0 >= 1000)

        let dropped = try #require(items.first { $0.extensionID == "dropped@vendor" })
        #expect(dropped.source == .otherProgram)
        #expect(dropped.flags.map(\.kind) == [.sideloaded])
        #expect(dropped.path == shared.path)
        #expect(dropped.size >= 3000)
        #expect(items.first { $0.extensionID == "global@vendor" }?.source == .otherProgram)

        // A recorded path outside the profile is neither shown nor measured.
        for id in ["forged@x", "climb@x"] {
            let forged = try #require(items.first { $0.extensionID == id })
            #expect(forged.path == profile.appendingPathComponent("extensions/\(id).xpi").path)
            #expect(forged.size == 0)
        }
    }

    /// Unpacked (location 4) and command-line (8) extensions stay where they were loaded from.
    @Test func listsUnpackedChromiumExtensionsFromTheirRecordedFolder() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let chrome = support.appendingPathComponent("Google/Chrome")
        let devFolder = home.appendingPathComponent("Projects/my-extension")
        try writeJSON(devFolder.appendingPathComponent("manifest.json"), ["name": "My Dev Extension", "version": "0.3"])
        try write(devFolder.appendingPathComponent("content.js"), String(repeating: "j", count: 4000))
        let unpacked = String(repeating: "f", count: 32)
        let commandLine = String(repeating: "g", count: 32)
        let wholeDisk = String(repeating: "h", count: 32)
        try writeJSON(chrome.appendingPathComponent("Default/Secure Preferences"), [
            "extensions": ["settings": [
                unpacked: ["location": 4, "path": devFolder.path, "state": 1],
                // The folder is gone; the record still has the manifest.
                commandLine: ["location": 8, "path": home.appendingPathComponent("gone").path,
                              "manifest": ["name": "From Command Line", "version": "1.0"]],
                // A path at a folder with no manifest is never measured.
                wholeDisk: ["location": 4, "path": "/", "manifest": ["name": "Odd", "version": "1"]],
            ]],
        ])
        let app = try makeApp("Google Chrome", bundleID: "com.google.Chrome")
        let items = try #require(scanner(apps: [app]).scan().first?.profiles.first?.extensions)
        #expect(items.map(\.name) == ["From Command Line", "My Dev Extension", "Odd"])

        let dev = try #require(items.first { $0.extensionID == unpacked })
        #expect(dev.path == devFolder.path)
        #expect(dev.version == "0.3")
        #expect(dev.source == .sideloaded && dev.state == .enabled)
        #expect(dev.flags.map(\.kind) == [.sideloaded])
        #expect(dev.size >= 4000)
        #expect(items.first { $0.extensionID == commandLine }?.size == 0)
        #expect(items.first { $0.extensionID == wholeDisk }?.size == 0)
    }

    @Test func listsSafariExtensionsProvidedByInstalledApps() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let withExtension = try makeApp("Notes Plus", bundleID: "com.example.notesplus", appexes: [
            (name: "Notes Plus Safari", point: "com.apple.Safari.web-extension"),
            (name: "Notes Widget", point: "com.apple.widgetkit-extension"),
        ])
        let plain = try makeApp("Plain App", bundleID: "com.example.plain")

        let install = try #require(scanner(apps: [withExtension, plain]).scan().first { $0.family == .safari })
        let items = try #require(install.profiles.first?.extensions)
        #expect(items.count == 1)
        let item = items[0]
        #expect(item.name == "Notes Plus Safari")
        #expect(item.kind == "Safari web extension")
        #expect(item.providedBy == "Notes Plus")
        #expect(item.state == .unknown && item.source == .app)
        #expect(item.version == "2.1")
        #expect(item.size >= 5000)
        #expect(install.note?.contains("removing the app removes the extension") == true)
    }

    @Test func reportsAFolderMacOSWillNotLetItRead() throws {
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: support.appendingPathComponent("Vivaldi").path)
            try? FileManager.default.removeItem(at: home)
        }
        let folder = support.appendingPathComponent("Vivaldi")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: folder.path)
        guard geteuid() != 0 else { return }  // root reads everything

        let vivaldi = try makeApp("Vivaldi", bundleID: "com.vivaldi.Vivaldi")
        let browser = try #require(scanner(apps: [vivaldi]).scan().first)
        #expect(browser.profiles.isEmpty)
        #expect(browser.note?.contains("Full Disk Access") == true)
        #expect(browser.note?.contains("leftover") == false)
    }

    @Test func skipsBrowsersWithNothingToList() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: support.appendingPathComponent("Microsoft Edge-headless"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: support.appendingPathComponent("Chromium"), withIntermediateDirectories: true)
        #expect(scanner(apps: []).scan().isEmpty)
    }

    @Test func encodesToJSONWithTheFlagsAndDates() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        try buildChrome()
        let chrome = try makeApp("Google Chrome", bundleID: "com.google.Chrome")
        let installs = scanner(apps: [chrome]).scan()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(installs)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode([BrowserInstall].self, from: data)
        #expect(decoded == installs)
    }
}
