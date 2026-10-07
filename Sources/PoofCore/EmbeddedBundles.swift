import Foundation

/// An app, extension or XPC service shipped inside an app bundle. Helpers have their own
/// bundle IDs and leave their own files (DaVinci Resolve's "DaVinci Resolve Welcome" writes
/// com.blackmagic-design.DaVinciResolveWelcome.plist).
public struct EmbeddedBundle: Sendable, Equatable {
    public let bundleID: String
    public let name: String?
    public let executable: String?
}

extension AppBundle {
    /// Identifiers to match files against: the app's own, plus those of helpers inside it
    /// that come from the same vendor. Third-party frameworks are left out so that, say,
    /// Sparkle's updater (org.sparkle-project.*) does not claim other apps' Sparkle files.
    public func identity() -> (bundleIDs: [String], names: [String], executables: [String]) {
        let vendor = Self.vendor(of: bundleID)
        let helpers = embeddedBundles().filter {
            Self.vendor(of: $0.bundleID) == vendor && !isKnownNonApp($0.bundleID)
        }
        let mainExecutable = Bundle(url: url)?.executableURL?.lastPathComponent
        return (
            bundleIDs: unique([bundleID] + helpers.map(\.bundleID)),
            names: unique(names + helpers.compactMap(\.name)),
            executables: unique(([mainExecutable] + helpers.map(\.executable)).compactMap { $0 }.filter { $0.count >= 3 })
        )
    }

    /// Bundles inside this app, found without walking its resources: only folders that hold
    /// code are entered, and nested bundles are not opened further.
    public func embeddedBundles(fileManager: FileManager = .default) -> [EmbeddedBundle] {
        let contents = url.appendingPathComponent("Contents")
        var found: [EmbeddedBundle] = []
        var queue: [(URL, Int)] = [(contents, 0)]
        var visited = 0
        while let (dir, depth) = queue.popLast(), visited < 5_000 {
            visited += 1
            let entries = (try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            for entry in entries {
                if ["app", "appex", "xpc", "systemextension"].contains(entry.pathExtension) {
                    if let bundle = Bundle(url: entry), let id = bundle.bundleIdentifier {
                        found.append(EmbeddedBundle(
                            bundleID: id,
                            name: bundle.infoDictionary?["CFBundleName"] as? String,
                            executable: bundle.executableURL?.lastPathComponent
                        ))
                    }
                    continue
                }
                let isFolder = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                // Resources and localizations can hold tens of thousands of files and no code.
                if isFolder, depth < 6, !["Resources", "_CodeSignature", "Headers", "Modules"].contains(entry.lastPathComponent),
                   entry.pathExtension != "lproj" {
                    queue.append((entry, depth + 1))
                }
            }
        }
        return found
    }

    /// Helpers this app shares with other installed apps from the same vendor, mapped to
    /// those apps' names. Every Office app embeds com.microsoft.errorreporting, so removing
    /// Word must leave its files alone. Helpers named under the app's own ID
    /// (com.microsoft.Word.widgetextension) belong to it alone and are not checked.
    public func sharedHelpers(among others: [AppBundle]? = nil) -> [String: [String]] {
        let own = bundleID.lowercased()
        let candidates = identity().bundleIDs.map { $0.lowercased() }.filter { $0 != own && !$0.hasPrefix(own + ".") }
        guard !candidates.isEmpty else { return [:] }
        let vendor = Self.vendor(of: bundleID)
        let siblings = (others ?? Self.installedAppURLs().compactMap { try? AppBundle(at: $0) })
            .filter { $0.url != url && Self.vendor(of: $0.bundleID) == vendor }
        var shared: [String: [String]] = [:]
        for sibling in siblings {
            let ids = Set(([sibling.bundleID] + sibling.embeddedBundles().map(\.bundleID)).map { $0.lowercased() })
            for id in candidates where ids.contains(id) {
                shared[id, default: []].append(sibling.displayName)
            }
        }
        return shared
    }

    static func vendor(of id: String) -> String {
        id.lowercased().split(separator: ".").prefix(2).joined(separator: ".")
    }
}

private func unique(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.filter { seen.insert($0.lowercased()).inserted }
}
