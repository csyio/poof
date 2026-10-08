import AppKit
import CoreServices
import Foundation
import Security

/// Where Poof looks when it gathers insights. Tests point these at fixture folders and
/// replace the parts that ask macOS (Spotlight, running apps).
public struct InsightSources: Sendable {
    public var home: URL
    public var systemRoot: URL
    /// Homebrew's Caskroom folders (Apple silicon and Intel locations).
    public var caskrooms: [URL]
    public var packages: any PackageDatabase
    /// Walking a large bundle takes time; the CLI and app turn this on.
    public var measureSize: Bool
    public var runningBundleIDs: @Sendable () -> Set<String>
    public var spotlight: @Sendable (URL) -> SpotlightDates
    /// The launch jobs launchd has loaded. Tests replace it.
    public var launchdJobs: @Sendable () -> LaunchdJobs
    /// Reads a bundle's code signature when the `AppBundle` does not carry one. Tests replace it.
    var codeSignature: @Sendable (URL) -> CodeSignature = CodeSignature.read

    public init(
        home: URL = UserContext.home,
        systemRoot: URL = URL(fileURLWithPath: "/"),
        caskrooms: [URL]? = nil,
        packages: any PackageDatabase = SystemPackageDatabase(),
        measureSize: Bool = true,
        runningBundleIDs: @escaping @Sendable () -> Set<String> = InsightSources.runningApps,
        spotlight: @escaping @Sendable (URL) -> SpotlightDates = SpotlightDates.init(of:),
        launchdJobs: @escaping @Sendable () -> LaunchdJobs = LaunchdJobs.current
    ) {
        self.home = home
        self.systemRoot = systemRoot
        self.caskrooms = caskrooms ?? ["opt/homebrew/Caskroom", "usr/local/Caskroom"].map { systemRoot.appendingPathComponent($0) }
        self.packages = packages
        self.measureSize = measureSize
        self.runningBundleIDs = runningBundleIDs
        self.spotlight = spotlight
        self.launchdJobs = launchdJobs
    }

    public static let runningApps: @Sendable () -> Set<String> = {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }
}

/// The labels of the jobs launchd has loaded: in this user's login session (agents, login
/// items) and in the system domain (daemons). A bundle can carry agents it never registers;
/// only a loaded one runs.
public struct LaunchdJobs: Sendable, Equatable {
    /// Nil when launchctl could not list the domain: unknown, not "nothing loaded".
    public var user: Set<String>?
    public var system: Set<String>?

    public init(user: Set<String>?, system: Set<String>?) {
        self.user = user
        self.system = system
    }

    /// Whether the job is loaded, or nil when the domain could not be read.
    func isLoaded(_ label: String, daemon: Bool) -> Bool? {
        (daemon ? system : user).map { $0.contains(label) }
    }

    /// Reads `launchctl print gui/<uid>` and `launchctl print system`. Read-only.
    public static let current: @Sendable () -> LaunchdJobs = {
        LaunchdJobs(user: services(inDomain: "gui/\(UserContext.uid)"), system: services(inDomain: "system"))
    }

    static func services(inDomain domain: String) -> Set<String>? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", domain]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return parseServices(String(decoding: data, as: UTF8.self))
    }

    /// The labels in the top-level `services = { ... }` block, one job per line:
    /// "<pid or 0>  <last exit status or ->  <label>". Nil when there is no such block.
    static func parseServices(_ output: String) -> Set<String>? {
        var labels: Set<String>?
        var inside = false
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if !inside {
                if line == "\tservices = {" { inside = true; labels = [] }
                continue
            }
            if line == "\t}" { break }
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if fields.count >= 3 { labels?.insert(String(fields[2...].joined(separator: " "))) }
        }
        return labels
    }
}

