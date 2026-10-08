import Foundation

/// Firefox lists its profiles in `profiles.ini`; each profile's `extensions.json` records
/// every add-on with its state, signature and dates.
extension BrowserExtensionScanner {
    static let firefoxBundleIDs = ["org.mozilla.firefox", "org.mozilla.nightly", "org.mozilla.firefoxdeveloperedition"]
    static let firefoxAppNames = ["Firefox", "Firefox Nightly", "Firefox Developer Edition"]

    func scanFirefox() -> [BrowserInstall] {
        let fm = FileManager.default
        let root = applicationSupport.appendingPathComponent("Firefox")
        guard fm.fileExists(atPath: root.path) else { return [] }
        let app = installedApp(bundleIDs: Self.firefoxBundleIDs, names: Self.firefoxAppNames)

        guard Self.isReadable(root) else {
            return [BrowserInstall(name: "Firefox", family: .firefox, isInstalled: app != nil, appPath: app?.path,
                                   dataPath: root.path, profiles: [], note: Self.unreadableNote("Firefox", installed: app != nil))]
        }
        guard let ini = try? String(contentsOf: root.appendingPathComponent("profiles.ini"), encoding: .utf8) else { return [] }

        let profiles = Self.firefoxProfiles(ini: ini, root: root)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { entry in
                BrowserProfile(name: entry.name, directory: entry.folder.lastPathComponent, path: entry.folder.path,
                               extensions: firefoxExtensions(in: entry.folder, app: app))
            }
        guard !profiles.isEmpty else { return [] }
        return [BrowserInstall(name: "Firefox", family: .firefox, isInstalled: app != nil, appPath: app?.path,
                               dataPath: root.path, profiles: profiles, note: app == nil ? Self.removedNote("Firefox") : nil)]
    }

