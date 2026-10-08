import Foundation

/// Read access to the installer's package receipts (what `pkgutil` reports).
public protocol PackageDatabase: Sendable {
    func packageIDs() -> [String]
    /// Paths relative to the install location, as recorded in the receipt.
    func files(of packageID: String) -> [String]
    /// Where the package was installed, relative to the volume root ("" or "Library").
    func installLocation(of packageID: String) -> String
    /// When the package was installed, if the receipt records it.
    func installTime(of packageID: String) -> Date?
}

/// Package receipts from `/var/db/receipts`, read through `pkgutil`.
public struct SystemPackageDatabase: PackageDatabase {
    public init() {}

    public func packageIDs() -> [String] {
        Self.lines(Self.pkgutil(["--pkgs"]))
    }

    public func files(of packageID: String) -> [String] {
        Self.lines(Self.pkgutil(["--files", packageID]))
    }

    public func installLocation(of packageID: String) -> String {
        let data = Self.pkgutil(["--pkg-info-plist", packageID])
        let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        return info?["install-location"] as? String ?? ""
    }

    public func installTime(of packageID: String) -> Date? {
        let data = Self.pkgutil(["--pkg-info-plist", packageID])
        let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        return (info?["install-time"] as? Int).map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    static func pkgutil(_ arguments: [String]) -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/pkgutil")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return Data() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data
    }

    static func lines(_ data: Data) -> [String] {
        String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }
}

/// A package that installed (part of) an app.
public struct PackageMatch: Sendable, Equatable {
    public struct OwnedPath: Sendable, Equatable {
        /// Relative to the volume root, e.g. "Library/Application Support/Fortinet".
        public let path: String
        /// Other packages that also install files under this path.
        public let sharedWith: [String]
    }

    public let packageID: String
    /// Other apps the same package installed. Non-empty means everything it installed is shared.
    public let otherApps: [String]
    /// Top-most folders and files the package created outside app bundles and standard system folders.
    public let ownedPaths: [OwnedPath]
}

extension PackageDatabase {
    public func installLocation(of packageID: String) -> String { "" }
    public func installTime(of packageID: String) -> Date? { nil }

    /// Packages that installed `app`.
    ///
    /// App bundles are matched by name because installers often unpack them somewhere
    /// temporary (`private/tmp/...`) and move them afterwards, so the recorded location
    /// is wrong for the `.app`. It is still right for the package's other files.
    public func packages(for app: AppBundle) -> [PackageMatch] {
        let bundleID = app.bundleID.lowercased()
        let appFile = app.url.lastPathComponent
        let vendor = bundleID.split(separator: ".").prefix(2).joined(separator: ".")

        // Listing files is slow, so only look inside packages from the same vendor.
        let candidates = packageIDs().filter { id in
            let lowered = id.lowercased()
            return lowered == bundleID || lowered.hasPrefix(bundleID + ".") || lowered.hasPrefix(vendor + ".")
        }

        var matched: [(id: String, apps: [String: String], paths: [String])] = []
        var others: [String: Set<String>] = [:]  // path or ancestor -> other packages using it
        for id in candidates {
            let lowered = id.lowercased()
            let files = self.files(of: id)
            let location = installLocation(of: id)
            let paths = Self.absolutePaths(files: files, location: location)
            let bundles = Dictionary(
                files.compactMap { file in Self.appBundlePath(file).map { (Self.appBundleName(file)!, Self.join(location, $0)) } },
                uniquingKeysWith: { first, _ in first }
            )
            if lowered == bundleID || lowered.hasPrefix(bundleID + ".") || bundles[appFile] != nil {
                matched.append((id, bundles, paths))
            } else {
                for path in paths {
                    for ancestor in Self.ancestors(of: path) { others[ancestor, default: []].insert(id) }
                }
            }
        }

        return matched.map { package in
            let owned = Self.ownedPaths(package.paths, others: others)
            let unshared = owned.filter(\.sharedWith.isEmpty).map(\.path)
            // Apps the package put inside folders it owns (an uninstaller next to the app) go with it.
            let otherApps = package.apps.filter { name, path in
                name != appFile && !unshared.contains { path == $0 || path.hasPrefix($0 + "/") }
            }.keys.sorted()
            return PackageMatch(packageID: package.id, otherApps: otherApps, ownedPaths: owned)
        }
    }

