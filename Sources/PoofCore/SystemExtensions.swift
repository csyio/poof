import Foundation

/// A system extension (network filter, driver, endpoint security) registered with macOS.
public struct SystemExtension: Sendable, Equatable {
    public let identifier: String
    public let teamID: String?
    public let category: String
    public let state: String
    /// Where macOS keeps its copy, under /Library/SystemExtensions.
    public let stagedPath: String?
    /// The app bundle path it was activated from.
    public let originPath: String?
    public let appIdentifiers: [String]

    /// "com.apple.system_extension.network_extension" -> "network extension"
    public var kind: String {
        category.split(separator: ".").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? category
    }

    /// Extensions listed in macOS's system extension database.
    static func load(from db: URL) -> [SystemExtension] {
        guard let root = NSDictionary(contentsOf: db) as? [String: Any],
              let entries = root["extensions"] as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            guard let identifier = entry["identifier"] as? String else { return nil }
            let staged = (entry["stagedBundleURL"] as? [String: Any])?["relative"] as? String
            let references = entry["references"] as? [[String: Any]] ?? []
            return SystemExtension(
                identifier: identifier,
                teamID: entry["teamID"] as? String,
                category: (entry["categories"] as? [String])?.first ?? "",
                state: entry["state"] as? String ?? "",
                stagedPath: staged.flatMap { URL(string: $0)?.path },
                originPath: entry["originPath"] as? String,
                appIdentifiers: references.compactMap { $0["appIdentifier"] as? String }
            )
        }
    }

    /// Activated from inside the app bundle, or registered on behalf of the app.
    func belongs(to app: AppBundle) -> Bool {
        if let origin = originPath, origin.hasPrefix(app.url.path + "/") { return true }
        let bundleID = app.bundleID.lowercased()
        return appIdentifiers.contains { id in
            let id = id.lowercased()
            return id == bundleID || id.hasPrefix(bundleID + ".")
        }
    }
}
