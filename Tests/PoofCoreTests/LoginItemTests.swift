import Foundation
import Testing
@testable import PoofCore

struct LoginItemTests {
    let dump = """
    ========================
     Records for UID -2 : FFFFEEEE-DDDD-CCCC-BBBB-AAAAFFFFFFFE
    ========================

     Items:

     #1:
                     UUID: 70CDC31B-CFB0-42E6-8D75-8CE5907837D3
                     Name: com.example.helper
           Developer Name: Example, Inc
          Team Identifier: ABCDE12345
                     Type: legacy daemon (0x10010)
              Disposition: [enabled, allowed, notified] (0xb)
               Identifier: 16.com.example.helper
                      URL: /Library/LaunchDaemons/com.example.helper.plist
          Executable Path: /Library/Application Support/Example/helper
        Parent Identifier: Example, Inc

    ========================
     Records for UID 501 : 2FAAC1EA-EC68-4806-9118-AF451009FF2F
    ========================

     #1:
                     UUID: 1
                     Name: Example
           Developer Name: Example, Inc
                     Type: app (0x2)
              Disposition: [disabled, allowed, not notified] (0x2)
               Identifier: 2.com.example.app
                      URL: /Applications/Example.app
        Bundle Identifier: com.example.app

     #2:
                     UUID: 2
                     Name: Example Helper
                     Type: login item (0x4)
              Disposition: [enabled, allowed, notified] (0xb)
               Identifier: 4.com.example.app.LoginHelper
                      URL: Contents/Library/LoginItems/Example Helper.app
        Bundle Identifier: com.example.app.LoginHelper
        Parent Identifier: 2.com.example.app

     #3:
                     UUID: 3
                     Name: Updater
                     Type: legacy agent (0x10008)
              Disposition: [enabled, allowed, notified] (0xb)
               Identifier: 8.com.vendor.updater
                      URL: /Users/501/Library/LaunchAgents/com.vendor.updater.plist
          Executable Path: /Users/Shared/Vendor/updater
        Assoc. Bundle IDs: [com.example.app, com.vendor.other]
          Embedded Item Identifiers:
            #1: 16.com.vendor.daemon

    ========================
     Records for UID 502 : 00000000-0000-0000-0000-000000000000
    ========================

     #1:
                     UUID: 4
                     Name: Someone Else
                     Type: app (0x2)
              Disposition: [enabled, allowed, notified] (0xb)
               Identifier: 2.com.other.app
                      URL: /Applications/Other.app
    """

    @Test func parsesRecordsOfTheUserAndTheSystem() {
        let items = LoginItem.parse(dump: dump, uid: 501)
        #expect(items.map(\.name) == ["com.example.helper", "Example", "Example Helper", "Updater"])
        #expect(items[0].type == "legacy daemon")
        #expect(items[0].enabled)
        #expect(!items[1].enabled)
        #expect(items[3].associatedBundleIDs == ["com.example.app", "com.vendor.other"])
    }

    @Test func resolvesRelativeAndUIDBasedPaths() throws {
        let items = LoginItem.parse(dump: dump, uid: 501)
        #expect(items[2].path == "/Applications/Example.app/Contents/Library/LoginItems/Example Helper.app")
        let home = try #require(getpwuid(501)).pointee.pw_dir.map { String(cString: $0) }
        #expect(items[3].path == "\(home ?? "")/Library/LaunchAgents/com.vendor.updater.plist")
    }

    @Test func matchesItemsToTheirApp() {
        let items = LoginItem.parse(dump: dump, uid: 501)
        let mine = items.filter { $0.belongs(to: ["com.example.app"], appPath: "/Applications/Example.app") }
        #expect(mine.map(\.name) == ["Example", "Example Helper", "Updater"])
    }

    @Test func loginItemsAreNeverMoved() {
        let item = Leftover(url: URL(fileURLWithPath: "/Applications/Example.app"), reason: .loginItem, size: 0)
        let plan = Remover(canWriteSystem: true, stopService: { _ in }).plan([item])
        if case .skip = plan.first?.action {} else { Issue.record("login item was planned to move") }
    }
}