/// Network extension providers macOS has a configuration for (a VPN, a content filter), by
/// bundle ID, from /Library/Preferences/com.apple.networkextension.plist. An empty set when
/// the file does not exist; nil when it exists but cannot be read.
enum NetworkExtensionConfigurations {
    static func providerIDs(in url: URL) -> Set<String>? {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        guard let data = try? Data(contentsOf: url),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return nil }
        // A keyed archive: the configurations' strings, provider bundle IDs among them, sit in `$objects`.
        var strings = Set<String>()
        func collect(_ value: Any) {
            switch value {
            case let text as String: strings.insert(text)
            case let array as [Any]: array.forEach(collect)
            case let dict as [String: Any]: dict.values.forEach(collect)
            default: break
            }
        }
        collect(root)
        return strings
    }
}

/// Dates Spotlight keeps for a file. Readable without Full Disk Access.
public struct SpotlightDates: Sendable, Equatable {
    /// When the app was last opened through Finder, the Dock or `open` (`kMDItemLastUsedDate`).
    public var lastUsed: Date?
    /// When the bundle appeared in its folder (`kMDItemDateAdded`). App updates that replace
    /// the bundle reset it.
    public var added: Date?

    public init(lastUsed: Date? = nil, added: Date? = nil) {
        self.lastUsed = lastUsed
        self.added = added
    }

    public init(of url: URL) {
        guard let item = MDItemCreate(kCFAllocatorDefault, url.resolvingSymlinksInPath().path as CFString) else {
            self.init()
            return
        }
        self.init(
            lastUsed: MDItemCopyAttribute(item, "kMDItemLastUsedDate" as CFString) as? Date,
            added: MDItemCopyAttribute(item, "kMDItemDateAdded" as CFString) as? Date
        )
    }
}

/// The parts of a code signature Poof reads: who signed it and the team ID, each trusted only
/// as far as macOS could verify the signature against Apple's certificate requirements.
struct CodeSignature: Sendable, Equatable {
    let signer: Signer
    /// The team ID, only when the signature validates and the Apple-issued leaf certificate
    /// names that team. A team ID that is merely written into the signature is never used to
    /// link apps, extensions or files to each other.
    let teamID: String?

    static let unsigned = CodeSignature(signer: .unsigned, teamID: nil)

    /// Checks the signature itself and its certificate chain, without hashing the executable
    /// or the bundle's resources (`kSecCSBasicValidateOnly`), and without going online.
    static let checkFlags = SecCSFlags(rawValue: kSecCSBasicValidateOnly).union(.noNetworkAccess)

    nonisolated(unsafe) private static let appStore = requirement(
        "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.9] exists")
    nonisolated(unsafe) private static let developerID = requirement(
        "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists")
    nonisolated(unsafe) private static let apple = requirement("anchor apple")
    nonisolated(unsafe) private static let appleIssued = requirement("anchor apple generic")

    private static func requirement(_ text: String) -> SecRequirement? {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }

    static func read(_ url: URL) -> CodeSignature {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return .unsigned }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return .unsigned }
        let isSigned = dict[kSecCodeInfoIdentifier as String] != nil
        let certificates = dict[kSecCodeInfoCertificates as String] as? [SecCertificate] ?? []
        let leaf = certificates.first.flatMap { SecCertificateCopySubjectSummary($0) as String? }
        let trust = isSigned && !certificates.isEmpty ? Self.trust(of: code) : .none
        let signer = Signer(leafCommonName: leaf, isSigned: isSigned, trust: trust)

        // Apple signs App Store apps and its own code itself, team ID included. Any other
        // certificate must name the team it claims.
        var team: String?
        if let claimed = dict[kSecCodeInfoTeamIdentifier as String] as? String, !claimed.isEmpty,
           claimed.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.alphanumerics.contains($0) }) {
            switch trust {
            case .apple, .appStore: team = claimed
            case .developerID, .appleIssued:
                if satisfies(code, requirement("anchor apple generic and certificate leaf[subject.OU] = \"\(claimed)\"")) { team = claimed }
            case .none: break
            }
        }
        return CodeSignature(signer: signer, teamID: team)
    }

    /// The strongest Apple requirement the signature meets. The first check validates the
    /// signature; macOS keeps that result on `code`, so the requirement checks after it are cheap.
    static func trust(of code: SecStaticCode) -> SignatureTrust {
        guard satisfies(code, nil, allowNil: true) else { return .none }
        if satisfies(code, appStore) { return .appStore }
        if satisfies(code, developerID) { return .developerID }
        if satisfies(code, apple) { return .apple }
        if satisfies(code, appleIssued) { return .appleIssued }
        return .none
    }

    private static func satisfies(_ code: SecStaticCode, _ requirement: SecRequirement?, allowNil: Bool = false) -> Bool {
        guard requirement != nil || allowNil else { return false }
        return SecStaticCodeCheckValidity(code, checkFlags, requirement) == errSecSuccess
    }
}

