import Foundation

/// An entry in macOS's background task database: an app that opens at login, a login item
/// inside an app, or a launch agent or daemon. These are what System Settings lists under
/// General > Login Items & Extensions.
///
/// The database is readable only by root, through `sfltool dumpbtm`. Records are not files:
/// macOS drops them when their app or plist is gone, so Poof reports them and never edits them.
public struct LoginItem: Sendable, Equatable, Codable {
    public let name: String
    public let developer: String?
    public let teamID: String?
    /// "app", "login item", "legacy agent", "background tasks"...
    public let type: String
    public let enabled: Bool
    public let identifier: String
    /// What the record points at, resolved to an absolute path.
    public let path: String?
    public let executablePath: String?
    public let bundleID: String?
    public let parentIdentifier: String?
    public let associatedBundleIDs: [String]

    /// False when the app, plist or program the record points at no longer exists.
    public var targetExists: Bool {
        // Relative paths the parent app could not resolve are not evidence of anything.
        [path, executablePath].compactMap { $0 }.filter { $0.hasPrefix("/") }
            .allSatisfy { FileManager.default.fileExists(atPath: $0) }
    }

    /// Types System Settings shows to people: apps that open at login and the
    /// background items apps register. Spotlight, Quick Look and dock tile plug-ins are left out.
    public var isUserFacing: Bool {
        ["app", "login item", "agent", "daemon", "legacy agent", "legacy daemon", "background tasks"].contains(type)
    }

    public enum Failure: Error, CustomStringConvertible {
        case needsAdmin
        case unreadable(String)

        public var description: String {
            switch self {
            case .needsAdmin: "Reading login items needs administrator rights. Run with sudo."
            case .unreadable(let message): "Could not read login items: \(message)"
            }
        }
    }

    /// Reads the database through `sfltool dumpbtm`. Requires root.
    public static func load() throws -> [LoginItem] {
        guard UserContext.isRoot else { throw Failure.needsAdmin }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sfltool")
        process.arguments = ["dumpbtm"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure.unreadable(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return parse(dump: String(decoding: data, as: UTF8.self), uid: UserContext.uid)
    }

    /// Parses `sfltool dumpbtm` output, keeping the records of user `uid` and the
    /// system-wide ones (daemons are filed under UID 0 and -2).
    public static func parse(dump: String, uid: uid_t) -> [LoginItem] {
        var items: [LoginItem] = []
        var sectionUID: Int?
        var fields: [String: String] = [:]
        var associated: [String] = []
        var inAssociated = false

        func flush() {
            defer { fields = [:]; associated = []; inAssociated = false }
            guard let section = sectionUID, section == Int(uid) || section <= 0,
                  let name = fields["Name"], let identifier = fields["Identifier"] else { return }
            let type = (fields["Type"] ?? "").replacingOccurrences(of: #"\s*\(0x[0-9a-f]+\)$"#, with: "", options: .regularExpression)
            let disposition = fields["Disposition"] ?? ""
            items.append(LoginItem(
                name: name,
                developer: nullable(fields["Developer Name"]),
                teamID: nullable(fields["Team Identifier"]),
                type: type,
                enabled: disposition.contains("[enabled"),
                identifier: identifier,
                path: nullable(fields["URL"]).map { resolve($0, uid: section) },
                executablePath: nullable(fields["Executable Path"]).map { resolve($0, uid: section) },
                bundleID: nullable(fields["Bundle Identifier"]),
                parentIdentifier: nullable(fields["Parent Identifier"]),
                associatedBundleIDs: associated
            ))
        }

        for line in dump.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if let match = line.firstMatch(of: /Records for UID (-?\d+)/) {
                flush()
                sectionUID = Int(match.1)
            } else if line.firstMatch(of: /^\s#\d+:\s*$/) != nil {
                flush()
            } else if line.contains("Assoc. Bundle IDs:") {
                // Either "[a, b]" on the same line or "#1: id" lines below.
                let rest = line.components(separatedBy: "Assoc. Bundle IDs:")[1]
                associated += rest.trimmingCharacters(in: CharacterSet(charactersIn: " []"))
                    .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                inAssociated = true
            } else if line.firstMatch(of: /^\s+[A-Za-z. ]+:\s*$/) != nil {
                inAssociated = false  // another list starts, such as "Embedded Item Identifiers:"
            } else if inAssociated, let match = line.firstMatch(of: /^\s+#\d+:\s+(\S+)/) {
                associated.append(String(match.1))
            } else if let match = line.firstMatch(of: /^\s+([A-Za-z. ]+?):\s(.*)$/) {
                inAssociated = false
                let key = String(match.1)
                if fields[key] == nil { fields[key] = String(match.2).trimmingCharacters(in: .whitespaces) }
            }
        }
        flush()

        // Items an app registers itself record paths relative to the app
        // ("Contents/Library/LoginItems/X.app", "Contents/Resources/Tray.app/Contents/MacOS/Tray").
        let byIdentifier = Dictionary(items.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
        return items.map { item in
            guard let base = item.parentIdentifier.flatMap({ byIdentifier[$0] })?.path, base.hasPrefix("/") else { return item }
            func absolute(_ path: String?) -> String? {
                guard let path, !path.hasPrefix("/") else { return path }
                return (base as NSString).appendingPathComponent(path)
            }
            return item.with(path: absolute(item.path), executablePath: absolute(item.executablePath))
        }
    }

    /// Does this record belong to `app` (its bundle ID or a helper's, or a path inside it)?
    public func belongs(to bundleIDs: [String], appPath: String) -> Bool {
        let ids = ([bundleID] + associatedBundleIDs.map { Optional($0) }).compactMap { $0?.lowercased() }
        let owned = ids.contains { id in bundleIDs.contains { id == $0.lowercased() || id.hasPrefix($0.lowercased() + ".") } }
        let inside = [path, executablePath].compactMap { $0 }.contains { $0 == appPath || $0.hasPrefix(appPath + "/") }
        return owned || inside
    }

    func with(path: String?, executablePath: String?) -> LoginItem {
        LoginItem(name: name, developer: developer, teamID: teamID, type: type, enabled: enabled, identifier: identifier,
                  path: path, executablePath: executablePath, bundleID: bundleID, parentIdentifier: parentIdentifier,
                  associatedBundleIDs: associatedBundleIDs)
    }

    /// The database writes paths under the user's home as "/Users/<uid>/..." and some
    /// URLs as "file://..." strings.
    static func resolve(_ raw: String, uid: Int) -> String {
        var path = raw.hasPrefix("file://") ? (URL(string: raw)?.path ?? raw) : raw
        if uid > 0, path.hasPrefix("/Users/\(uid)/"), let entry = getpwuid(uid_t(uid)), let dir = entry.pointee.pw_dir {
            path = String(cString: dir) + "/" + path.dropFirst("/Users/\(uid)/".count)
        }
        return path
    }
}

private func nullable(_ value: String?) -> String? {
    guard let value, value != "(null)", !value.isEmpty else { return nil }
    return value
}