    /// Splits a package's files into the top-most paths it owns. Starts at the first folder
    /// below the standard system folders and walks down while another package also uses it,
    /// so "Blackmagic Design" (shared) becomes "Blackmagic Design/DaVinci Resolve" (owned).
    static func ownedPaths(_ paths: [String], others: [String: Set<String>]) -> [PackageMatch.OwnedPath] {
        let pathSet = Set(paths)
        var result: [PackageMatch.OwnedPath] = []
        var queue = Set(paths.compactMap { path in
            ancestors(of: path).first { !standardFolders.contains($0) }
        }).filter { !isTemporary($0) }.sorted()
        while let root = queue.popLast() {
            guard let users = others[root], !users.isEmpty else {
                result.append(.init(path: root, sharedWith: []))
                continue
            }
            let depth = root.split(separator: "/").count + 1
            let children = Set(paths.filter { $0.hasPrefix(root + "/") }.map {
                $0.split(separator: "/").prefix(depth).joined(separator: "/")
            })
            if children.isEmpty {
                // A file (or empty folder) another package also lists.
                if pathSet.contains(root) { result.append(.init(path: root, sharedWith: users.sorted())) }
            } else {
                queue.append(contentsOf: children)
            }
        }
        return result.sorted { $0.path < $1.path }
    }

    /// Install-root-relative paths of everything outside app bundles.
    static func absolutePaths(files: [String], location: String) -> [String] {
        files.filter { appBundleName($0) == nil }.map { join(location, $0) }
    }

    static func join(_ location: String, _ file: String) -> String {
        (location.split(separator: "/") + file.split(separator: "/").filter { $0 != "." }).joined(separator: "/")
    }

    /// "a/b/c" -> ["a", "a/b", "a/b/c"]
    static func ancestors(of path: String) -> [String] {
        let parts = path.split(separator: "/")
        return (1...max(parts.count, 1)).compactMap { depth in
            depth <= parts.count ? parts.prefix(depth).joined(separator: "/") : nil
        }
    }

    /// "DaVinci Resolve/Uninstall Resolve.app/Contents/x" -> "DaVinci Resolve/Uninstall Resolve.app"
    static func appBundlePath(_ path: String) -> String? {
        let parts = path.split(separator: "/")
        guard let index = parts.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return parts.prefix(index + 1).joined(separator: "/")
    }

    static func isTemporary(_ path: String) -> Bool {
        ["private/tmp", "tmp", "private/var/folders"].contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// "Applications/Foo.app/Contents/x" -> "Foo.app"
    static func appBundleName(_ path: String) -> String? {
        path.split(separator: "/").first { $0.hasSuffix(".app") }.map(String.init)
    }

    static var standardFolders: Set<String> { standardSystemFolders }
}

/// Folders that exist on every Mac. Packages list them but never own them.
private let standardSystemFolders: Set<String> = {
        let library = [
            "Application Support", "Audio", "Audio/MIDI Drivers", "Audio/Plug-Ins", "Audio/Plug-Ins/Components",
            "Audio/Plug-Ins/HAL", "Audio/Plug-Ins/VST", "Audio/Plug-Ins/VST3", "Caches", "ColorSync",
            "ColorSync/Profiles", "Components", "Contextual Menu Items", "Developer", "Documentation",
            "DriverExtensions", "Extensions", "Filesystems", "Fonts", "Frameworks", "Image Capture",
            "Image Capture/Devices", "Input Methods", "Internet Plug-Ins", "Keyboard Layouts", "LaunchAgents",
            "LaunchDaemons", "Logs", "PreferencePanes", "Preferences", "Printers", "PrivilegedHelperTools",
            "QuickLook", "Screen Savers", "Security", "Security/SecurityAgentPlugins", "Services", "Spotlight",
            "StartupItems", "SystemExtensions",
        ]
        let other = [
            "Applications", "Applications/Utilities", "Library", "System", "Users", "opt", "usr", "usr/local",
            "usr/local/bin", "usr/local/etc", "usr/local/include", "usr/local/lib", "usr/local/sbin", "usr/local/share",
            "usr/local/share/man", "usr/local/share/man/man1", "private", "private/etc", "private/var",
            "private/var/db", "etc", "var",
        ]
        return Set(other + library.map { "Library/\($0)" })
}()
