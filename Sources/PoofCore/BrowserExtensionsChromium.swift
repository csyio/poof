import Foundation

/// Chromium-based browsers keep one folder per profile under Application Support, with
/// `Extensions/<id>/<version>/manifest.json` for the files and `Secure Preferences` (older
/// versions: `Preferences`) for whether each extension is on and where it came from.
extension BrowserExtensionScanner {
    struct ChromiumBrowser {
        let name: String
        /// Relative to ~/Library/Application Support.
        let folder: String
        let bundleIDs: [String]
        let appNames: [String]
    }

    static let chromiumBrowsers: [ChromiumBrowser] = [
        .init(name: "Google Chrome", folder: "Google/Chrome", bundleIDs: ["com.google.Chrome"], appNames: ["Google Chrome"]),
        .init(name: "Google Chrome Beta", folder: "Google/Chrome Beta", bundleIDs: ["com.google.Chrome.beta"], appNames: ["Google Chrome Beta"]),
        .init(name: "Google Chrome Canary", folder: "Google/Chrome Canary", bundleIDs: ["com.google.Chrome.canary"], appNames: ["Google Chrome Canary"]),
        .init(name: "Google Chrome Dev", folder: "Google/Chrome Dev", bundleIDs: ["com.google.Chrome.dev"], appNames: ["Google Chrome Dev"]),
        .init(name: "Chromium", folder: "Chromium", bundleIDs: ["org.chromium.Chromium"], appNames: ["Chromium"]),
        .init(name: "Microsoft Edge", folder: "Microsoft Edge", bundleIDs: ["com.microsoft.edgemac"], appNames: ["Microsoft Edge"]),
        .init(name: "Microsoft Edge Beta", folder: "Microsoft Edge Beta", bundleIDs: ["com.microsoft.edgemac.Beta"], appNames: ["Microsoft Edge Beta"]),
        .init(name: "Microsoft Edge Dev", folder: "Microsoft Edge Dev", bundleIDs: ["com.microsoft.edgemac.Dev"], appNames: ["Microsoft Edge Dev"]),
        .init(name: "Microsoft Edge Canary", folder: "Microsoft Edge Canary", bundleIDs: ["com.microsoft.edgemac.Canary"], appNames: ["Microsoft Edge Canary"]),
        .init(name: "Brave", folder: "BraveSoftware/Brave-Browser", bundleIDs: ["com.brave.Browser"], appNames: ["Brave Browser"]),
        .init(name: "Brave Beta", folder: "BraveSoftware/Brave-Browser-Beta", bundleIDs: ["com.brave.Browser.beta"], appNames: ["Brave Browser Beta"]),
        .init(name: "Brave Nightly", folder: "BraveSoftware/Brave-Browser-Nightly", bundleIDs: ["com.brave.Browser.nightly"], appNames: ["Brave Browser Nightly"]),
        .init(name: "Arc", folder: "Arc/User Data", bundleIDs: ["company.thebrowser.Browser"], appNames: ["Arc"]),
        .init(name: "Vivaldi", folder: "Vivaldi", bundleIDs: ["com.vivaldi.Vivaldi"], appNames: ["Vivaldi"]),
        .init(name: "Opera", folder: "com.operasoftware.Opera", bundleIDs: ["com.operasoftware.Opera"], appNames: ["Opera"]),
        .init(name: "Opera GX", folder: "com.operasoftware.OperaGX", bundleIDs: ["com.operasoftware.OperaGX"], appNames: ["Opera GX"]),
    ]

    func scanChromium() -> [BrowserInstall] {
        Self.chromiumBrowsers.compactMap(scan(chromium:))
    }

    func scan(chromium browser: ChromiumBrowser) -> BrowserInstall? {
        let fm = FileManager.default
        let root = applicationSupport.appendingPathComponent(browser.folder)
        guard fm.fileExists(atPath: root.path) else { return nil }
        let app = installedApp(bundleIDs: browser.bundleIDs, names: browser.appNames)

        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return BrowserInstall(name: browser.name, family: .chromium, isInstalled: app != nil, appPath: app?.path,
                                  dataPath: root.path, profiles: [], note: Self.unreadableNote(browser.name, installed: app != nil))
        }

