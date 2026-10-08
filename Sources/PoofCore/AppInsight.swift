import Foundation

/// Poof's judgement of one app: what the evidence says, as plain sentences.
public enum Verdict: Sendable, Equatable {
    /// Ships with macOS. Never offered for removal.
    case partOfMacOS
    /// Another installed app ships a copy of it inside its own bundle.
    case componentOf(String)
    /// Runs something while closed: phrases such as "a launch daemon", "a network extension".
    case runsInBackground([String])
    case managedByHomebrew(cask: String)
    /// Opened within the unused threshold; 0 means today or running now.
    case recentlyUsed(days: Int)
    case unused(days: Int)
    /// From the App Store, and macOS has no record of when it was last opened.
    case fromAppStore
    /// No usage record and no idea where it came from.
    case unknownOrigin
    /// The origin is known but macOS has no record of it being opened.
    case noUsageRecord

    /// One word for a table column.
    public var word: String {
        switch self {
        case .partOfMacOS: "macOS"
        case .componentOf: "component"
        case .runsInBackground: "background"
        case .managedByHomebrew: "homebrew"
        case .recentlyUsed: "in use"
        case .unused: "unused"
        case .fromAppStore: "app store"
        case .unknownOrigin: "unknown"
        case .noUsageRecord: "review"
        }
    }

    /// Whether Poof suggests the app as one to look at for removal.
    public var isRemovalCandidate: Bool {
        if case .unused = self { return true }
        return false
    }
}

/// Why an app is on the Mac and whether removing it is likely to matter.
public struct AppInsight: Sendable, Equatable, Identifiable {
    public let signals: AppSignals
    public let origin: AppOrigin
    public let verdict: Verdict
    /// Short sentences, most important first.
    public let findings: [String]
    /// One line: what Poof suggests doing.
    public let recommendation: String
    /// Whole days since the app was last opened (0 while it runs); nil when macOS has no record.
    public let daysSinceUse: Int?
    /// Days since last use, or since the app was added when macOS has no record of it being opened.
    public let idleDays: Int?

    public var id: String { signals.path }
    public var name: String { signals.name }
    public var vendor: String? { signals.vendor }

    /// Apps not opened for this many days count as unused.
    public static let defaultUnusedDays = 90