/// Apps Homebrew installed, by `.app` file name (lowercased), with the cask and the path
/// each was installed to.
enum HomebrewCasks {
    struct App: Sendable, Equatable {
        let cask: String
        /// Where the cask put the app, with symbolic links resolved.
        let path: String
    }

    typealias Index = [String: [App]]

    /// Each cask keeps `<Caskroom>/<cask>/<version>/` with a link to the app it installed,
    /// and lists its apps in `.metadata/INSTALL_RECEIPT.json` in case the link is gone; those
    /// are taken to be in the cask's app folder (`--appdir`, recorded in `.metadata/config.json`,
    /// or `appDir`).
    static func index(caskrooms: [URL], appDir: URL, fileManager: FileManager = .default) -> Index {
        var index: Index = [:]
        for room in caskrooms {
            for caskDir in (try? fileManager.contentsOfDirectory(at: room, includingPropertiesForKeys: nil)) ?? []
            where isCaskName(caskDir.lastPathComponent) {
                let cask = caskDir.lastPathComponent
                let folder = configuredAppDir(caskDir.appendingPathComponent(".metadata/config.json")) ?? appDir
                var names = Set<String>()
                for version in (try? fileManager.contentsOfDirectory(at: caskDir, includingPropertiesForKeys: nil)) ?? []
                where !version.lastPathComponent.hasPrefix(".") {
                    for entry in (try? fileManager.contentsOfDirectory(at: version, includingPropertiesForKeys: nil)) ?? []
                    where entry.pathExtension == "app" {
                        let name = entry.lastPathComponent.lowercased()
                        // The link points at the installed app; a real bundle here is not the installed one.
                        let isLink = (try? fileManager.destinationOfSymbolicLink(atPath: entry.path)) != nil
                        let target = isLink ? entry : folder.appendingPathComponent(entry.lastPathComponent)
                        index[name, default: []].append(App(cask: cask, path: target.resolvingSymlinksInPath().path))
                        names.insert(name)
                    }
                }
                let receipt = caskDir.appendingPathComponent(".metadata/INSTALL_RECEIPT.json")
                for app in receiptApps(receipt) where !names.contains(app.lowercased()) {
                    index[app.lowercased(), default: []].append(
                        App(cask: cask, path: folder.appendingPathComponent(app).resolvingSymlinksInPath().path))
                }
            }
        }
        return index
    }

    /// The cask that installed the app at `url`: one whose app has the same name and was
    /// installed to the same place. A copy of a cask's app elsewhere is not Homebrew's.
    static func cask(of url: URL, in index: Index) -> String? {
        guard let entries = index[url.lastPathComponent.lowercased()] else { return nil }
        let path = url.absoluteURL.standardizedFileURL.resolvingSymlinksInPath().path
        return entries.first { $0.path.caseInsensitiveCompare(path) == .orderedSame }?.cask
    }

