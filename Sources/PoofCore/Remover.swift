import Foundation

/// Decides what happens to each found item, then moves the chosen ones into quarantine.
public struct Remover: Sendable {
    public enum Action: Sendable, Equatable {
        case move
        /// Kept, with the reason shown to the user.
        case skip(String)
    }

    public struct PlannedItem: Sendable {
        public let item: Leftover
        public let action: Action
        /// Saved passwords, bookmarks, keychains and the like found inside the item.
        public let sensitiveFiles: [String]
    }

    public enum Outcome: Sendable {
        case moved
        case skipped(String)
        case failed(String)
    }

    public static let needsAdminSkip = Action.skip("needs administrator rights; run with sudo")

    public let quarantine: Quarantine
    let isRoot: Bool
    /// Stops a launch agent or daemon before its plist is moved.
    let stopService: @Sendable (URL) -> Void

    public init(
        quarantine: Quarantine = Quarantine(),
        isRoot: Bool = UserContext.isRoot,
        stopService: @escaping @Sendable (URL) -> Void = Remover.bootout
    ) {
        self.quarantine = quarantine
        self.isRoot = isRoot
        self.stopService = stopService
    }

    public func plan(_ items: [Leftover]) -> [PlannedItem] {
        items.map { item in
            let action: Action
            if item.reason == .systemExtension || item.reason == .orphanedSystemExtension {
                action = .skip("system extensions are protected by macOS; remove it in System Settings > General > Login Items & Extensions")
            } else if !item.sharedWith.isEmpty {
                action = .skip("also used by \(item.sharedWith.joined(separator: ", "))")
            } else if item.isSystem && !isRoot {
                action = Self.needsAdminSkip
            } else {
                action = .move
            }
            return PlannedItem(item: item, action: action, sensitiveFiles: action == .move ? SensitiveData.find(in: item.url) : [])
        }
    }

    /// Moves every `.move` item into one quarantine session.
    public func execute(_ plan: [PlannedItem], appName: String, bundleID: String?) throws -> (Quarantine.Session, [(PlannedItem, Outcome)]) {
        var session = try quarantine.begin(appName: appName, bundleID: bundleID)
        var outcomes: [(PlannedItem, Outcome)] = []
        for planned in plan {
            guard planned.action == .move else {
                if case .skip(let reason) = planned.action { outcomes.append((planned, .skipped(reason))) }
                continue
            }
            if planned.item.url.pathExtension == "plist", planned.item.url.deletingLastPathComponent().lastPathComponent.hasPrefix("Launch") {
                stopService(planned.item.url)
            }
            do {
                try quarantine.move(planned.item.url, size: planned.item.size, into: &session)
                outcomes.append((planned, .moved))
            } catch {
                outcomes.append((planned, .failed(Self.explain(error))))
            }
        }
        if session.entries.isEmpty { try? quarantine.purge(session.id) }
        return (session, outcomes)
    }

    static func explain(_ error: Error) -> String {
        let nsError = error as NSError
        let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        if nsError.code == NSFileWriteNoPermissionError || underlying?.code == Int(EPERM) || underlying?.code == Int(EACCES) {
            return "macOS blocked access; give your terminal Full Disk Access in System Settings > Privacy & Security"
        }
        return nsError.localizedDescription
    }

    /// Unloads a launch agent from the user's session, or a daemon from the system domain.
    public static let bootout: @Sendable (URL) -> Void = { plist in
        let domain = plist.deletingLastPathComponent().lastPathComponent == "LaunchDaemons" ? "system" : "gui/\(UserContext.uid)"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootout", domain, plist.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}

/// Files whose loss people notice: saved passwords, bookmarks, keys.
public enum SensitiveData {
    static let names: Set<String> = [
        "login data", "login data for account", "bookmarks", "cookies", "web data",
        "logins.json", "key4.db", "places.sqlite", "cookies.sqlite", "wallet.dat",
    ]
    static let extensions: Set<String> = ["keychain", "keychain-db", "kdbx", "1pif", "opvault"]

    /// Names of sensitive files inside `url`, relative to it. Stops after a bounded walk
    /// so a huge folder does not stall the plan.
    public static func find(in url: URL, limit: Int = 200_000) -> [String] {
        if matches(url.path) { return [url.lastPathComponent] }
        // Relative paths straight from the enumerator, so /var vs /private/var cannot skew them.
        guard let walker = FileManager.default.enumerator(atPath: url.path) else { return [] }
        var found: [String] = []
        var seen = 0
        while let relative = walker.nextObject() as? String {
            seen += 1
            if seen > limit { break }
            if matches(relative) { found.append(relative) }
            // App bundles inside the item are code, not personal data.
            if relative.hasSuffix(".app") { walker.skipDescendants() }
        }
        return found
    }

    static func matches(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return names.contains(name.lowercased()) || extensions.contains((name as NSString).pathExtension.lowercased())
    }
}
