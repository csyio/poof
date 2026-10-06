import Foundation
import Security

/// An installed application and the identifiers used to find its leftovers.
public struct AppBundle: Sendable, Equatable {
    public let url: URL
    public let name: String
    public let bundleID: String
    public let teamID: String?
    /// Labels of helpers the app installs into /Library/PrivilegedHelperTools (`SMPrivilegedExecutables`).
    public let privilegedHelpers: [String]

    public init(url: URL, name: String, bundleID: String, teamID: String?, privilegedHelpers: [String] = []) {
        self.url = url
        self.name = name
        self.bundleID = bundleID
        self.teamID = teamID
        self.privilegedHelpers = privilegedHelpers
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
        self.init(url: url, name: name, bundleID: bundleID, teamID: Self.teamID(of: url), privilegedHelpers: helpers)
    }

    /// Resolves a user-supplied name ("chrome", "Google Chrome") or path to an installed app.
    public static func find(_ query: String, fileManager: FileManager = .default) throws -> AppBundle {
        if query.hasSuffix(".app"), fileManager.fileExists(atPath: query) {
            return try AppBundle(at: URL(fileURLWithPath: query))
        }
        let dirs = ["/Applications", "/Applications/Utilities", UserContext.home.path + "/Applications"]
        // Some apps ship inside a folder ("/Applications/DaVinci Resolve/DaVinci Resolve.app").
        func apps(in dir: URL, depth: Int) -> [URL] {
            let entries = (try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            return entries.flatMap { entry -> [URL] in
                if entry.pathExtension == "app" { return [entry] }
                let isFolder = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                return depth > 0 && isFolder ? apps(in: entry, depth: depth - 1) : []
            }
        }
        let apps = dirs.flatMap { apps(in: URL(fileURLWithPath: $0), depth: 1) }
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

    private static func teamID(of url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(code, flags, &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }
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
