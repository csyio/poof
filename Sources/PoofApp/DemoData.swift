#if DEBUG
import AppKit
import PoofCore
import SwiftUI
import UniformTypeIdentifiers

/// POOF_DEMO=1 fills the Apps section and app details with fictional apps for screenshots.
/// Nothing is read from this Mac's apps; insights come from `AppInsight.evaluate` on made-up
/// signals. DEBUG builds only.
@MainActor
enum DemoData {
    static let isEnabled = ProcessInfo.processInfo.environment["POOF_DEMO"] == "1"

    struct Icon {
        let symbol: String
        let colors: [Color]
    }

    private struct DemoApp {
        let name: String
        let bundleID: String
        let icon: Icon
        let configure: (inout AppSignals) -> Void

        var path: String { "/Applications/\(name).app" }
    }

    private static func ago(_ days: Int) -> Date { Date().addingTimeInterval(-Double(days) * 86_400 - 3_600) }
    private static let mb: Int64 = 1_000_000

    private static let catalog: [DemoApp] = [
        DemoApp(name: "Kestrel Photo", bundleID: "com.kestrelsoft.photo",
                icon: Icon(symbol: "camera.aperture", colors: [.pink, .purple])) { s in
            s.signer = .developerID("Kestrel Software Ltd")
            s.version = "4.2.1"
            s.origin.quarantine = QuarantineInfo(agent: "Safari", date: ago(410))
            s.lastUsed = ago(214)
            s.dateAdded = ago(410)
            s.size = 1_240 * mb
            s.category = "Photography"
        },
        DemoApp(name: "Lumen Notes", bundleID: "com.lumenlabs.notes",
                icon: Icon(symbol: "note.text", colors: [.yellow, .orange])) { s in
            s.signer = .developerID("Lumen Labs Inc")
            s.version = "2.8"
            s.origin.quarantine = QuarantineInfo(agent: "Safari", date: ago(300))
            s.lastUsed = ago(0)
            s.isRunning = true
            s.dateAdded = ago(300)
            s.size = 182 * mb
        },
        DemoApp(name: "Orbit VPN", bundleID: "net.orbitnetworks.vpn",
                icon: Icon(symbol: "globe.europe.africa.fill", colors: [.teal, .blue])) { s in
            s.signer = .developerID("Orbit Networks AB")
            s.version = "7.1.0"
            s.origin.packageIDs = ["net.orbitnetworks.vpn.pkg"]
            s.lastUsed = ago(31)
            s.dateAdded = ago(500)
            s.size = 96 * mb
            s.background = [BackgroundItem(kind: .systemExtension, identifier: "net.orbitnetworks.vpn.tunnel",
                                           detail: "network extension")]
        },
        DemoApp(name: "Tidewave Mail", bundleID: "com.tidewave.mail",
                icon: Icon(symbol: "envelope.fill", colors: [.cyan, .blue])) { s in
            s.signer = .appStore
            s.copyright = "Copyright © 2021-2026 Tidewave Software. All rights reserved."
            s.version = "3.4"
            s.origin.hasAppStoreReceipt = true
            s.lastUsed = ago(143)
            s.dateAdded = ago(620)
            s.size = 64 * mb
        },
        DemoApp(name: "Cobalt Terminal", bundleID: "dev.cobalt.terminal",
                icon: Icon(symbol: "terminal.fill", colors: [.indigo, .black])) { s in
            s.signer = .developerID("Cobalt Dev")
            s.version = "1.9.3"
            s.origin.homebrewCask = "cobalt-terminal"
            s.lastUsed = ago(1)
            s.dateAdded = ago(90)
            s.size = 118 * mb
        },
        DemoApp(name: "Quill Writer", bundleID: "app.quill.writer",
                icon: Icon(symbol: "pencil.and.scribble", colors: [.orange, .red])) { s in
            s.signer = .appStore
            s.copyright = "© 2025 Quill Apps GmbH"
            s.version = "5.0"
            s.origin.hasAppStoreReceipt = true
            s.lastUsed = ago(12)
            s.dateAdded = ago(200)
            s.size = 41 * mb
        },
        DemoApp(name: "Beacon Sync", bundleID: "io.beaconsync.agent",
                icon: Icon(symbol: "arrow.triangle.2.circlepath", colors: [.green, .teal])) { s in
            s.signer = .developerID("Beacon Systems Inc")
            s.version = "12.0"
            s.origin.packageIDs = ["io.beaconsync.pkg"]
            s.lastUsed = ago(160)
            s.dateAdded = ago(700)
            s.size = 230 * mb
            s.background = [BackgroundItem(kind: .launchAgent, identifier: "io.beaconsync.agent")]
        },
        DemoApp(name: "Marble Paint", bundleID: "com.marblepaint.app",
                icon: Icon(symbol: "paintbrush.pointed.fill", colors: [.mint, .green])) { s in
            s.signer = .developerID("Marble Paint Studio")
            s.version = "3.0.2"
            s.origin.quarantine = QuarantineInfo(agent: "Firefox", date: ago(400))
            s.lastUsed = ago(97)
            s.dateAdded = ago(400)
            s.size = 512 * mb
        },
        DemoApp(name: "Nimbus Weather", bundleID: "com.nimbus.weather",
                icon: Icon(symbol: "cloud.sun.fill", colors: [.blue, .cyan])) { s in
            s.signer = .developerID("Nimbus Labs")
            s.version = "1.2"
            s.origin.packageIDs = ["com.nimbus.weather.pkg"]
            s.isBackgroundOnly = true
            s.dateAdded = ago(30)
            s.size = 22 * mb
        },
        DemoApp(name: "Atlas Maps", bundleID: "com.atlasmaps.desktop",
                icon: Icon(symbol: "map.fill", colors: [.green, .blue])) { s in
            s.signer = .developerID("Atlas Mapping Co")
            s.version = "9.3"
            s.origin.quarantine = QuarantineInfo(agent: "Safari", date: ago(150))
            s.lastUsed = ago(5)
            s.dateAdded = ago(150)
            s.size = 344 * mb
        },
        DemoApp(name: "Atlas Maps Helper", bundleID: "com.atlasmaps.helper",
                icon: Icon(symbol: "map", colors: [.gray, .blue])) { s in
            s.signer = .developerID("Atlas Mapping Co")
            s.version = "9.3"
            s.embeddedIn = ["Atlas Maps"]
            s.dateAdded = ago(150)
            s.size = 8 * mb
        },
        DemoApp(name: "Sparrow Clock", bundleID: "local.sparrow.clock",
                icon: Icon(symbol: "clock.fill", colors: [.gray, .secondary])) { s in
            s.signer = .adHoc
            s.version = "0.4"
            s.size = 3 * mb
        },
    ]