    /// Judges an app from its signals alone. Pure: reads nothing from disk.
    public static func evaluate(_ s: AppSignals, now: Date = Date(), unusedAfterDays: Int = defaultUnusedDays) -> AppInsight {
        let origin = AppOrigin(s.origin, signer: s.signer)
        let lastUsedDays = s.isRunning ? 0 : s.lastUsed.map { days(from: $0, to: now) }
        let addedDays = s.dateAdded.map { days(from: $0, to: now) }
        // Parts shipped inside the bundle that macOS has not switched on run nothing yet.
        let active = s.background.filter { !$0.isUpdater && $0.runs(forAppAt: s.path) }
        let dormant = s.background.filter { !$0.isUpdater && !$0.runs(forAppAt: s.path) }
        let updaters = s.background.filter(\.isUpdater)
        let hint = active.compactMap(\.hint).min()

        // Unused: not opened for the threshold, or never opened and added longer ago than that.
        let idleDays = lastUsedDays ?? addedDays
        let unusedDays = idleDays.flatMap { $0 >= unusedAfterDays ? $0 : nil }

        let verdict: Verdict
        if origin == .macOS {
            verdict = .partOfMacOS
        } else if let host = s.embeddedIn.first {
            verdict = .componentOf(host)
        } else if !active.isEmpty {
            verdict = .runsInBackground(backgroundPhrases(active))
        } else if case .homebrew(let cask) = origin {
            verdict = .managedByHomebrew(cask: cask)
        } else if let days = unusedDays {
            verdict = .unused(days: days)
        } else if let used = lastUsedDays {
            verdict = .recentlyUsed(days: used)
        } else if origin == .appStore {
            verdict = .fromAppStore
        } else if origin == .unknown {
            verdict = .unknownOrigin
        } else {
            verdict = .noUsageRecord
        }

        // Findings, most telling first.
        var findings: [String] = []
        findings.append(originSentence(origin, evidence: s.origin))
        if let signature = signatureSentence(s) { findings.append(signature) }
        if AppBundle.claimsAppleBundleID(s.bundleID), !AppBundle.isApples(bundleID: s.bundleID, signer: s.signer), origin != .macOS {
            findings.append("It claims an Apple bundle ID (\(s.bundleID)) but is not signed by Apple.")
        }
        if s.origin.hasAppStoreReceipt, origin != .appStore, origin != .macOS {
            findings.append("It holds an App Store receipt, but the App Store did not sign it, so the receipt says nothing about where it came from.")
        }
        if s.isRunning {
            findings.append("It is running right now.")
        } else if let used = lastUsedDays {
            findings.append(used >= unusedAfterDays ? "Not opened in \(used) days." : "Last opened \(relativeDays(used)).")
        } else if origin != .macOS {
            findings.append("macOS has no record of it being opened.")
        }
        if let added = addedDays, origin != .macOS {
            findings.append("Added to this Mac \(relativeDays(added)).")
        }
        if s.isBackgroundOnly, origin != .macOS {
            findings.append("It has no Dock icon: a menu bar app or a helper that other apps or links start, so macOS may not record when it is used.")
        }
        if !active.isEmpty {
            findings.append("Runs in the background even when it is not open: \(describe(active)).")
            if let hint { findings.append(hintSentence(hint)) }
        }
        // Off for sure, or of unknown state because Poof could not read launchd (or the
        // network extension configurations): only the first is stated as fact.
        let off = dormant.filter { $0.isActive == false }
        let unknown = dormant.filter { $0.isActive == nil }
        if !off.isEmpty {
            findings.append("Can run in the background if enabled, but is not enabled now: \(describe(off)).")
        }
        if !unknown.isEmpty {
            let launchdOnly = unknown.allSatisfy { [.launchAgent, .launchDaemon, .loginItem].contains($0.kind) }
            let why = launchdOnly ? "Poof could not read launchd" : "Poof could not read whether it is enabled"
            findings.append("May run in the background if enabled (\(why)): \(describe(unknown)).")
        }
        if !updaters.isEmpty {
            findings.append("Installs an automatic updater that runs in the background (\(updaters.map(\.identifier).joined(separator: ", "))).")
        }
        if !s.embeddedIn.isEmpty {
            findings.append("\(list(s.embeddedIn)) \(s.embeddedIn.count == 1 ? "ships" : "ship") a copy of it inside \(s.embeddedIn.count == 1 ? "its own app" : "their own apps"), so it is a component rather than a standalone app.")
        }
        if !s.package.otherApps.isEmpty {
            findings.append("Its installer also installed \(list(s.package.otherApps)).")
        }
        if !s.package.otherFiles.isEmpty {
            let shown = s.package.otherFiles.prefix(3).joined(separator: ", ")
            let more = s.package.otherFiles.count > 3 ? " and \(s.package.otherFiles.count - 3) more" : ""
            findings.append("Its installer also put files in \(shown)\(more).")
        }
        if !s.package.relatedPackages.isEmpty {
            let shown = s.package.relatedPackages.prefix(3).joined(separator: ", ")
            let more = s.package.relatedPackages.count > 3 ? " and \(s.package.relatedPackages.count - 3) more" : ""
            findings.append("Installed at the same time as these packages from the same vendor: \(shown)\(more).")
        }
        if !s.companions.isEmpty {
            findings.append("Same developer as \(list(s.companions)).")
        }
        let independent = origin != .macOS && s.embeddedIn.isEmpty && s.package.otherApps.isEmpty
        if independent {
            findings.append("Poof found no other app that depends on it.")
        }

        let recommendation = recommend(verdict, origin: origin, signals: s, hint: hint, unusedDays: unusedDays,
                                       lastUsedDays: lastUsedDays, independent: independent)
        return AppInsight(signals: s, origin: origin, verdict: verdict, findings: findings,
                          recommendation: recommendation, daysSinceUse: lastUsedDays, idleDays: idleDays)
    }

    // MARK: - Sentences