    /// `{"explicit": {"appdir": "~/Applications"}, "default": {"appdir": "/Applications"}}`
    /// `~` is the user's home from `UserContext`, which stays right under sudo.
    static func configuredAppDir(_ url: URL, home: URL = UserContext.home) -> URL? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let explicit = (root["explicit"] as? [String: Any])?["appdir"] as? String
        let fallback = (root["default"] as? [String: Any])?["appdir"] as? String
        guard let dir = explicit ?? fallback, !dir.isEmpty else { return nil }
        let expanded: String
        if dir == "~" || dir.hasPrefix("~/") {
            expanded = home.path + dir.dropFirst()
        } else {
            expanded = (dir as NSString).expandingTildeInPath  // ~otheruser/...
        }
        return expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : nil
    }

    /// Cask tokens are lowercase letters, digits and `-+@._`. Anything else is not a cask, and
    /// is never printed into a suggested `brew` command.
    static func isCaskName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".")
            && name.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-+@._").contains($0) }
    }

    /// `"uninstall_artifacts": [{"app": ["Raycast.app"]}]`; an entry can also be
    /// `["Source.app", {"target": "Target.app"}]`, where the target is the installed name.
    static func receiptApps(_ url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let artifacts = root["uninstall_artifacts"] as? [[String: Any]] else { return [] }
        var names: [String] = []
        for artifact in artifacts {
            guard let apps = artifact["app"] as? [Any] else { continue }
            var pending: String?
            for value in apps {
                if let name = value as? String {
                    if let pending { names.append(pending) }
                    pending = (name as NSString).lastPathComponent
                } else if let options = value as? [String: Any], let target = options["target"] as? String {
                    pending = (target as NSString).lastPathComponent
                }
            }
            if let pending { names.append(pending) }
        }
        return names.filter { $0.hasSuffix(".app") }
    }
}

extension OriginEvidence {
    /// Reads the origin hints stored with the bundle itself. Package receipts are looked up
    /// separately because listing them is slow.
    static func gather(at url: URL, systemRoot: URL, casks: HomebrewCasks.Index, packageIDs: [String] = []) -> OriginEvidence {
        let fm = FileManager.default
        let resolved = url.resolvingSymlinksInPath().path
        let system = systemRoot.appendingPathComponent("System").standardizedFileURL.path
        let setapp = systemRoot.appendingPathComponent("Applications/Setapp").standardizedFileURL.path
        return OriginEvidence(
            isInSystemFolder: resolved.hasPrefix(system + "/") || url.path.hasPrefix(system + "/"),
            hasAppStoreReceipt: fm.fileExists(atPath: url.appendingPathComponent("Contents/_MASReceipt/receipt").path),
            homebrewCask: HomebrewCasks.cask(of: url, in: casks),
            isInSetapp: url.standardizedFileURL.path.hasPrefix(setapp + "/"),
            packageIDs: packageIDs,
            quarantine: quarantineAttribute(of: url).flatMap(QuarantineInfo.init(attribute:))
        )
    }

    static func quarantineAttribute(of url: URL) -> String? {
        let name = "com.apple.quarantine"
        let size = getxattr(url.path, name, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        let read = getxattr(url.path, name, &buffer, size, 0, 0)
        guard read > 0 else { return nil }
        return String(decoding: buffer.prefix(read), as: UTF8.self)
    }
}

/// Memoises `pkgutil` calls for one run: many apps share a vendor's packages.
final class CachingPackageDatabase: PackageDatabase, @unchecked Sendable {
    private let base: any PackageDatabase
    private let lock = NSLock()
    private var ids: [String]?
    private var filesByID: [String: [String]] = [:]
    private var locations: [String: String] = [:]
    private var times: [String: Date?] = [:]

    init(_ base: any PackageDatabase) { self.base = base }

    func packageIDs() -> [String] {
        lock.lock(); defer { lock.unlock() }
        if let ids { return ids }
        let loaded = base.packageIDs()
        ids = loaded
        return loaded
    }

    func files(of packageID: String) -> [String] {
        lock.lock()
        if let cached = filesByID[packageID] { lock.unlock(); return cached }
        lock.unlock()
        let loaded = base.files(of: packageID)
        lock.lock(); filesByID[packageID] = loaded; lock.unlock()
        return loaded
    }

