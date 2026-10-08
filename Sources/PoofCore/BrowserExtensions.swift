import Foundation

/// Why an extension deserves a look. Never a verdict: Poof cannot tell whether an extension
/// is harmful, only that it is switched off, came from outside a store, or looks forgotten.
public struct ExtensionFlag: Sendable, Codable, Equatable {
    public enum Kind: String, Sendable, Codable {
        case disabled, sideloaded, policy, unsigned, notUpdated, browserRemoved
    }

    public let kind: Kind
    public let message: String

    public init(_ kind: Kind, _ message: String) {
        self.kind = kind
        self.message = message
    }
}

public enum ExtensionState: String, Sendable, Codable {
    case enabled, disabled, unknown
}

/// Where an extension came from, as far as the browser's own records say.
public enum ExtensionSource: String, Sendable, Codable {
    /// The browser's add-on store (Chrome Web Store, Edge Add-ons, Firefox Add-ons...).
    case webStore
    /// Loaded from a folder or a file instead of a store.
    case sideloaded
    /// Added by another program or installer.
    case otherProgram
    /// Installed by an administrator policy or configuration profile.
    case policy
    /// Installed from a website outside the store.
    case website
    /// Delivered inside an app (Safari app extensions).
    case app
    case unknown

    public var label: String {
        switch self {
        case .webStore: "from the store"
        case .sideloaded: "not from a store (unpacked or from a file)"
        case .otherProgram: "added by another program"
        case .policy: "installed by a policy"
        case .website: "from a website, not the store"
        case .app: "app"
        case .unknown: "unknown source"
        }
    }
}

public struct BrowserExtension: Sendable, Codable, Equatable, Identifiable {
    public let name: String
    public let version: String
    /// The browser's identifier: Chromium extension ID, Firefox add-on ID, Safari bundle ID.
    public let extensionID: String
    /// "Extension", "Theme", "Chrome app", "Safari web extension"...
    public let kind: String
    public let state: ExtensionState
    public let source: ExtensionSource
    /// The folder, `.xpi` file or `.appex` bundle to show in Finder.
    public let path: String
    public let size: Int64
    public let installed: Date?
    public let updated: Date?
    /// The app that supplies the extension (Safari). Removing that app removes the extension.
    public let providedBy: String?
    public let flags: [ExtensionFlag]

    public var id: String { path }

    /// The flags worth showing next to the extension. `browserRemoved` is left out: the
    /// browser's own note already says the browser is gone.
    public var shownFlags: [ExtensionFlag] { flags.filter { $0.kind != .browserRemoved } }
    /// Whether the extension has a flag worth a look; what "flagged" counts and filters on.
    public var isFlagged: Bool { !shownFlags.isEmpty }

    public init(name: String, version: String, extensionID: String, kind: String = "Extension",
                state: ExtensionState, source: ExtensionSource, path: String, size: Int64,
                installed: Date? = nil, updated: Date? = nil, providedBy: String? = nil,
                flags: [ExtensionFlag] = []) {
        self.name = name
        self.version = version
        self.extensionID = extensionID
        self.kind = kind
        self.state = state
        self.source = source
        self.path = path
        self.size = size
        self.installed = installed
        self.updated = updated
        self.providedBy = providedBy
        self.flags = flags
    }

    func adding(_ flag: ExtensionFlag) -> BrowserExtension {
        BrowserExtension(name: name, version: version, extensionID: extensionID, kind: kind, state: state,
                         source: source, path: path, size: size, installed: installed, updated: updated,
                         providedBy: providedBy, flags: flags + [flag])
    }
}

public struct BrowserProfile: Sendable, Codable, Equatable, Identifiable {
    /// The name the person gave the profile, or the folder name when there is none.
    public let name: String
    /// The profile's folder name ("Default", "Profile 2").
    public let directory: String
    public let path: String
    public let extensions: [BrowserExtension]

    public var id: String { path }
    public var size: Int64 { extensions.reduce(0) { $0 + $1.size } }

    public init(name: String, directory: String, path: String, extensions: [BrowserExtension]) {
        self.name = name
        self.directory = directory
        self.path = path
        self.extensions = extensions
    }
}

public struct BrowserInstall: Sendable, Codable, Equatable, Identifiable {
    public enum Family: String, Sendable, Codable {
        case chromium, firefox, safari
    }

    public let name: String
    public let family: Family
    /// False when the app is gone but its profile folder is still on disk.
    public let isInstalled: Bool
    public let appPath: String?
    /// The browser's data folder, which holds the profiles.
    public let dataPath: String?
    public let profiles: [BrowserProfile]
    /// Something the person should know about this browser: a leftover folder, or a folder
    /// macOS would not let Poof read.
    public let note: String?

    public var id: String { dataPath ?? name }
    public var extensionCount: Int { profiles.reduce(0) { $0 + $1.extensions.count } }
    public var flaggedCount: Int {
        profiles.reduce(0) { $0 + $1.extensions.filter(\.isFlagged).count }
    }

