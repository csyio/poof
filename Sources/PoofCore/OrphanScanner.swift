import Foundation

/// Finds files left by apps that are no longer installed. Read-only.
///
/// It only reports cases it can judge without the app present, and errs toward silence:
/// a file named after a bundle ID counts as orphaned only when no installed app comes
/// from the same vendor, since vendors share files across apps under their own prefix
/// (`com.microsoft.office.plist` is used by every Office app).
public struct OrphanScanner: Sendable {
    let home: URL
    let systemRoot: URL
    let installedIDs: Set<String>

    public init(
        home: URL = UserContext.home,
        systemRoot: URL = URL(fileURLWithPath: "/"),
        installedIDs: Set<String>? = nil
    ) {
        self.home = home
        self.systemRoot = systemRoot
        self.installedIDs = Set((installedIDs ?? Self.installedBundleIDs()).map { $0.lowercased() })
    }

    /// Folders where entries are named after the owning bundle ID. Only apps and their
    /// extensions create the first group; any process can write to the second.
    static let appOnlyDirs = ["Application Scripts", "Containers", "Saved Application State"]
    static let anyProcessDirs = ["Caches", "HTTPStorages", "Preferences", "WebKit"]
    /// Reverse-DNS prefixes that real bundle IDs start with.
    static let domainPrefixes: Set<String> = ["com", "org", "net", "io", "app", "dev", "co", "ai", "de", "me", "us", "uk", "fr", "tv"]

    public func scan() -> [Leftover] {
        var found = LeftoverScanner.Found()
        let fm = FileManager.default
        let library = systemRoot.appendingPathComponent("Library")

        for ext in SystemExtension.load(from: library.appendingPathComponent("SystemExtensions/db.plist")) {
            let originGone = ext.originPath.map { !fm.fileExists(atPath: $0) } ?? true
            let ids = [ext.identifier] + ext.appIdentifiers
            guard originGone, !ids.contains(where: isInstalledOrVendorPresent) else { continue }
            found.add(systemRoot.appendingPathComponent(ext.stagedPath ?? "/Library/SystemExtensions"),
                      .orphanedSystemExtension, detail: "\(ext.identifier), \(ext.kind)")
        }

        for base in [home.appendingPathComponent("Library"), library] {
            for dir in ["LaunchAgents", "LaunchDaemons"] {
                for plist in (try? fm.contentsOfDirectory(at: base.appendingPathComponent(dir), includingPropertiesForKeys: nil)) ?? [] {
                    guard !plist.lastPathComponent.hasPrefix("com.apple."),
                          let program = Self.launchProgram(plist), program.hasPrefix("/"),
                          !fm.fileExists(atPath: systemRoot.appendingPathComponent(program).path) else { continue }
                    found.add(plist, .brokenLaunchItem, detail: "runs \(program)")
                }
            }
        }

        for dir in Self.appOnlyDirs + Self.anyProcessDirs {
            let folder = home.appendingPathComponent("Library/\(dir)")
            let reason: Leftover.Reason = Self.appOnlyDirs.contains(dir) ? .orphanedAppData : .orphanedBundleID
            for entry in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
                guard let id = Self.bundleID(fromEntryName: entry.lastPathComponent),
                      !isKnownNonApp(id), !isInstalledOrVendorPresent(id) else { continue }
                found.add(entry, reason, detail: id)
            }
        }
        return found.items.sorted { ($0.isCertain ? 0 : 1, $0.url.path) < ($1.isCertain ? 0 : 1, $1.url.path) }
    }

    /// True when an installed app has this ID, is its parent or child, or shares its vendor prefix.
    func isInstalledOrVendorPresent(_ id: String) -> Bool {
        let id = id.lowercased()
        let vendor = Self.vendor(of: id)
        return installedIDs.contains { installed in
            installed == id || id.hasPrefix(installed + ".") || installed.hasPrefix(id + ".")
                || Self.vendor(of: installed) == vendor
        }
    }

    /// "com.logi.ghub.hidfilter" -> "com.logi"
    static func vendor(of id: String) -> String {
        id.split(separator: ".").prefix(2).joined(separator: ".")
    }

    /// "com.logi.ghub.plist" -> "com.logi.ghub"; nil for Apple's own files and non-bundle-ID names.
    static func bundleID(fromEntryName name: String) -> String? {
        let lowered = name.lowercased()
        let stem = String(name.prefix(LeftoverScanner.stripExtensions(lowered).count))
        let parts = stem.lowercased().split(separator: ".")
        guard parts.count >= 3, let first = parts.first, domainPrefixes.contains(String(first)),
              !stem.lowercased().hasPrefix("com.apple."), !stem.contains(" ") else { return nil }
        return stem
    }

    static func launchProgram(_ plist: URL) -> String? {
        guard let dict = NSDictionary(contentsOf: plist) as? [String: Any] else { return nil }
        return dict["Program"] as? String ?? (dict["ProgramArguments"] as? [String])?.first
    }

    /// Bundle IDs of every app Spotlight knows about, plus the standard app folders in case
    /// Spotlight is off. Apps in odd places (Downloads, build folders) count as installed.
    public static func installedBundleIDs() -> Set<String> {
        var paths = Set<String>()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = ["kMDItemContentType == 'com.apple.application-bundle'"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        if (try? process.run()) != nil {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            paths.formUnion(String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init))
        }
        for dir in ["/Applications", "/System/Applications", "/System/Applications/Utilities", UserContext.home.path + "/Applications"] {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where name.hasSuffix(".app") {
                paths.insert(dir + "/" + name)
            }
        }
        return Set(paths.filter { !isInstallerOrStaged($0) }.compactMap { Bundle(path: $0)?.bundleIdentifier })
    }

    /// An installer left in Downloads, or macOS's own copy of a system extension, does not
    /// mean the app is installed (`lghub_installer.app` outlives Logitech G HUB).
    static func isInstallerOrStaged(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent.lowercased()
        return path.hasPrefix("/Library/SystemExtensions/")
            || ["installer", "uninstall", "uninstaller"].contains { name.contains($0) }
    }
}