    func installLocation(of packageID: String) -> String {
        lock.lock()
        if let cached = locations[packageID] { lock.unlock(); return cached }
        lock.unlock()
        let loaded = base.installLocation(of: packageID)
        lock.lock(); locations[packageID] = loaded; lock.unlock()
        return loaded
    }

    func installTime(of packageID: String) -> Date? {
        lock.lock()
        if let cached = times[packageID] { lock.unlock(); return cached }
        lock.unlock()
        let loaded = base.installTime(of: packageID)
        lock.lock(); times[packageID] = loaded; lock.unlock()
        return loaded
    }
}

/// A launch agent or daemon plist, read once per run and matched against every app.
struct LaunchPlist: Sendable {
    let url: URL
    let label: String
    /// The file name without ".plist", lowercased.
    let stem: String
    let fields: LaunchJobFields
    let isDaemon: Bool

    init?(_ url: URL, isDaemon: Bool) {
        guard url.pathExtension == "plist" else { return nil }
        let dict = NSDictionary(contentsOf: url) as? [String: Any] ?? [:]
        self.url = url
        label = (dict["Label"] as? String) ?? url.deletingPathExtension().lastPathComponent
        stem = LeftoverScanner.stripExtensions(url.lastPathComponent.lowercased())
        fields = LaunchJobFields(dict)
        self.isDaemon = isDaemon
    }

    static func load(from dir: URL, isDaemon: Bool) -> [LaunchPlist] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .compactMap { LaunchPlist($0, isDaemon: isDaemon) }
    }

    /// The rule `LeftoverScanner.match` applies to launch plists: named after one of the
    /// app's bundle IDs (lowercased), running a program inside the bundle, or naming the app
    /// as associated.
    func belongs(toBundleIDs ids: [String], appPath: String) -> Bool {
        LeftoverScanner.Identity.owner(of: stem, among: ids) != nil || fields.starts(appPath: appPath, bundleIDs: ids)
    }
}

/// App extension points macOS runs as network extensions (VPN tunnels, proxies, filters).
let networkExtensionPoints: Set<String> = [
    "com.apple.networkextension.packet-tunnel",
    "com.apple.networkextension.app-proxy",
    "com.apple.networkextension.filter-data",
    "com.apple.networkextension.filter-packet",
    "com.apple.networkextension.dns-proxy",
]

/// What every app's insight needs, gathered once per run.
final class InsightContext: Sendable {
    let sources: InsightSources
    let installed: [AppBundle]
    let running: Set<String>
    let casks: HomebrewCasks.Index
    let launchd: LaunchdJobs
    /// Network extension providers macOS has a configuration for; nil when unreadable.
    let networkProviders: Set<String>?
    let systemExtensions: [SystemExtension]
    /// Kernel extensions in /Library/Extensions with their verified team IDs.
    let kernelExtensions: [(id: String, teamID: String, path: String)]
    /// Bundle ID (lowercased) of every helper inside an installed app -> those apps' paths
    /// (standardized).
    let embedders: [String: [String]]
    /// The bundles inside each installed app, by standardized app path, so each app is walked once.
    let embedded: [String: [EmbeddedBundle]]
    /// Launch agents and daemons in the user's and the system's Library, parsed once.
    let launchPlists: [LaunchPlist]
    let packages: CachingPackageDatabase