        var folders = entries.filter { entry in
            let name = entry.lastPathComponent
            guard name == "Default" || (name.hasPrefix("Profile ") && Int(name.dropFirst(8)) != nil) else { return false }
            return (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
        // Opera keeps its single profile directly in the browser folder.
        if folders.isEmpty, fm.fileExists(atPath: root.appendingPathComponent("Preferences").path)
            || fm.fileExists(atPath: root.appendingPathComponent("Extensions").path) {
            folders = [root]
        }
        guard !folders.isEmpty else { return nil }

        let names = (Self.json(at: root.appendingPathComponent("Local State"))?["profile"] as? [String: Any])?["info_cache"] as? [String: Any]
        let profiles = folders
            .sorted { Self.profileOrder($0.lastPathComponent) < Self.profileOrder($1.lastPathComponent) }
            .map { folder -> BrowserProfile in
                let directory = folder == root ? "(browser folder)" : folder.lastPathComponent
                let label = ((names?[folder.lastPathComponent] as? [String: Any])?["name"] as? String) ?? directory
                return BrowserProfile(
                    name: label, directory: directory, path: folder.path,
                    extensions: chromiumExtensions(in: folder, browser: browser.name, browserRemoved: app == nil))
            }
        return BrowserInstall(name: browser.name, family: .chromium, isInstalled: app != nil, appPath: app?.path,
                              dataPath: root.path, profiles: profiles, note: app == nil ? Self.removedNote(browser.name) : nil)
    }

    private static func profileOrder(_ name: String) -> Int {
        name == "Default" ? 0 : (Int(name.dropFirst(8)) ?? Int.max - 1) + 1
    }

    func chromiumExtensions(in profile: URL, browser: String, browserRemoved: Bool) -> [BrowserExtension] {
        let fm = FileManager.default
        let extensionsDir = profile.appendingPathComponent("Extensions")
        let ids = ((try? fm.contentsOfDirectory(atPath: extensionsDir.path)) ?? [])
            .filter(Self.isChromiumID)
        let settings = Self.chromiumSettings(in: profile)

        var found = ids.compactMap { id -> BrowserExtension? in
            let folder = extensionsDir.appendingPathComponent(id)
            // Several versions can sit side by side while an update is pending; the newest is live.
            guard let version = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? [])
                .filter({ !$0.hasPrefix(".") })
                .max(by: { $0.compare($1, options: .numeric) == .orderedAscending }) else { return nil }
            let versionDir = folder.appendingPathComponent(version)
            let record = settings?[id] as? [String: Any]
            let manifest = Self.json(at: versionDir.appendingPathComponent("manifest.json"))
                ?? (record?["manifest"] as? [String: Any])
            guard let manifest else { return nil }
            return chromiumExtension(id: id, record: record, manifest: manifest, versionDir: versionDir, version: version,
                                     folder: folder, size: LeftoverScanner.size(of: folder),
                                     browser: browser, browserRemoved: browserRemoved)
        }

        // Unpacked and command-line extensions stay in the folder they were loaded from, which
        // `extensions.settings.<id>.path` records; nothing of them is in the Extensions folder.
        let listed = Set(ids)
        for (id, value) in settings ?? [:] where !listed.contains(id) && Self.isChromiumID(id) {
            guard let record = value as? [String: Any],
                  let location = (record["location"] as? NSNumber)?.intValue, location == 4 || location == 8,
                  let path = record["path"] as? String, !path.isEmpty else { continue }
            // Chromium stores these paths absolute; a relative one would start at its install folder.
            let folders = path.hasPrefix("/")
                ? [URL(fileURLWithPath: path)]
                : [extensionsDir.appendingPathComponent(path), profile.appendingPathComponent(path)]
            let folder = (folders.first { fm.fileExists(atPath: $0.appendingPathComponent("manifest.json").path) } ?? folders[0])
                .standardizedFileURL
            let manifestFile = Self.json(at: folder.appendingPathComponent("manifest.json"))
            guard let manifest = manifestFile ?? (record["manifest"] as? [String: Any]) else { continue }
            // Only a folder that really holds the extension is measured; the recorded path could
            // point anywhere, even at the whole disk.
            let size = manifestFile != nil ? LeftoverScanner.size(of: folder) : 0
            if let item = chromiumExtension(id: id, record: record, manifest: manifest, versionDir: folder, version: "",
                                            folder: folder, size: size, browser: browser, browserRemoved: browserRemoved) {
                found.append(item)
            }
        }
        return Self.sorted(found)
    }

