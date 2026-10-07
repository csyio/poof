import Foundation

/// A file or folder that belongs to an app, and why Poof thinks so.
public struct Leftover: Sendable, Equatable, Identifiable {
    public enum Reason: String, Sendable {
        case appBundle = "app bundle"
        case bundleID = "bundle ID"
        case appName = "app name"
        case teamID = "team ID"
        case launchItem = "launch item runs the app"
        case privilegedHelper = "privileged helper declared by the app"
        case packageFile = "installed by package"
        case packageReceipt = "installer receipt"
        case systemExtension = "system extension"
        case orphanedSystemExtension = "system extension of a removed app"
        case brokenLaunchItem = "launch item whose program is gone"
        case brokenLaunchItemOfInstalledVendor = "launch item whose program is gone, its vendor still has apps installed"
        case orphanedAppData = "app data, no installed app from this vendor"
        case orphanedBundleID = "named after an app, no installed app from this vendor"
    }

    public let url: URL
    public let reason: Reason
    public let size: Int64
    /// Other apps that use this item. Removing it may break them.
    public var sharedWith: [String] = []
    /// False when Poof's evidence is circumstantial and a person should check before removing.
    public var isCertain: Bool { reason != .orphanedBundleID && reason != .brokenLaunchItemOfInstalledVendor }
    /// Extra context shown next to the item, e.g. a system extension's identifier and state.
    public var detail: String?
    /// Needs administrator rights to remove.
    public var isSystem: Bool {
        !FileManager.default.isWritableFile(atPath: url.deletingLastPathComponent().path)
    }
    public var id: String { url.path }

    public init(url: URL, reason: Reason, size: Int64, sharedWith: [String] = [], detail: String? = nil) {
        self.url = url
        self.reason = reason
        self.size = size
        self.sharedWith = sharedWith
        self.detail = detail
    }
}

/// Finds an app's files outside its bundle. Read-only: never modifies anything.
public struct LeftoverScanner: Sendable {
    let home: URL
    let systemRoot: URL
    let packages: any PackageDatabase

    public init(
        home: URL = UserContext.home,
        systemRoot: URL = URL(fileURLWithPath: "/"),
        packages: any PackageDatabase = SystemPackageDatabase()
    ) {
        self.home = home
        self.systemRoot = systemRoot
        self.packages = packages
    }

    static let userLibraryDirs = [
        "Application Support", "Application Scripts", "Caches", "Containers", "Cookies",
        "Group Containers", "HTTPStorages", "LaunchAgents", "Logs", "Preferences",
        "Preferences/ByHost", "Saved Application State", "WebKit",
    ]
    static let systemLibraryDirs = [
        "Application Support", "Caches", "LaunchAgents", "LaunchDaemons", "Logs",
        "Preferences", "PrivilegedHelperTools",
    ]

    public func scan(_ app: AppBundle) -> [Leftover] {
        let fm = FileManager.default
        let dirs = Self.userLibraryDirs.map { home.appendingPathComponent("Library/\($0)") }
            + Self.systemLibraryDirs.map { systemRoot.appendingPathComponent("Library/\($0)") }

        var found = Found()
        found.add(app.url, .appBundle)
        for dir in dirs {
            guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for entry in entries {
                if let reason = match(entry, app: app) {
                    found.add(entry, reason)
                } else if let nested = vendorFolder(entry, app: app) {
                    found.add(nested, .appName)
                }
            }
        }

        let library = systemRoot.appendingPathComponent("Library")
        for label in app.privilegedHelpers {
            found.add(library.appendingPathComponent("PrivilegedHelperTools/\(label)"), .privilegedHelper)
            found.add(library.appendingPathComponent("LaunchDaemons/\(label).plist"), .privilegedHelper)
        }

        for package in packages.packages(for: app) {
            for owned in package.ownedPaths {
                found.add(systemRoot.appendingPathComponent(owned.path), .packageFile, sharedWith: owned.sharedWith)
            }
            found.add(
                systemRoot.appendingPathComponent("private/var/db/receipts/\(package.packageID).plist"),
                .packageReceipt, sharedWith: package.otherApps
            )
        }

        // macOS keeps its own copy of activated system extensions. They must be deactivated,
        // not deleted, so the identifier travels with the item.
        let extensionDB = library.appendingPathComponent("SystemExtensions/db.plist")
        for ext in SystemExtension.load(from: extensionDB) where ext.belongs(to: app) {
            let path = ext.stagedPath ?? "/Library/SystemExtensions"
            found.add(systemRoot.appendingPathComponent(path), .systemExtension,
                      detail: "\(ext.identifier), \(ext.kind), \(ext.state.replacingOccurrences(of: "_", with: " "))")
        }

        // Updaters often live in a support folder rather than the app bundle
        // (Chrome's Keystone agent runs from ~/Library/Google/GoogleSoftwareUpdate).
        let roots = found.items.map(\.url.path)
        for dir in ["LaunchAgents", "LaunchDaemons"] {
            for base in [home.appendingPathComponent("Library"), library] {
                let launchDir = base.appendingPathComponent(dir)
                for plist in (try? fm.contentsOfDirectory(at: launchDir, includingPropertiesForKeys: nil)) ?? []
                where launchItem(plist, runsFrom: roots) {
                    found.add(plist, .launchItem)
                }
            }
        }
        return found.items
    }