    static var apps: [AppBundle] {
        catalog.map { AppBundle(url: URL(fileURLWithPath: $0.path), name: $0.name, bundleID: $0.bundleID, teamID: nil) }
    }

    static func insights() -> [String: AppInsight] {
        Dictionary(uniqueKeysWithValues: catalog.map { app in
            var signals = AppSignals(name: app.name, bundleID: app.bundleID, path: app.path)
            app.configure(&signals)
            return (app.path, AppInsight.evaluate(signals))
        })
    }

    /// Made-up files for an app, shaped like a real scan.
    static func plan(for app: AppBundle) -> [Remover.PlannedItem] {
        let home = UserContext.home.path
        let id = app.bundleID
        func item(_ path: String, _ reason: Leftover.Reason, _ size: Int64,
                  action: Remover.Action = .move, sensitive: [String] = []) -> Remover.PlannedItem {
            Remover.PlannedItem(item: Leftover(url: URL(fileURLWithPath: path), reason: reason, size: size),
                                action: action, sensitiveFiles: sensitive)
        }
        return [
            item(app.url.path, .appBundle, insights()[app.url.path]?.signals.size ?? 100 * mb),
            item("\(home)/Library/Application Support/\(app.displayName)", .appName, 642 * mb,
                 sensitive: ["\(home)/Library/Application Support/\(app.displayName)/Web/Cookies"]),
            item("\(home)/Library/Caches/\(id)", .bundleID, 212 * mb),
            item("\(home)/Library/Preferences/\(id).plist", .bundleID, 12_000),
            item("\(home)/Library/Saved Application State/\(id).savedState", .bundleID, 48_000),
            item("/Library/LaunchDaemons/\(id).helper.plist", .launchItem, 4_000),
            item("\(home)/Library/Group Containers/K7T2.\(id).shared", .teamID, 18 * mb,
                 action: .skip("Shared with Kestrel RAW, which is still installed")),
        ]
    }

    static func icon(for path: String) -> DemoIcon.Kind? {
        guard isEnabled else { return nil }
        if let app = catalog.first(where: { $0.path == path }) { return .symbol(app.icon) }
        guard path.contains(".") || path.hasPrefix(UserContext.home.path) || path.hasPrefix("/Library") else { return nil }
        if FileManager.default.fileExists(atPath: path) { return nil }
        let type: UTType = path.hasSuffix(".plist") ? .propertyList : .folder
        return .image(NSWorkspace.shared.icon(for: type))
    }
}

/// A made-up app icon: a rounded square with a gradient and a symbol.
struct DemoIcon: View {
    enum Kind {
        case symbol(DemoData.Icon)
        case image(NSImage)
    }

    let spec: Kind
    let size: CGFloat

    var body: some View {
        switch spec {
        case .image(let image):
            Image(nsImage: image).resizable().frame(width: size, height: size)
        case .symbol(let icon):
            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .fill(LinearGradient(colors: icon.colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay {
                    Image(systemName: icon.symbol)
                        .font(.system(size: size * 0.48, weight: .medium))
                        .foregroundStyle(.white)
                }
                .padding(size * 0.08)
                .frame(width: size, height: size)
        }
    }
}
#endif