    static func recommend(_ verdict: Verdict, origin: AppOrigin, signals s: AppSignals, hint: BackgroundItem.Hint?,
                          unusedDays: Int?, lastUsedDays: Int?, independent: Bool) -> String {
        let brew: String? = if case .homebrew(let cask) = origin { "brew uninstall --cask \(cask)" } else { nil }
        switch verdict {
        case .partOfMacOS:
            return "Part of macOS. It cannot be removed and does not need to be."
        case .componentOf(let host):
            return "Part of \(host). Remove \(host) instead if you no longer need it; removing this alone may break \(host)."
        case .runsInBackground(let phrases):
            let purpose = switch hint {
            case .device: "it most likely supports a device you connect"
            case .network: "it most likely provides a VPN, firewall or network filter"
            case .security: "it most likely is a security or monitoring product"
            case nil: "something you use may rely on it"
            }
            var text = "Runs \(list(phrases)) in the background; \(purpose). Keep it unless you no longer use that product."
            if let days = unusedDays { text += " It has not been opened in \(days) days." }
            if let brew { text += " If you remove it, use `\(brew)`." }
            return text
        case .managedByHomebrew:
            let usage = unusedDays.map { "Not opened in \($0) days. " } ?? lastUsedDays.map { "Used \(relativeDays($0)). " } ?? ""
            return "\(usage)Installed by Homebrew; remove it with `\(brew ?? "brew uninstall --cask")` so Homebrew stays consistent."
        case .recentlyUsed(let days):
            let when = s.isRunning ? "Running now" : "Used \(relativeDays(days))"
            return "\(when); keep it unless you know you no longer need it."
        case .unused(let days):
            var reasons = [s.lastUsed == nil ? "No record of being opened in the \(days) days since it was added"
                                              : "Not opened in \(days) days"]
            if case .downloaded(let agent, _) = origin {
                reasons.append(agent.map { "downloaded with \($0)" } ?? "downloaded by hand")
            } else if origin == .appStore {
                reasons.append("from the App Store, so you can download it again later")
            }
            if independent { reasons.append("nothing else depends on it") }
            let joined = reasons.count > 1
                ? reasons.dropLast().joined(separator: ", ") + " and " + reasons.last!
                : reasons[0]
            if !s.package.otherApps.isEmpty {
                // Removing this app leaves the others its package installed; say so.
                let others = list(s.package.otherApps)
                let them = s.package.otherApps.count == 1 ? "it" : "them"
                return "\(joined): a candidate to remove, but it was installed together with \(others); removing it leaves \(them) in place, so check what else its installer added first."
            }
            // Without a usage record, a helper may be in use without ever being "opened".
            if s.lastUsed == nil, s.isBackgroundOnly || !s.companions.isEmpty {
                let partner = s.companions.first.map { "\($0), from the same developer" } ?? "another app"
                return "\(joined), but it may work behind the scenes for \(partner): check before removing it."
            }
            return "\(joined): a good candidate to remove."
        case .fromAppStore:
            return "Installed from the App Store, and macOS has no record of when it was last opened. If you remove it, you can download it again from your purchases."
        case .unknownOrigin:
            return "Poof could not tell where it came from or when it was last used. Check the developer above before removing it."
        case .noUsageRecord:
            return "macOS has no record of it being opened. If you do not recognise it, check the developer above before removing it."
        }
    }

    static func originSentence(_ origin: AppOrigin, evidence: OriginEvidence) -> String {
        switch origin {
        case .macOS: return "Part of macOS."
        case .appStore: return "Installed from the App Store."
        case .homebrew(let cask): return "Installed by Homebrew (cask \(cask))."
        case .setapp: return "Installed through Setapp."
        case .installer(let id):
            let more = evidence.packageIDs.count > 1 ? " and \(evidence.packageIDs.count - 1) more" : ""
            return "Installed by an installer package (\(id)\(more))."
        case .downloaded(let agent, let date):
            let by = agent.map { " with \($0)" } ?? ""
            let on = date.map { " on \(formatDate($0))" } ?? ""
            return "Downloaded\(by)\(on), then copied to the Mac by hand."
        case .unknown: return "Poof could not tell how it was installed."
        }
    }

    static func signatureSentence(_ s: AppSignals) -> String? {
        switch s.signer {
        case .apple: return nil
        case .appStore:
            return s.vendor.map { "Distributed through the App Store by \($0)." } ?? "Signed by the App Store."
        case .developerID(let name): return "Signed by \(name), a developer identified by Apple."
        case .development(let name): return "Signed with a development certificate (\(name)), not one meant for distribution."
        case .distribution(let name):
            return "Signed with \(name)'s App Store distribution certificate, which is meant for submitting apps to the App Store, not for installing them directly."
        case .adHoc: return "Not signed by an identified developer."
        case .unsigned: return "Not signed."
        case .other(let name): return "Signed by \(name)."
        case .unverified(let name):
            return name.map { "Its signature names \"\($0)\", but macOS could not verify that Apple issued the certificate, so the name proves nothing." }
                ?? "Its code signature could not be verified."
        }
    }

    static func hintSentence(_ hint: BackgroundItem.Hint) -> String {
        switch hint {
        case .device: "It installs a driver, so it most likely supports a device such as a mouse, keyboard, audio interface or printer."
        case .network: "It installs a network extension, so it most likely provides a VPN, firewall or content filter."
        case .security: "It installs an endpoint security extension, so it most likely is antivirus, monitoring or device management software."
        }
    }

