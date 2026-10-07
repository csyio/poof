import Foundation

/// Where removed items wait until they are restored or purged.
///
/// Each removal is a session folder holding the moved items and a manifest of their
/// original paths. Items are moved, not copied, so removal is instant on the same volume
/// and restoring puts back the exact files, permissions and ownership.
public struct Quarantine: Sendable {
    public struct Entry: Codable, Sendable, Equatable {
        public let originalPath: String
        /// Path inside the session folder.
        public let storedName: String
        public let size: Int64
    }

    public struct Session: Codable, Sendable, Equatable {
        public let id: String
        public let appName: String
        public let bundleID: String?
        public let date: Date
        public var entries: [Entry]

        public var totalSize: Int64 { entries.reduce(0) { $0 + $1.size } }
    }

    public enum Failure: Error, CustomStringConvertible {
        case sessionNotFound(String)
        case destinationExists(String)

        public var description: String {
            switch self {
            case .sessionNotFound(let id): "No quarantine session \"\(id)\""
            case .destinationExists(let path): "Not restored, something already exists at \(path)"
            }
        }
    }

    public let root: URL

    public init(root: URL = UserContext.home.appendingPathComponent("Library/Application Support/Poof/Quarantine")) {
        self.root = root
    }

    static let manifestName = "manifest.json"

    /// Starts a session folder for one removal.
    public func begin(appName: String, bundleID: String?, date: Date = Date()) throws -> Session {
        let stamp = ISO8601DateFormatter.string(from: date, timeZone: .current, formatOptions: [.withFullDate, .withTime])
        let slug = appName.lowercased().filter { $0.isLetter || $0.isNumber }
        let id = "\(stamp)-\(slug.isEmpty ? "app" : slug)"
        try FileManager.default.createDirectory(at: root.appendingPathComponent(id), withIntermediateDirectories: true)
        let session = Session(id: id, appName: appName, bundleID: bundleID, date: date, entries: [])
        try save(session)
        // Under sudo these folders would belong to root and the user could not manage them.
        for folder in [root.deletingLastPathComponent(), root, root.appendingPathComponent(id)] {
            Self.handOverToUser(folder)
        }
        return session
    }

    /// Moves `url` into the session. The manifest is saved after every move so a crash
    /// mid-removal still leaves a restorable record.
    public func move(_ url: URL, size: Int64, into session: inout Session) throws {
        let storedName = "\(session.entries.count)-\(url.lastPathComponent)"
        try FileManager.default.moveItem(at: url, to: root.appendingPathComponent(session.id).appendingPathComponent(storedName))
        session.entries.append(Entry(originalPath: url.path, storedName: storedName, size: size))
        try save(session)
    }

    public func save(_ session: Session) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let manifest = root.appendingPathComponent(session.id).appendingPathComponent(Self.manifestName)
        try encoder.encode(session).write(to: manifest)
        Self.handOverToUser(manifest)
    }

    /// Gives a file Poof created to the user who ran `sudo`. Moved items keep their owner.
    static func handOverToUser(_ url: URL) {
        guard UserContext.isRoot, let entry = getpwuid(UserContext.uid) else { return }
        chown(url.path, entry.pointee.pw_uid, entry.pointee.pw_gid)
    }

    /// Sessions, newest first.
    public func sessions() -> [Session] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(Self.manifestName)) else { return nil }
            return try? decoder.decode(Session.self, from: data)
        }.sorted { $0.date > $1.date }
    }

    public func session(_ id: String) -> Session? {
        sessions().first { $0.id == id }
    }

    /// Puts every item back where it was. Items whose original path is taken again
    /// (the app was reinstalled) stay in quarantine and are reported.
    @discardableResult
    public func restore(_ id: String) throws -> [(Entry, Error?)] {
        guard var session = sessions().first(where: { $0.id == id }) else { throw Failure.sessionNotFound(id) }
        let folder = root.appendingPathComponent(id)
        var results: [(Entry, Error?)] = []
        var remaining: [Entry] = []
        for entry in session.entries {
            let destination = URL(fileURLWithPath: entry.originalPath)
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    throw Failure.destinationExists(destination.path)
                }
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: folder.appendingPathComponent(entry.storedName), to: destination)
                results.append((entry, nil))
            } catch {
                remaining.append(entry)
                results.append((entry, error))
            }
        }
        if remaining.isEmpty {
            try FileManager.default.removeItem(at: folder)
        } else {
            session.entries = remaining
            try save(session)
        }
        return results
    }

    /// Permanently deletes a session and everything in it.
    public func purge(_ id: String) throws {
        guard sessions().contains(where: { $0.id == id }) else { throw Failure.sessionNotFound(id) }
        try FileManager.default.removeItem(at: root.appendingPathComponent(id))
    }
}
