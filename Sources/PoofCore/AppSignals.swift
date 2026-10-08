import Foundation

/// How far macOS could verify a code signature: which Apple certificate requirement it meets.
/// Only a requirement that passes makes the certificate's name and team ID trustworthy; anyone
/// can make a self-signed certificate called "Software Signing".
public enum SignatureTrust: Sendable, Equatable {
    /// Signed by Apple itself (`anchor apple`).
    case apple
    /// Re-signed by the Mac App Store (leaf extension 1.2.840.113635.100.6.1.9).
    case appStore
    /// A Developer ID Application certificate (leaf extension 1.2.840.113635.100.6.1.13).
    case developerID
    /// Another certificate Apple issued (`anchor apple generic`): development or distribution.
    case appleIssued
    /// No certificate, a certificate Apple did not issue, or a signature that does not validate.
    case none
}

/// Who signed an app, read from the leaf certificate of its code signature.
public enum Signer: Sendable, Equatable {
    /// Signed by Apple as part of macOS ("Software Signing").
    case apple
    /// Re-signed by the App Store ("Apple Mac OS Application Signing"). The certificate does
    /// not name the developer.
    case appStore
    /// "Developer ID Application: Raycast Technologies Inc (SY64MV22J9)": a developer Apple identified.
    case developerID(String)
    /// "Apple Development: Jane Doe (ABCDE12345)": a build signed on a developer's own Mac.
    case development(String)
    /// "Apple Distribution: Example Inc (ABCDE12345)": a certificate for submitting to the App
    /// Store, not for handing out the app directly.
    case distribution(String)
    /// Signed without a certificate, so the signature names nobody.
    case adHoc
    case unsigned
    /// A certificate Apple issued that is none of the above.
    case other(String)
    /// The signature has a certificate, but it does not chain to Apple or does not validate,
    /// so the name in it proves nothing.
    case unverified(String?)

    /// Classifies a signature from its leaf certificate's common name and the Apple
    /// requirement it was verified against. The name only picks between kinds of Apple-issued
    /// certificates; it never makes a signature count as Apple's or a Developer ID.
    public init(leafCommonName: String?, isSigned: Bool, trust: SignatureTrust) {
        guard isSigned else { self = .unsigned; return }
        let name = leafCommonName?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        switch trust {
        case .apple:
            self = .apple
        case .appStore:
            self = .appStore
        case .developerID:
            let prefix = "Developer ID Application: "
            let rest = name.map { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : $0 }
            self = .developerID(rest.map(Self.stripTeam) ?? "an unnamed developer")
        case .appleIssued:
            guard let name else { self = .other("an Apple-issued certificate"); return }
            for prefix in ["Apple Development: ", "Mac Developer: "] where name.hasPrefix(prefix) {
                self = .development(Self.stripTeam(String(name.dropFirst(prefix.count))))
                return
            }
            for prefix in ["Apple Distribution: ", "3rd Party Mac Developer Application: "] where name.hasPrefix(prefix) {
                self = .distribution(Self.stripTeam(String(name.dropFirst(prefix.count))))
                return
            }
            self = .other(name)
        case .none:
            self = name.map { .unverified($0) } ?? .adHoc
        }
    }

    /// The developer's name when the certificate gives one.
    public var vendor: String? {
        switch self {
        case .apple: "Apple"
        case .developerID(let name), .development(let name), .distribution(let name): name
        case .appStore, .adHoc, .unsigned, .other, .unverified: nil
        }
    }

    /// "Raycast Technologies Inc (SY64MV22J9)" -> "Raycast Technologies Inc"
    static func stripTeam(_ name: String) -> String {
        guard name.hasSuffix(")"), let open = name.lastIndex(of: "(") else { return name }
        let team = name[name.index(after: open)..<name.index(before: name.endIndex)]
        guard !team.isEmpty, team.allSatisfy({ $0.isLetter || $0.isNumber }) else { return name }
        return name[..<open].trimmingCharacters(in: .whitespaces)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }

    /// The text made safe to print to a terminal. App names, versions, copyright lines and
    /// browser extension names come from files anyone can write, and an ESC in them would start
    /// a terminal escape sequence that can recolour, move or hide output. Tabs and line breaks
    /// become spaces; every other C0 and C1 control character, DEL and the bidirectional
    /// embeddings, overrides and isolates become U+FFFD.
    public var sanitizedForTerminal: String {
        guard unicodeScalars.contains(where: Self.isUnsafeForTerminal) else { return self }
        var result = String.UnicodeScalarView()
        for scalar in unicodeScalars {
            if ["\t", "\n", "\r"].contains(scalar) {
                result.append(" ")
            } else if Self.isUnsafeForTerminal(scalar) {
                result.append("\u{FFFD}")
            } else {
                result.append(scalar)
            }
        }
        return String(result)
    }