    /// Reads the `[ProfileN]` sections of profiles.ini. Relative paths start at the Firefox folder.
    static func firefoxProfiles(ini: String, root: URL) -> [(name: String, folder: URL)] {
        var sections: [[String: String]] = []
        var current: [String: String]?
        for rawLine in ini.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                if let current { sections.append(current) }
                current = line.hasPrefix("[Profile") ? [:] : nil
            } else if current != nil, let equals = line.firstIndex(of: "=") {
                current?[String(line[..<equals])] = String(line[line.index(after: equals)...])
            }
        }
        if let current { sections.append(current) }

        var seen = Set<String>()
        return sections.compactMap { section in
            guard let path = section["Path"], !path.isEmpty else { return nil }
            let folder = section["IsRelative"] == "0"
                ? URL(fileURLWithPath: path)
                : root.appendingPathComponent(path)
            guard seen.insert(folder.path).inserted else { return nil }
            return (section["Name"] ?? folder.lastPathComponent, folder)
        }
    }

    /// Where Firefox keeps add-ons: the profile's own, and the shared folders other programs
    /// drop add-ons into for every profile: this user's (`app-system-user`), every user's
    /// (`app-system-local`) and the Firefox app's own (`app-global`). Built-in and system
    /// add-ons that ship with Firefox are left out.
    static let firefoxLocations: Set<String> = ["app-profile", "app-system-user", "app-system-local", "app-global"]

    /// The folders an add-on from a shared location may sit in.
    func firefoxSharedFolders(location: String, app: URL?) -> [URL] {
        switch location {
        case "app-system-user": [applicationSupport.appendingPathComponent("Mozilla/Extensions")]
        case "app-system-local": [systemLibrary.appendingPathComponent("Application Support/Mozilla/Extensions")]
        case "app-global": app.map { [$0] } ?? []
        default: []
        }
    }

    /// `app` is the installed Firefox, nil when it is gone.
    func firefoxExtensions(in profile: URL, app: URL?) -> [BrowserExtension] {
        let browserRemoved = app == nil
        guard let database = Self.json(at: profile.appendingPathComponent("extensions.json")),
              let addons = database["addons"] as? [[String: Any]] else { return [] }
        let fm = FileManager.default

        let found = addons.compactMap { addon -> BrowserExtension? in
            guard addon["type"] as? String == "extension",
                  let location = addon["location"] as? String, Self.firefoxLocations.contains(location),
                  let id = addon["id"] as? String, Self.isSafeAddonID(id) else { return nil }
            let name = ((addon["defaultLocale"] as? [String: Any])?["name"] as? String) ?? id
            let state = Self.firefoxState(addon)
            let source = location == "app-profile"
                ? Self.firefoxSource(addon)
                : ChromiumSource(source: .otherProgram,
                                 note: location == "app-global"
                                     ? "Added by another program, which put it inside the Firefox app; not installed from addons.mozilla.org."
                                     : "Added by another program, which put it in a Mozilla folder shared by every profile; not installed from addons.mozilla.org.")
            let installed = Self.milliseconds(addon["installDate"])
            let updated = Self.milliseconds(addon["updateDate"]) ?? installed
            let signed = (addon["signedState"] as? NSNumber)?.intValue

            // The file normally sits in the profile's extensions folder; the recorded path covers
            // the rest, but only inside the folders Firefox keeps add-ons in: extensions.json is
            // just a file, and its path could name any folder on the disk.
            let roots = [profile] + firefoxSharedFolders(location: location, app: app)
            let recorded = (addon["path"] as? String).map { URL(fileURLWithPath: $0) }
                .flatMap { Self.isInside($0, roots: roots) ? $0 : nil }
            let candidates = [profile.appendingPathComponent("extensions/\(id).xpi"),
                              profile.appendingPathComponent("extensions/\(id)"),
                              recorded].compactMap { $0 }
            let existing = candidates.first { fm.fileExists(atPath: $0.path) }
            // An add-on from a shared folder that is not where Firefox keeps it (gone, or recorded
            // somewhere Poof does not trust) is skipped rather than shown with a made-up path.
            guard existing != nil || location == "app-profile" else { return nil }
            let file = existing ?? candidates[0]

            return BrowserExtension(
                name: name,
                version: (addon["version"] as? String) ?? "",
                extensionID: id,
                state: state,
                source: source.source,
                path: file.path,
                size: LeftoverScanner.size(of: file),
                installed: installed,
                updated: updated,
                // signedState: 0 is missing, -2 is broken; -1 only means Firefox has not checked.
                flags: flags(state: state, disabledReason: "Turned off in Firefox's add-ons manager.", source: source.source,
                             sourceNote: source.note, updated: updated, unsigned: signed == 0 || signed == -2,
                             browserRemoved: browserRemoved, browser: "Firefox"))
        }
        return Self.sorted(found)
    }

    /// Add-on IDs become file names; one that could climb out of the extensions folder is skipped.
    static func isSafeAddonID(_ id: String) -> Bool {
        !id.isEmpty && !id.contains("/") && !id.contains("..") && !id.contains("\0")
    }

    static func firefoxState(_ addon: [String: Any]) -> ExtensionState {
        for key in ["userDisabled", "appDisabled", "softDisabled"] where (addon[key] as? Bool) == true {
            return .disabled
        }
        guard let active = addon["active"] as? Bool else { return .unknown }
        return active ? .enabled : .disabled
    }

    static func firefoxSource(_ addon: [String: Any]) -> ChromiumSource {
        let telemetry = (addon["installTelemetryInfo"] as? [String: Any])?["source"] as? String
        if telemetry == "enterprise-policy" {
            return .init(source: .policy, note: "Installed by a policy (an administrator or a configuration profile).")
        }
        guard let text = addon["sourceURI"] as? String, let url = URL(string: text) else {
            return .init(source: .sideloaded, note: "Installed from a file, not from addons.mozilla.org.")
        }
        if url.isFileURL { return .init(source: .sideloaded, note: "Installed from a file, not from addons.mozilla.org.") }
        if url.host?.lowercased() == "addons.mozilla.org" || telemetry == "amo" { return .init(source: .webStore, note: nil) }
        return .init(source: .website, note: "Installed from \(url.host ?? "a website"), not from addons.mozilla.org.")
    }

    /// Firefox stores dates as milliseconds since 1970.
    static func milliseconds(_ value: Any?) -> Date? {
        guard let ms = (value as? NSNumber)?.doubleValue, ms > 0 else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }
}