    /// "launch daemon com.x.vpn, network extension com.x.filter"
    static func describe(_ items: [BackgroundItem]) -> String {
        let shown = items.prefix(4).map { item in
            "\(item.noun) \(item.identifier)"
        }
        let more = items.count > 4 ? " and \(items.count - 4) more" : ""
        return shown.joined(separator: ", ") + more
    }

    /// ["a launch daemon", "2 launch agents", "a network extension"]
    static func backgroundPhrases(_ items: [BackgroundItem]) -> [String] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for item in items {
            let noun = item.noun
            if counts[noun] == nil { order.append(noun) }
            counts[noun, default: 0] += 1
        }
        return order.map { noun in
            let count = counts[noun]!
            if count == 1 { return (noun.first.map { "aeiou".contains($0) } == true ? "an " : "a ") + noun }
            return "\(count) \(noun)s"
        }
    }

    // MARK: - Formatting

    /// Whole calendar days between two dates, never negative.
    public static func days(from start: Date, to end: Date, calendar: Calendar = .current) -> Int {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: calendar.startOfDay(for: end)).day ?? 0
        return max(0, days)
    }

    /// 0 -> "today", 1 -> "yesterday", 45 -> "45 days ago", 214 -> "7 months ago", 800 -> "2 years ago"
    public static func relativeDays(_ days: Int) -> String {
        switch days {
        case ..<1: "today"
        case 1: "yesterday"
        case ..<60: "\(days) days ago"
        case ..<730: "\(days / 30) months ago"
        default: "\(days / 365) years ago"
        }
    }

    /// For a table column: "running", "today", "12 days ago", or "never" when macOS has no
    /// record of it being opened.
    public var lastUsedText: String {
        if signals.isRunning { return "running" }
        return daysSinceUse.map(Self.relativeDays) ?? "never"
    }

    static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: date)
    }

    /// "A", "A and B", "A, B and C", "A, B, C and 2 more"
    static func list(_ items: [String]) -> String {
        let shown = Array(items.prefix(3))
        let rest = items.count - shown.count
        if rest > 0 { return shown.joined(separator: ", ") + " and \(rest) more" }
        if shown.count <= 1 { return shown.first ?? "" }
        return shown.dropLast().joined(separator: ", ") + " and " + shown.last!
    }
}

extension AppInsight: Encodable {
    private enum Keys: String, CodingKey {
        case name, bundleID, path, version, vendor, teamID, category, origin, homebrewCask, packageIDs
        case downloadedWith, downloadedOn, lastUsed, dateAdded, daysSinceUse, size, running
        case background, companions, embeddedIn, installedWith, verdict, findings, recommendation
    }

    private struct Background: Encodable {
        let kind: String
        let identifier: String
        let detail: String?
        let path: String?
        let active: Bool?
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        let s = signals
        try c.encode(s.name, forKey: .name)
        try c.encode(s.bundleID, forKey: .bundleID)
        try c.encode(s.path, forKey: .path)
        try c.encodeIfPresent(s.version, forKey: .version)
        try c.encodeIfPresent(s.vendor, forKey: .vendor)
        try c.encodeIfPresent(s.teamID, forKey: .teamID)
        try c.encodeIfPresent(s.category, forKey: .category)
        try c.encode(origin.label, forKey: .origin)
        try c.encodeIfPresent(s.origin.homebrewCask, forKey: .homebrewCask)
        if !s.origin.packageIDs.isEmpty { try c.encode(s.origin.packageIDs, forKey: .packageIDs) }
        try c.encodeIfPresent(s.origin.quarantine?.agent, forKey: .downloadedWith)
        try c.encodeIfPresent(s.origin.quarantine?.date, forKey: .downloadedOn)
        try c.encodeIfPresent(s.lastUsed, forKey: .lastUsed)
        try c.encodeIfPresent(s.dateAdded, forKey: .dateAdded)
        try c.encodeIfPresent(daysSinceUse, forKey: .daysSinceUse)
        try c.encodeIfPresent(s.size, forKey: .size)
        try c.encode(s.isRunning, forKey: .running)
        try c.encode(s.background.map { Background(kind: $0.kind.rawValue, identifier: $0.identifier, detail: $0.detail, path: $0.path,
                                                    active: $0.isActive) },
                     forKey: .background)
        try c.encode(s.companions, forKey: .companions)
        try c.encode(s.embeddedIn, forKey: .embeddedIn)
        try c.encode(s.package.otherApps, forKey: .installedWith)
        try c.encode(verdict.word, forKey: .verdict)
        try c.encode(findings, forKey: .findings)
        try c.encode(recommendation, forKey: .recommendation)
    }
}