    static func isUnsafeForTerminal(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00...0x1F, 0x7F...0x9F: true
        case 0x202A...0x202E, 0x2066...0x2069: true  // bidirectional embeddings, overrides and isolates
        default: false
        }
    }
}

/// The `com.apple.quarantine` attribute macOS puts on downloaded files:
/// "01c1;6a855ae7;Edge;88BDA545-F7A6-411A-A3D3-72488DEC228C" (flags; hex time; agent; event).
public struct QuarantineInfo: Sendable, Equatable {
    /// The app that downloaded it ("Chrome", "Safari"), when recorded.
    public let agent: String?
    public let date: Date?

    public init(agent: String?, date: Date?) {
        self.agent = agent
        self.date = date
    }

    public init?(attribute value: String) {
        let parts = value.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3 else { return nil }
        let agent = parts[2].trimmingCharacters(in: .whitespaces)
        self.agent = agent.isEmpty ? nil : agent
        self.date = UInt64(parts[1], radix: 16).flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil }
    }
}

/// Everything that hints at how an app got onto the Mac.
public struct OriginEvidence: Sendable, Equatable {
    /// Inside /System (or a cryptex), where macOS keeps its own apps.
    public var isInSystemFolder = false
    public var hasAppStoreReceipt = false
    /// The Homebrew cask that installed it.
    public var homebrewCask: String?
    public var isInSetapp = false
    /// Installer packages whose receipts list the app.
    public var packageIDs: [String] = []
    public var quarantine: QuarantineInfo?

    public init(isInSystemFolder: Bool = false, hasAppStoreReceipt: Bool = false, homebrewCask: String? = nil,
                isInSetapp: Bool = false, packageIDs: [String] = [], quarantine: QuarantineInfo? = nil) {
        self.isInSystemFolder = isInSystemFolder
        self.hasAppStoreReceipt = hasAppStoreReceipt
        self.homebrewCask = homebrewCask
        self.isInSetapp = isInSetapp
        self.packageIDs = packageIDs
        self.quarantine = quarantine
    }
}

/// How an app was installed, judged from its `OriginEvidence`.
public enum AppOrigin: Sendable, Equatable {
    case macOS
    case appStore
    case homebrew(cask: String)
    case setapp
    case installer(packageID: String)
    case downloaded(agent: String?, date: Date?)
    case unknown

    /// The strongest evidence wins: a Homebrew app also carries a quarantine flag, and an
    /// App Store app may also have a package receipt. A receipt file alone is not enough for
    /// the App Store, since anyone can create one: the App Store must have signed the app too.
    public init(_ evidence: OriginEvidence, signer: Signer) {
        if evidence.isInSystemFolder || signer == .apple {
            self = .macOS
        } else if evidence.hasAppStoreReceipt && signer == .appStore {
            self = .appStore
        } else if let cask = evidence.homebrewCask {
            self = .homebrew(cask: cask)
        } else if evidence.isInSetapp {
            self = .setapp
        } else if let package = evidence.packageIDs.first {
            self = .installer(packageID: package)
        } else if let quarantine = evidence.quarantine {
            self = .downloaded(agent: quarantine.agent, date: quarantine.date)
        } else {
            self = .unknown
        }
    }

    /// One or two words for a table column.
    public var label: String {
        switch self {
        case .macOS: "macOS"
        case .appStore: "App Store"
        case .homebrew: "Homebrew"
        case .setapp: "Setapp"
        case .installer: "Installer"
        case .downloaded: "Downloaded"
        case .unknown: "Unknown"
        }
    }
}

/// Something that runs without the app being open.
public struct BackgroundItem: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case launchAgent = "launch agent"
        case launchDaemon = "launch daemon"
        case privilegedHelper = "privileged helper"
        case systemExtension = "system extension"
        case kernelExtension = "kernel extension"
        /// An app extension inside the bundle that macOS runs on its own, such as a VPN's
        /// packet tunnel. `detail` says which ("network extension").
        case appExtension = "app extension"
        /// A helper app in `Contents/Library/LoginItems` that the app can start at login.
        case loginItem = "login item"
    }

    public let kind: Kind
    /// Launch label, helper label or extension bundle ID.
    public let identifier: String
    /// A system or app extension's type: "network extension", "driver extension", "endpoint security extension".
    public let detail: String?
    public let path: String?
    /// Whether macOS has it switched on: a launch job loaded in launchd, a login item
    /// registered, a network extension configured. Nil when Poof could not tell, or for items
    /// that are on by being installed (a plist in a LaunchAgents folder, an activated system
    /// extension).
    public let isActive: Bool?

    public init(kind: Kind, identifier: String, detail: String? = nil, path: String? = nil, isActive: Bool? = nil) {
        self.kind = kind
        self.identifier = identifier
        self.detail = detail
        self.path = path
        self.isActive = isActive
    }

    /// Whether it runs, or can run, without the app: switched on, or of unknown state but
    /// installed outside the app's bundle. Items shipped inside the bundle (agents the app
    /// can register, login item helpers, network extensions) only count once switched on.
    func runs(forAppAt appPath: String) -> Bool {
        if let isActive { return isActive }
        guard let path else { return true }
        return !path.hasPrefix(appPath + "/")
    }

    /// Updaters run in the background too, but say nothing about what the app is for.
    public var isUpdater: Bool {
        let id = identifier.lowercased()
        return ![.systemExtension, .kernelExtension, .appExtension].contains(kind)
            && (id.contains("update") || id.contains("keystone"))
    }

    /// What to call it in a sentence: an extension by its type, anything else by its kind.
    var noun: String {
        kind == .systemExtension || kind == .appExtension ? (detail ?? kind.rawValue) : kind.rawValue
    }

    /// What this kind of item usually supports.
    var hint: Hint? {
        switch kind {
        case .kernelExtension: return .device
        case .systemExtension, .appExtension:
            let detail = (detail ?? "").lowercased()
            if detail.contains("driver") { return .device }
            if detail.contains("network") { return .network }
            if detail.contains("endpoint") { return .security }
            return nil
        default: return nil
        }
    }

    enum Hint: Int, Comparable {
        case device, network, security
        static func < (a: Hint, b: Hint) -> Bool { a.rawValue < b.rawValue }
    }
}

