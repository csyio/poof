import Foundation

/// Decides what happens to each found item, then moves the chosen ones into quarantine.
public struct Remover: Sendable {
    public enum Action: Sendable, Equatable {
        case move
        /// Kept, with the reason shown to the user.
        case skip(String)
    }

    public struct PlannedItem: Sendable, Identifiable {
        public let item: Leftover
        public let action: Action
        /// Saved passwords, bookmarks, keychains and the like found inside the item.
        public let sensitiveFiles: [String]
        public var id: String { item.id }

        public init(item: Leftover, action: Action, sensitiveFiles: [String]) {
            self.item = item
            self.action = action
            self.sensitiveFiles = sensitiveFiles
        }
    }

    public enum Outcome: Sendable {
        case moved
        case skipped(String)
        case failed(String)
    }

    public static let needsAdminSkip = Action.skip("needs administrator rights; run with sudo")

    public let quarantine: Quarantine
    /// Whether items in system folders can be moved: running as root, or (in the app)
    /// because they will be handed to a privileged helper.
    let canWriteSystem: Bool
    /// Stops a launch agent or daemon before its plist is moved.
    let stopService: @Sendable (URL) -> Void

    public init(
        quarantine: Quarantine = Quarantine(),
        canWriteSystem: Bool = UserContext.isRoot,
        stopService: @escaping @Sendable (URL) -> Void = Remover.bootout
    ) {
        self.quarantine = quarantine
        self.canWriteSystem = canWriteSystem
        self.stopService = stopService
    }

    public func plan(_ items: [Leftover]) -> [PlannedItem] {
        items.map { item in
            let action: Action
            if item.reason == .systemExtension || item.reason == .orphanedSystemExtension {
                action = .skip("system extensions are protected by macOS; remove it in System Settings > General > Login Items & Extensions")
            } else if !item.sharedWith.isEmpty {
                action = .skip("also used by \(item.sharedWith.joined(separator: ", "))")
            } else if item.isSystem && !canWriteSystem {
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
        let outcomes = move(plan, into: &session)
        if session.entries.isEmpty { try? quarantine.purge(session.id) }
        return (session, outcomes)
    }

    /// Moves every `.move` item into an existing session, stopping launch items first.
    public func move(_ plan: [PlannedItem], into session: inout Quarantine.Session) -> [(PlannedItem, Outcome)] {
        plan.map { planned in
            if case .skip(let reason) = planned.action { return (planned, .skipped(reason)) }
            if Self.isLaunchItem(planned.item.url) { stopService(planned.item.url) }
            do {
                try quarantine.move(planned.item.url, size: planned.item.size, into: &session)
                return (planned, .moved)
            } catch {
                return (planned, .failed(Self.explain(error)))
            }
        }
    }

    static func isLaunchItem(_ url: URL) -> Bool {
        url.pathExtension == "plist" && url.deletingLastPathComponent().lastPathComponent.hasPrefix("Launch")
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