    /// Chromium extension IDs are 32 letters from a to p.
    static func isChromiumID(_ id: String) -> Bool {
        id.count == 32 && id.allSatisfy { ("a"..."p").contains($0) }
    }

    func chromiumExtension(id: String, record: [String: Any]?, manifest: [String: Any], versionDir: URL, version: String,
                           folder: URL, size: Int64, browser: String, browserRemoved: Bool) -> BrowserExtension? {
        let location = (record?["location"] as? NSNumber)?.intValue
        // Chrome's own component extensions are not the person's.
        if location == 5 || location == 10 { return nil }

        let state = Self.chromiumState(record)
        let source = Self.chromiumSource(record: record, manifest: manifest, location: location)
        let updated = Self.chromeDate(record?["last_update_time"]) ?? Self.chromeDate(record?["first_install_time"])
            ?? Self.chromeDate(record?["install_time"])
        let installed = Self.chromeDate(record?["first_install_time"]) ?? Self.chromeDate(record?["install_time"])

        return BrowserExtension(
            name: Self.chromiumName(manifest: manifest, record: record, versionDir: versionDir, fallback: id),
            version: (manifest["version"] as? String) ?? version,
            extensionID: id,
            kind: manifest["theme"] != nil ? "Theme" : (manifest["app"] != nil ? "Chrome app" : "Extension"),
            state: state,
            source: source.source,
            path: folder.path,
            size: size,
            installed: installed,
            updated: updated,
            flags: flags(state: state, disabledReason: Self.chromiumDisabledReason(record), source: source.source,
                         sourceNote: source.note, updated: updated, browserRemoved: browserRemoved, browser: browser))
    }

    /// `extensions.settings` from `Secure Preferences` and `Preferences`, merged per extension.
    /// Chrome splits what it protects with a hash from what it does not, depending on version.
    static func chromiumSettings(in profile: URL) -> [String: Any]? {
        var merged: [String: Any]?
        for file in ["Secure Preferences", "Preferences"] {
            guard let prefs = json(at: profile.appendingPathComponent(file)),
                  let settings = (prefs["extensions"] as? [String: Any])?["settings"] as? [String: Any] else { continue }
            var result = merged ?? [:]
            for (id, value) in settings {
                guard let entry = value as? [String: Any] else { continue }
                var combined = (result[id] as? [String: Any]) ?? [:]
                combined.merge(entry) { current, _ in current }
                result[id] = combined
            }
            merged = result
        }
        return merged
    }

    static func chromiumState(_ record: [String: Any]?) -> ExtensionState {
        guard let record else { return .unknown }
        if let state = (record["state"] as? NSNumber)?.intValue {
            return state == 1 ? .enabled : .disabled
        }
        // Newer Chrome versions drop `state` and keep only the reasons an extension is off.
        if let reasons = (record["disable_reasons"] as? NSNumber)?.intValue, reasons != 0 { return .disabled }
        if let reasons = record["disable_reasons"] as? [Any], !reasons.isEmpty { return .disabled }
        // A full install record with no reason to be off is an enabled extension.
        return record["location"] != nil && record["path"] != nil ? .enabled : .unknown
    }

    static func chromiumDisabledReason(_ record: [String: Any]?) -> String? {
        guard let reasons = (record?["disable_reasons"] as? NSNumber)?.intValue, reasons != 0 else { return nil }
        if reasons & 1 != 0 { return "Turned off in the browser's extension settings." }
        if reasons & 2 != 0 { return "Turned off after an update asked for more permissions." }
        if reasons & 64 != 0 { return "Turned off by the browser's own blocklist." }
        if reasons & 128 != 0 { return "Turned off because its files are damaged." }
        if reasons & (1024 | 2048) != 0 { return "Turned off by a policy." }
        return "Turned off by the browser."
    }