/// What the installer package that installed an app also put on the Mac.
public struct PackageRelations: Sendable, Equatable {
    /// Other apps the same package installed.
    public var otherApps: [String] = []
    /// Folders and files the package created outside app bundles, e.g. "/Library/Application Support/Fortinet".
    public var otherFiles: [String] = []
    /// Other packages from the same vendor that are installed.
    public var relatedPackages: [String] = []

    public init(otherApps: [String] = [], otherFiles: [String] = [], relatedPackages: [String] = []) {
        self.otherApps = otherApps
        self.otherFiles = otherFiles
        self.relatedPackages = relatedPackages
    }
}

/// The raw facts Poof gathers about one app. Every field is best effort: nil or empty
/// means unknown. `AppInsight.evaluate` turns these into findings without touching the disk.
public struct AppSignals: Sendable, Equatable {
    public var name: String
    public var bundleID: String
    public var path: String
    public var version: String?
    public var signer: Signer = .unsigned
    public var teamID: String?
    /// Humanised `LSApplicationCategoryType` ("Developer Tools").
    public var category: String?
    public var copyright: String?
    public var origin = OriginEvidence()
    public var lastUsed: Date?
    public var dateAdded: Date?
    public var size: Int64?
    public var isRunning = false
    /// Bundle IDs whose process running means the app is running (`AppBundle.runningIdentifiers`),
    /// so a live check can reuse them without walking the bundle again. Not part of the JSON.
    public var runningIdentifiers: [String] = []
    /// No Dock icon (`LSUIElement` or `LSBackgroundOnly`): a menu bar app or a helper that
    /// other apps or links start, so macOS may not record when it is used.
    public var isBackgroundOnly = false
    /// Other installed apps with the same team ID.
    public var companions: [String] = []
    public var background: [BackgroundItem] = []
    /// Installed apps that ship this app's bundle ID inside their own bundle.
    public var embeddedIn: [String] = []
    public var package = PackageRelations()

    public init(name: String, bundleID: String, path: String) {
        self.name = name
        self.bundleID = bundleID
        self.path = path
    }

    /// The developer's name: from the certificate, or for App Store apps (whose certificate
    /// is Apple's) from the copyright line.
    public var vendor: String? {
        if signer == .appStore { return copyright.flatMap(Self.vendor(fromCopyright:)) }
        return signer.vendor
    }

    /// "Copyright © 2014-2026 Telegram FZ-LLC. All rights reserved." -> "Telegram FZ-LLC"
    static func vendor(fromCopyright text: String) -> String? {
        let lowered = text.lowercased()
        guard ["©", "copyright", "(c)"].contains(where: lowered.contains) else { return nil }
        var rest = text.components(separatedBy: CharacterSet.newlines).first ?? text
        for phrase in ["All rights reserved", "All Rights Reserved", "Copyright", "copyright", "©", "(c)", "(C)"] {
            rest = rest.replacingOccurrences(of: phrase, with: " ")
        }
        // Drop years and year ranges ("2014-2026", "2024,").
        let words = rest.split(separator: " ").filter { word in
            !word.allSatisfy { $0.isNumber || "-–,.".contains($0) }
        }
        let name = words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " .,;"))
        return name.count >= 2 && name.count <= 60 ? name : nil
    }

    /// "public.app-category.developer-tools" -> "Developer Tools"
    public static func humanize(category: String) -> String? {
        let raw = category.split(separator: ".").last.map(String.init) ?? category
        let words = raw.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }
        return words.isEmpty ? nil : words.joined(separator: " ")
    }
}