    init(sources: InsightSources, installed: [AppBundle]) {
        self.sources = sources
        self.installed = installed
        running = sources.runningBundleIDs()
        launchd = sources.launchdJobs()
        casks = HomebrewCasks.index(caskrooms: sources.caskrooms, appDir: sources.systemRoot.appendingPathComponent("Applications"))
        let library = sources.systemRoot.appendingPathComponent("Library")
        networkProviders = NetworkExtensionConfigurations.providerIDs(
            in: library.appendingPathComponent("Preferences/com.apple.networkextension.plist"))
        systemExtensions = SystemExtension.load(from: library.appendingPathComponent("SystemExtensions/db.plist"))
        let kexts = (try? FileManager.default.contentsOfDirectory(at: library.appendingPathComponent("Extensions"),
                                                                   includingPropertiesForKeys: nil)) ?? []
        kernelExtensions = kexts.filter { $0.pathExtension == "kext" }.compactMap { url in
            guard let team = sources.codeSignature(url).teamID else { return nil }
            return (Bundle(url: url)?.bundleIdentifier ?? url.deletingPathExtension().lastPathComponent, team, url.path)
        }
        var embedders: [String: [String]] = [:]
        var embedded: [String: [EmbeddedBundle]] = [:]
        for app in installed where embedded[app.standardPath] == nil {
            let helpers = app.embeddedBundles()
            embedded[app.standardPath] = helpers
            for helper in helpers {
                embedders[helper.bundleID.lowercased(), default: []].append(app.standardPath)
            }
        }
        self.embedders = embedders
        self.embedded = embedded
        launchPlists = [sources.home.appendingPathComponent("Library"), library].flatMap { base in
            LaunchPlist.load(from: base.appendingPathComponent("LaunchAgents"), isDaemon: false)
                + LaunchPlist.load(from: base.appendingPathComponent("LaunchDaemons"), isDaemon: true)
        }
        packages = CachingPackageDatabase(sources.packages)
    }

    /// The app's own bundle ID and its same-vendor helpers', as `AppBundle.identity()` gives them.
    func bundleIDs(of app: AppBundle) -> [String] {
        app.identity(embedded: embeddedBundles(of: app)).bundleIDs
    }

    func embeddedBundles(of app: AppBundle) -> [EmbeddedBundle] {
        embedded[app.standardPath] ?? app.embeddedBundles()
    }

