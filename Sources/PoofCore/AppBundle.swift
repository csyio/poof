import Foundation

/// An installed application and the identifiers used to find its leftovers.
public struct AppBundle: Sendable, Equatable {
    public let url: URL
    public let name: String
    public let bundleID: String
    public let teamID: String?
    /// Labels of helpers the app installs into /Library/PrivilegedHelperTools (`SMPrivilegedExecutables`).
    public let privilegedHelpers: [String]
    /// The code signature read when the app was loaded from disk, kept so it is read once.
    let signature: CodeSignature?

    public init(url: URL, name: String, bundleID: String, teamID: String?, privilegedHelpers: [String] = []) {
        self.init(url: url, name: name, bundleID: bundleID, teamID: teamID, privilegedHelpers: privilegedHelpers, signature: nil)
    }

    init(url: URL, name: String, bundleID: String, teamID: String?, privilegedHelpers: [String], signature: CodeSignature?) {
        self.url = url
        self.name = name
        self.bundleID = bundleID
        self.teamID = teamID
        self.privilegedHelpers = privilegedHelpers
        self.signature = signature
    }

    /// The display name and the file name, which can differ ("Word" vs "Microsoft Word").
    public var names: [String] {
        let file = url.deletingPathExtension().lastPathComponent
        return file == name ? [name] : [name, file]
    }

    /// Loads identifiers from an `.app` bundle on disk.
    public init(at url: URL) throws {
        guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else {
            throw PoofError.notAnApp(url.path)
        }
        let name = (bundle.infoDictionary?["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let helpers = (bundle.infoDictionary?["SMPrivilegedExecutables"] as? [String: Any])?.keys.sorted() ?? []
        // Only a team ID macOS can verify against an Apple-issued certificate is kept, so a
        // self-signed app cannot claim another developer's files.
        let signature = CodeSignature.read(url)
        self.init(url: url, name: name, bundleID: bundleID, teamID: signature.teamID, privilegedHelpers: helpers,
                  signature: signature)
    }

    /// Resolves a user-supplied name ("chrome", "Google Chrome") or path to an installed app.
    public static func find(_ query: String, fileManager: FileManager = .default) throws -> AppBundle {
        if query.hasSuffix(".app"), fileManager.fileExists(atPath: query) {
            // Absolute and without "..", so it compares equal to the same app found in a folder listing.
            return try AppBundle(at: URL(fileURLWithPath: query).absoluteURL.standardizedFileURL)
        }
        let apps = installedAppURLs(fileManager: fileManager)
        let needle = query.lowercased()
        let stem = { (url: URL) in url.deletingPathExtension().lastPathComponent.lowercased() }
        let matches = apps.filter { stem($0) == needle }
        let candidates = matches.isEmpty ? apps.filter { stem($0).contains(needle) } : matches
        switch candidates.count {
        case 1: return try AppBundle(at: candidates[0])
        case 0: throw PoofError.appNotFound(query)
        default: throw PoofError.ambiguous(query, candidates.map(\.lastPathComponent).sorted())
        }
    }

    /// App bundles in the standard app folders, including one level of subfolders
    /// ("/Applications/DaVinci Resolve/DaVinci Resolve.app").
    public static func installedAppURLs(fileManager: FileManager = .default) -> [URL] {
        let dirs = ["/Applications", "/Applications/Utilities", UserContext.home.path + "/Applications"]
        return appURLs(in: dirs.map { URL(fileURLWithPath: $0) }, fileManager: fileManager)
    }

    /// Apps in `dirs` and their direct subfolders, each once: /Applications at depth 1
    /// already enters /Applications/Utilities, which is also listed on its own.
    static func appURLs(in dirs: [URL], fileManager: FileManager = .default) -> [URL] {
        func apps(in dir: URL, depth: Int) -> [URL] {
            let entries = (try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            return entries.flatMap { entry -> [URL] in
                if entry.pathExtension == "app" { return [entry] }
                let isFolder = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                return depth > 0 && isFolder ? apps(in: entry, depth: depth - 1) : []
            }
        }
        var seen = Set<String>()
        return dirs.flatMap { apps(in: $0, depth: 1) }
            .filter { seen.insert($0.absoluteURL.standardizedFileURL.path).inserted }
    }

    /// Installed apps a user can remove: Apple's own apps are left out.
    public static func installedApps() -> [AppBundle] {
        installedAppURLs().compactMap { try? AppBundle(at: $0) }
            .filter { !$0.isApples }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// Whether the app is Apple's: an Apple bundle ID backed by a signature only Apple can
    /// make, its own or the App Store's (Xcode and Final Cut Pro come from the App Store).
    /// Anyone can write "com.apple." into an Info.plist, so the ID alone proves nothing.
    var isApples: Bool {
        Self.isApples(bundleID: bundleID, signer: (signature ?? CodeSignature.read(url)).signer)
    }

    static func isApples(bundleID: String, signer: Signer) -> Bool {
        claimsAppleBundleID(bundleID) && (signer == .apple || signer == .appStore)
    }

    static func claimsAppleBundleID(_ bundleID: String) -> Bool {
        bundleID.lowercased().hasPrefix("com.apple.")
    }

    /// The bundle's path, absolute and without "." or "..", for comparing two bundles.
    var standardPath: String { url.absoluteURL.standardizedFileURL.path }

    /// The name people see in Finder ("Microsoft Word" rather than "Word").
    public var displayName: String { url.deletingPathExtension().lastPathComponent }
}

public enum PoofError: Error, CustomStringConvertible {
    case notAnApp(String)
    case appNotFound(String)
    case ambiguous(String, [String])

    public var description: String {
        switch self {
        case .notAnApp(let path): "Not an application bundle: \(path)"
        case .appNotFound(let query): "No installed app matches \"\(query)\""
        case .ambiguous(let query, let names): "\"\(query)\" matches several apps: \(names.joined(separator: ", "))"
        }
    }
}