    public init(name: String, family: Family, isInstalled: Bool, appPath: String?, dataPath: String?,
                profiles: [BrowserProfile], note: String? = nil) {
        self.name = name
        self.family = family
        self.isInstalled = isInstalled
        self.appPath = appPath
        self.dataPath = dataPath
        self.profiles = profiles
        self.note = note
    }
}

/// Lists the extensions in every supported browser profile on this Mac. Read-only: browser
/// profiles hold passwords and history, so Poof only reads the extension folders and the
/// preference files that say whether each one is on.
public struct BrowserExtensionScanner: Sendable {
    struct InstalledApp: Sendable {
        let url: URL
        let bundleID: String?
    }

    let home: URL
    let apps: [InstalledApp]
    let now: Date
    let staleAfterDays: Int
    /// The Library folder shared by every user (Firefox's `app-system-local` add-ons). Tests replace it.
    var systemLibrary = URL(fileURLWithPath: "/Library")

    /// - Parameters:
    ///   - home: the home folder to read profiles from.
    ///   - appURLs: installed `.app` bundles; defaults to the standard app folders.
    ///   - staleAfterDays: an extension whose last update is older than this gets a flag.
    public init(home: URL = UserContext.home, appURLs: [URL]? = nil, now: Date = Date(), staleAfterDays: Int = 730) {
        self.home = home
        self.apps = (appURLs ?? AppBundle.installedAppURLs()).map {
            InstalledApp(url: $0, bundleID: Self.plist(at: $0.appendingPathComponent("Contents/Info.plist"))?["CFBundleIdentifier"] as? String)
        }
        self.now = now
        self.staleAfterDays = staleAfterDays
    }

    public func scan() -> [BrowserInstall] {
        scanChromium() + scanFirefox() + scanSafari()
    }

    var applicationSupport: URL { home.appendingPathComponent("Library/Application Support") }

    // MARK: Shared helpers

    /// The installed app that matches a bundle ID or a file name, if any.
    func installedApp(bundleIDs: [String], names: [String]) -> URL? {
        let ids = Set(bundleIDs.map { $0.lowercased() })
        let stems = Set(names.map { $0.lowercased() })
        return apps.first { app in
            if let id = app.bundleID?.lowercased(), ids.contains(id) { return true }
            return stems.contains(app.url.deletingPathExtension().lastPathComponent.lowercased())
        }?.url
    }

    static func json(at url: URL) -> [String: Any]? {
        guard var data = try? Data(contentsOf: url) else { return nil }
        // Chromium manifests are often saved with a byte order mark, which JSONSerialization rejects.
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { data = data.dropFirst(3) }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func plist(at url: URL) -> [String: Any]? {
        NSDictionary(contentsOf: url) as? [String: Any]
    }

    /// False when macOS refuses to list the folder, which is different from an empty folder.
    static func isReadable(_ url: URL) -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil
    }

    /// Whether `url`, with `..` and symbolic links resolved, lies inside one of `roots` (not
    /// the root itself).
    static func isInside(_ url: URL, roots: [URL]) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return roots.contains { root in
            let base = root.standardizedFileURL.resolvingSymlinksInPath().path
            return path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
        }
    }

    static func unreadableNote(_ browser: String, installed: Bool) -> String {
        "macOS did not let Poof read \(browser)'s data folder. Give Poof (or your terminal) Full Disk Access in System Settings > Privacy & Security."
            + (installed ? "" : " \(browser) is not installed, so the folder is probably a leftover.")
    }

    static func removedNote(_ browser: String) -> String {
        "\(browser) is not installed, so this folder is probably a leftover. It holds the browser's profiles, " +
            "which may include passwords and bookmarks, so Poof only lists it."
    }

    static func month(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: date)
    }

    /// Flags shared by every browser family.
    func flags(state: ExtensionState, disabledReason: String?, source: ExtensionSource, sourceNote: String?,
               updated: Date?, unsigned: Bool = false, browserRemoved: Bool, browser: String) -> [ExtensionFlag] {
        var found: [ExtensionFlag] = []
        if browserRemoved {
            found.append(.init(.browserRemoved, "\(browser) is not installed; this profile folder is a leftover."))
        }
        if state == .disabled {
            found.append(.init(.disabled, disabledReason ?? "Turned off."))
        }
        switch source {
        case .sideloaded, .otherProgram, .website:
            found.append(.init(.sideloaded, sourceNote ?? "Not installed from the browser's store."))
        case .policy:
            found.append(.init(.policy, sourceNote ?? "Installed by a policy, not by the person using this profile."))
        default: break
        }
        if unsigned {
            found.append(.init(.unsigned, "The browser has no signature for this extension."))
        }
        // Sideloaded extensions have no update channel, so "not updated" says nothing about them.
        if let updated, source != .sideloaded,
           now.timeIntervalSince(updated) > Double(staleAfterDays) * 86_400 {
            found.append(.init(.notUpdated, "Not updated since \(Self.month(updated))."))
        }
        return found
    }

    static func sorted(_ extensions: [BrowserExtension]) -> [BrowserExtension] {
        extensions.sorted {
            let order = $0.name.localizedCaseInsensitiveCompare($1.name)
            return order == .orderedSame ? $0.path < $1.path : order == .orderedAscending
        }
    }
}