    func signals(for app: AppBundle) -> AppSignals {
        var s = AppSignals(name: app.displayName, bundleID: app.bundleID, path: app.url.path)
        let info = Bundle(url: app.url)?.infoDictionary ?? [:]
        s.version = (info["CFBundleShortVersionString"] as? String) ?? (info["CFBundleVersion"] as? String)
        s.category = (info["LSApplicationCategoryType"] as? String).flatMap(AppSignals.humanize(category:))
        s.copyright = (info["NSHumanReadableCopyright"] as? String) ?? (info["CFBundleGetInfoString"] as? String)
        s.isBackgroundOnly = Self.flag(info["LSUIElement"]) || Self.flag(info["LSBackgroundOnly"])

        // Read once when the app was loaded; the team ID is set only for a verified signature.
        let signature = app.signature ?? sources.codeSignature(app.url)
        s.signer = signature.signer
        s.teamID = signature.teamID

        // macOS's own apps come with hundreds of system packages; their receipts say nothing useful.
        let isApple = AppBundle.isApples(bundleID: app.bundleID, signer: signature.signer)
        let matches = isApple ? [] : packages.packages(for: app)
        s.origin = OriginEvidence.gather(at: app.url, systemRoot: sources.systemRoot, casks: casks,
                                         packageIDs: matches.map(\.packageID))
        s.package = relations(of: matches, app: app)

        let dates = sources.spotlight(app.url)
        s.lastUsed = dates.lastUsed
        s.dateAdded = dates.added
        if sources.measureSize { s.size = LeftoverScanner.size(of: app.url.resolvingSymlinksInPath()) }

        let ids = bundleIDs(of: app)
        let path = app.standardPath
        // An `.app` helper inside the app (a login item, a menu bar agent) running counts as the
        // app running, unless another installed app ships the same helper.
        s.runningIdentifiers = app.runningIdentifiers(embedded: embeddedBundles(of: app)) { id in
            (embedders[id] ?? []).contains { $0 != path }
        }
        s.isRunning = s.runningIdentifiers.contains(where: running.contains)

        if let team = s.teamID {
            s.companions = unique(installed.filter { $0.standardPath != path && $0.teamID == team }.map(\.displayName))
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        }
        let hosts = (embedders[app.bundleID.lowercased()] ?? []).filter { $0 != path }
        s.embeddedIn = unique(hosts.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent })
        s.background = background(of: app, bundleIDs: ids, teamID: s.teamID)
        return s
    }

    /// Info.plist booleans appear as true, 1 or "1".
    static func flag(_ value: Any?) -> Bool {
        switch value {
        case let bool as Bool: bool
        case let number as NSNumber: number.boolValue
        case let string as String: ["1", "true", "yes"].contains(string.lowercased())
        default: false
        }
    }

    /// `teamID` must be a verified one: it links kernel extensions to the app.
    func background(of app: AppBundle, bundleIDs ids: [String], teamID: String?) -> [BackgroundItem] {
        let fm = FileManager.default
        let library = sources.systemRoot.appendingPathComponent("Library")
        let contents = app.url.appendingPathComponent("Contents")
        // Built from the app's own path rather than the listing's (which can say /private/var
        // for /var), so `BackgroundItem.runs(forAppAt:)` sees them as inside the bundle.
        func entries(_ relative: String, _ ext: String) -> [URL] {
            let dir = contents.appendingPathComponent(relative)
            return ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
                .filter { ($0 as NSString).pathExtension == ext }
                .sorted()
                .map { dir.appendingPathComponent($0) }
        }
        var items: [BackgroundItem] = []

        let helpers = app.privilegedHelpers.filter {
            fm.fileExists(atPath: library.appendingPathComponent("PrivilegedHelperTools/\($0)").path)
        }
        // A privileged helper runs through a launch daemon with the same label; list it once.
        var labels = Set(helpers)
        let lowered = ids.map { $0.lowercased() }
        for plist in launchPlists where plist.belongs(toBundleIDs: lowered, appPath: app.standardPath) {
            guard labels.insert(plist.label).inserted else { continue }
            items.append(BackgroundItem(kind: plist.isDaemon ? .launchDaemon : .launchAgent, identifier: plist.label, path: plist.url.path))
        }
        // Agents and daemons the app can register from inside its bundle (SMAppService). They
        // run only once registered, so each is checked against what launchd has loaded.
        for (folder, isDaemon) in [("Library/LaunchAgents", false), ("Library/LaunchDaemons", true)] {
            for url in entries(folder, "plist") {
                guard let plist = LaunchPlist(url, isDaemon: isDaemon), labels.insert(plist.label).inserted else { continue }
                items.append(BackgroundItem(kind: isDaemon ? .launchDaemon : .launchAgent, identifier: plist.label, path: url.path,
                                            isActive: launchd.isLoaded(plist.label, daemon: isDaemon)))
            }
        }
        for label in helpers {
            items.append(BackgroundItem(kind: .privilegedHelper, identifier: label,
                                        path: library.appendingPathComponent("PrivilegedHelperTools/\(label)").path))
        }
        for ext in systemExtensions where ext.belongs(to: app) && ext.state.hasPrefix("activated") {
            items.append(BackgroundItem(kind: .systemExtension, identifier: ext.identifier, detail: ext.kind, path: ext.stagedPath))
        }
        // Network extensions shipped as app extensions, as App Store VPNs do (WireGuard). One
        // runs only once a VPN or filter configuration (or a system extension) names it.
        let activated = Set(systemExtensions.filter { $0.state.hasPrefix("activated") }.map(\.identifier))
        for appex in entries("PlugIns", "appex") {
            let info = NSDictionary(contentsOf: appex.appendingPathComponent("Contents/Info.plist")) as? [String: Any] ?? [:]
            guard let point = (info["NSExtension"] as? [String: Any])?["NSExtensionPointIdentifier"] as? String,
                  networkExtensionPoints.contains(point) else { continue }
            let id = (info["CFBundleIdentifier"] as? String) ?? appex.deletingPathExtension().lastPathComponent
            let configured: Bool? = activated.contains(id) ? true : networkProviders.map { $0.contains(id) }
            items.append(BackgroundItem(kind: .appExtension, identifier: id, detail: "network extension", path: appex.path,
                                        isActive: configured))
        }
        // A login item helper runs once the app registers it, as a job in the user's session.
        for helper in entries("Library/LoginItems", "app") {
            let id = Bundle(url: helper)?.bundleIdentifier ?? helper.deletingPathExtension().lastPathComponent
            let loaded: Bool? = running.contains(id) ? true : launchd.isLoaded(id, daemon: false)
            items.append(BackgroundItem(kind: .loginItem, identifier: id, path: helper.path, isActive: loaded))
        }
        if let teamID {
            for kext in kernelExtensions where kext.teamID == teamID {
                items.append(BackgroundItem(kind: .kernelExtension, identifier: kext.id, path: kext.path))
            }
        }
        return items
    }

    func relations(of matches: [PackageMatch], app: AppBundle) -> PackageRelations {
        guard !matches.isEmpty else { return PackageRelations() }
        // Packages from the same vendor installed within an hour of this app's: usually one
        // installer that put several things on the Mac (an Office suite, a driver bundle).
        let matched = Set(matches.map(\.packageID))
        let vendors = Set(matches.map { AppBundle.vendor(of: $0.packageID) })
        let times = matches.compactMap { packages.installTime(of: $0.packageID) }
        let related = packages.packageIDs().filter { id in
            guard !matched.contains(id), vendors.contains(AppBundle.vendor(of: id)),
                  let time = packages.installTime(of: id) else { return false }
            return times.contains { abs($0.timeIntervalSince(time)) <= 3600 }
        }
        return PackageRelations(
            otherApps: unique(matches.flatMap(\.otherApps).filter { $0 != app.url.lastPathComponent }
                .map { ($0 as NSString).deletingPathExtension }),
            otherFiles: unique(matches.flatMap(\.ownedPaths).filter(\.sharedWith.isEmpty).map { "/" + $0.path }),
            relatedPackages: related.sorted()
        )
    }
}