    /// Collects existing items once each, skipping anything inside an item already found.
    struct Found {
        var items: [Leftover] = []

        mutating func add(_ url: URL, _ reason: Leftover.Reason, sharedWith: [String] = [], detail: String? = nil) {
            let path = url.standardizedFileURL.path
            guard FileManager.default.fileExists(atPath: path) || (try? url.checkResourceIsReachable()) == true else {
                return
            }
            guard !items.contains(where: { path == $0.url.path || path.hasPrefix($0.url.path + "/") }) else { return }
            // A folder replaces items found inside it earlier.
            items.removeAll { $0.url.path.hasPrefix(path + "/") }
            items.append(Leftover(url: URL(fileURLWithPath: path), reason: reason,
                                  size: LeftoverScanner.size(of: url), sharedWith: sharedWith, detail: detail))
        }
    }

    func match(_ entry: URL, app: AppBundle) -> Leftover.Reason? {
        let name = entry.lastPathComponent.lowercased()
        let stem = Self.stripExtensions(name)
        let bundleID = app.bundleID.lowercased()

        // Exact bundle ID or a child of it (com.google.Chrome, com.google.Chrome.helper),
        // but never a sibling under the same vendor prefix (com.google.antigravity).
        if stem == bundleID || stem.hasPrefix(bundleID + ".") { return .bundleID }
        // A team ID alone is shared by every app from that developer (Office, Teams, OneDrive...),
        // so the rest of the name must still point at this app.
        if let team = app.teamID?.lowercased(), entry.deletingLastPathComponent().lastPathComponent == "Group Containers",
           name.hasPrefix(team + ".") {
            let rest = String(name.dropFirst(team.count + 1))
            let group = rest.hasPrefix("group.") ? String(rest.dropFirst(6)) : rest
            if group == bundleID || group.hasPrefix(bundleID + ".") { return .teamID }
        }
        if app.names.contains(where: { $0.lowercased() == stem }) { return .appName }
        if entry.pathExtension == "plist", entry.deletingLastPathComponent().lastPathComponent.hasPrefix("Launch"),
           launchItem(entry, runsFrom: [app.url.path]) || launchItem(entry, isAssociatedWith: app.bundleID) {
            return .launchItem
        }
        return nil
    }

    /// Data kept inside a vendor folder: "Blackmagic Design/DaVinci Resolve", or
    /// "Google/Chrome" where the vendor folder holds the rest of the app name.
    func vendorFolder(_ entry: URL, app: AppBundle) -> URL? {
        guard ["Application Support", "Caches", "Logs"].contains(entry.deletingLastPathComponent().lastPathComponent)
        else { return nil }
        for name in app.names {
            let child = entry.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: child.path) { return child }
        }
        for name in app.names {
            let words = name.split(separator: " ")
            guard words.count > 1, entry.lastPathComponent.lowercased() == words[0].lowercased() else { continue }
            let child = entry.appendingPathComponent(words.dropFirst().joined(separator: " "))
            if FileManager.default.fileExists(atPath: child.path) { return child }
        }
        return nil
    }

    func launchItem(_ plist: URL, runsFrom roots: [String]) -> Bool {
        guard let dict = NSDictionary(contentsOf: plist) as? [String: Any] else { return false }
        let program = dict["Program"] as? String
        let args = dict["ProgramArguments"] as? [String] ?? []
        let paths = [program].compactMap { $0 } + args.prefix(1)
        return paths.contains { path in roots.contains { path.hasPrefix($0 + "/") } }
    }

    func launchItem(_ plist: URL, isAssociatedWith bundleID: String) -> Bool {
        guard let dict = NSDictionary(contentsOf: plist) as? [String: Any] else { return false }
        let ids = dict["AssociatedBundleIdentifiers"] as? [String]
            ?? (dict["AssociatedBundleIdentifiers"] as? String).map { [$0] } ?? []
        return ids.contains { $0.caseInsensitiveCompare(bundleID) == .orderedSame }
    }

    /// "com.foo.bar.plist" -> "com.foo.bar", "com.foo.bar.savedstate" -> "com.foo.bar"
    static func stripExtensions(_ name: String) -> String {
        for ext in [".plist", ".savedstate", ".binarycookies"] where name.hasSuffix(ext) {
            return String(name.dropLast(ext.count))
        }
        return name
    }

    public static func size(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isDirectoryKey]
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return 0 }
        guard values.isDirectory == true else { return Int64(values.totalFileAllocatedSize ?? 0) }
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