    struct ChromiumSource {
        let source: ExtensionSource
        let note: String?
    }

    /// Manifest::Location values: 1 internal, 2 external pref, 3 external registry, 4 unpacked,
    /// 6 external pref download, 7 external policy download, 8 command line, 9 external policy.
    static func chromiumSource(record: [String: Any]?, manifest: [String: Any], location: Int?) -> ChromiumSource {
        guard let record, let location else { return .init(source: .unknown, note: nil) }
        let fromStore = (record["from_webstore"] as? Bool) == true
            || (record["from_webstore"] as? NSNumber)?.boolValue == true
            || isStoreUpdateURL(manifest["update_url"] as? String)
        switch location {
        case 7, 9:
            return .init(source: .policy, note: "Installed by a policy (an administrator or a configuration profile).")
        case 4, 8:
            return .init(source: .sideloaded, note: "Loaded from a folder on this Mac, not from a store.")
        case 2, 3, 6:
            return fromStore
                ? .init(source: .webStore, note: nil)
                : .init(source: .otherProgram, note: "Added by another program, not from the browser's store.")
        default:
            return fromStore
                ? .init(source: .webStore, note: nil)
                : .init(source: .sideloaded, note: "Not from the browser's store (installed from a file or another site).")
        }
    }

    /// Update URLs of the stores Chromium browsers use. An extension that checks one of these
    /// for updates came from that store even when the browser did not record `from_webstore`.
    static func isStoreUpdateURL(_ text: String?) -> Bool {
        guard let host = text.flatMap({ URL(string: $0)?.host?.lowercased() }) else { return false }
        return ["clients2.google.com", "edge.microsoft.com", "microsoftedge.microsoft.com", "addons.opera.com",
                "extension-updates.opera.com"].contains(host)
    }

    /// Chromium timestamps are microseconds since 1601-01-01, stored as strings.
    static func chromeDate(_ value: Any?) -> Date? {
        let micros: Double?
        if let text = value as? String { micros = Double(text) } else { micros = (value as? NSNumber)?.doubleValue }
        guard let micros, micros > 0 else { return nil }
        return Date(timeIntervalSince1970: micros / 1_000_000 - 11_644_473_600)
    }

    static func chromiumName(manifest: [String: Any], record: [String: Any]?, versionDir: URL, fallback: String) -> String {
        let defaultLocale = manifest["default_locale"] as? String
        let candidates = [manifest["name"] as? String, (record?["manifest"] as? [String: Any])?["name"] as? String]
        for case let raw? in candidates {
            if let name = resolveMessage(raw, in: versionDir, defaultLocale: defaultLocale), !name.isEmpty { return name }
        }
        return fallback
    }

    /// Resolves `__MSG_key__` through `_locales/<default_locale>/messages.json`. Keys are
    /// case-insensitive. Returns nil when the text is a reference that cannot be resolved.
    static func resolveMessage(_ text: String, in versionDir: URL, defaultLocale: String?) -> String? {
        guard text.hasPrefix("__MSG_"), text.hasSuffix("__"), text.count > 8 else { return text }
        let key = String(text.dropFirst(6).dropLast(2)).lowercased()
        let localesDir = versionDir.appendingPathComponent("_locales")
        let available = ((try? FileManager.default.contentsOfDirectory(atPath: localesDir.path)) ?? []).sorted()
        func normal(_ locale: String) -> String { locale.replacingOccurrences(of: "-", with: "_").lowercased() }

        var order = [defaultLocale, "en", "en_US", "en_GB"].compactMap { $0 }.map(normal)
        order += available.map(normal)
        for locale in order {
            guard let folder = available.first(where: { normal($0) == locale }),
                  let messages = json(at: localesDir.appendingPathComponent(folder).appendingPathComponent("messages.json")) else { continue }
            for (name, value) in messages where name.lowercased() == key {
                if let message = (value as? [String: Any])?["message"] as? String { return message }
            }
        }
        return nil
    }
}