private func unique(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.filter { seen.insert($0).inserted }
}

extension AppInsight {
    /// Gathers evidence about one app and judges it. `installed` is the list companion apps
    /// and host apps are looked up in.
    public static func inspect(_ app: AppBundle, installed: [AppBundle], sources: InsightSources = InsightSources(),
                               now: Date = Date(), unusedAfterDays: Int = defaultUnusedDays) -> AppInsight {
        let context = InsightContext(sources: sources, installed: installed)
        return evaluate(context.signals(for: app), now: now, unusedAfterDays: unusedAfterDays)
    }

    /// Inspects every app, sharing the work that does not depend on the app. Runs the apps
    /// in parallel; results keep the order of `apps`.
    public static func inspectAll(_ apps: [AppBundle], installed: [AppBundle]? = nil, sources: InsightSources = InsightSources(),
                                  now: Date = Date(), unusedAfterDays: Int = defaultUnusedDays) -> [AppInsight] {
        let context = InsightContext(sources: sources, installed: installed ?? apps)
        let results = ResultSlots(count: apps.count)
        DispatchQueue.concurrentPerform(iterations: apps.count) { index in
            let insight = evaluate(context.signals(for: apps[index]), now: now, unusedAfterDays: unusedAfterDays)
            results.set(index, insight)
        }
        return results.values()
    }
}

private final class ResultSlots: @unchecked Sendable {
    private var slots: [AppInsight?]
    private let lock = NSLock()

    init(count: Int) { slots = Array(repeating: nil, count: count) }

    func set(_ index: Int, _ value: AppInsight) {
        lock.lock(); slots[index] = value; lock.unlock()
    }

    func values() -> [AppInsight] {
        lock.lock(); defer { lock.unlock() }
        return slots.compactMap { $0 }
    }
}
