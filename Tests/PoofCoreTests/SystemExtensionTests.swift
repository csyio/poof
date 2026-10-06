import Foundation
import Testing
@testable import PoofCore

struct SystemExtensionTests {
    let fortiClient = AppBundle(
        url: URL(fileURLWithPath: "/Applications/FortiClient.app"),
        name: "FortiClient", bundleID: "com.fortinet.FortiClient", teamID: "AH4XFXJ7DK"
    )

    func load(_ extensions: [[String: Any]]) throws -> [SystemExtension] {
        let db = FileManager.default.temporaryDirectory.appendingPathComponent("db-\(UUID()).plist")
        defer { try? FileManager.default.removeItem(at: db) }
        try (["extensions": extensions] as NSDictionary).write(to: db)
        return SystemExtension.load(from: db)
    }

    @Test func readsTheExtensionDatabase() throws {
        let ext = try load([[
            "identifier": "com.fortinet.forticlient.macos.vpn.nwextension",
            "teamID": "AH4XFXJ7DK",
            "categories": ["com.apple.system_extension.network_extension"],
            "state": "activated_enabled",
            "stagedBundleURL": ["relative": "file:///Library/SystemExtensions/85B7/vpn.systemextension/"],
            "originPath": "/Applications/FortiClient.app/Contents/Resources/FortiTray.app/Contents/Library/SystemExtensions/vpn.systemextension",
            "references": [["appIdentifier": "com.fortinet.forticlient.macos.vpn", "teamID": "AH4XFXJ7DK"]],
        ]]).first
        #expect(ext?.stagedPath == "/Library/SystemExtensions/85B7/vpn.systemextension")
        #expect(ext?.kind == "network extension")
        // Matched through the nested app it was activated from, though its IDs differ from the app's.
        #expect(ext?.belongs(to: fortiClient) == true)
    }

    @Test func matchesByAppIdentifierWhenOriginMoved() throws {
        let ext = try load([[
            "identifier": "com.logi.ghub.hidfilter",
            "originPath": "/Volumes/Installer/lghub.app/Contents/Library/SystemExtensions/x.dext",
            "references": [["appIdentifier": "com.logi.ghub"]],
        ]]).first
        let ghub = AppBundle(url: URL(fileURLWithPath: "/Applications/lghub.app"), name: "lghub", bundleID: "com.logi.ghub", teamID: nil)
        #expect(ext?.belongs(to: ghub) == true)
        #expect(ext?.belongs(to: fortiClient) == false)
    }
}
