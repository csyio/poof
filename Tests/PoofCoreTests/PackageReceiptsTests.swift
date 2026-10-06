import Foundation
import Testing
@testable import PoofCore

struct FakePackages: PackageDatabase {
    var receipts: [String: [String]]
    var locations: [String: String] = [:]
    func packageIDs() -> [String] { receipts.keys.sorted() }
    func files(of packageID: String) -> [String] { receipts[packageID] ?? [] }
    func installLocation(of packageID: String) -> String { locations[packageID] ?? "" }
}

struct PackageReceiptsTests {
    let oneDrive = AppBundle(
        url: URL(fileURLWithPath: "/Applications/OneDrive.app"),
        name: "OneDrive", bundleID: "com.microsoft.OneDrive", teamID: "UBF8T346G9"
    )

    @Test func matchesPackageByIDAndIgnoresOtherVendorPackages() {
        let db = FakePackages(receipts: [
            "com.microsoft.OneDrive": ["OneDrive.app", "OneDrive.app/Contents/Info.plist"],
            "com.microsoft.pkg.licensing": ["Library/PrivilegedHelperTools/com.microsoft.office.licensingV2.helper"],
            "com.fortinet.forticlient": ["Applications/FortiClient.app"],
        ])
        #expect(db.packages(for: oneDrive).map(\.packageID) == ["com.microsoft.OneDrive"])
    }

    @Test func matchesRelocatedPackageByAppName() {
        // Receipts record the temporary unpack location, not /Applications.
        let db = FakePackages(receipts: ["com.microsoft.package.sync": ["OneDrive.app", "Library/LaunchDaemons/x.plist"]])
        let match = db.packages(for: oneDrive)
        #expect(match.first?.ownedPaths.map(\.path) == ["Library/LaunchDaemons/x.plist"])
        #expect(match.first?.otherApps == [])
    }

    @Test func flagsPackagesThatInstallOtherApps() {
        let db = FakePackages(receipts: ["com.microsoft.suite": ["OneDrive.app", "Microsoft Word.app", "Library/Fonts/a.ttf"]])
        #expect(db.packages(for: oneDrive).first?.otherApps == ["Microsoft Word.app"])
    }

    func owned(_ files: [String], location: String = "Library", others: [String: [String]] = [:]) -> [PackageMatch.OwnedPath] {
        var index: [String: Set<String>] = [:]
        for (id, paths) in others {
            for path in paths { for a in FakePackages.ancestors(of: path) { index[a, default: []].insert(id) } }
        }
        return FakePackages.ownedPaths(FakePackages.absolutePaths(files: files, location: location), others: index)
    }

    @Test func collapsesFilesToTheFolderThePackageOwns() {
        let files = [
            "Application Support", "Application Support/Fortinet", "Application Support/Fortinet/FortiClient",
            "Application Support/Fortinet/FortiClient/bin/fctd", "LaunchDaemons",
            "LaunchDaemons/com.fortinet.forticlient.vpn.plist", "FortiClient.app/Contents/Info.plist",
        ]
        #expect(owned(files).map(\.path) == [
            "Library/Application Support/Fortinet",
            "Library/LaunchDaemons/com.fortinet.forticlient.vpn.plist",
        ])
    }

    @Test func ignoresTemporaryInstallLocations() {
        #expect(owned(["Frameworks/ADAL4.framework"], location: "private/tmp/com.microsoft.package.Frameworks").isEmpty)
    }

    @Test func descendsIntoSharedVendorFolders() {
        let files = [
            "Application Support/Blackmagic Design", "Application Support/Blackmagic Design/DaVinci Resolve/a",
            "Application Support/Blackmagic Design/Shared.dylib",
        ]
        let others = ["com.blackmagic-design.raw": [
            "Library/Application Support/Blackmagic Design/Blackmagic RAW/b",
            "Library/Application Support/Blackmagic Design/Shared.dylib",
        ]]
        #expect(owned(files, others: others) == [
            .init(path: "Library/Application Support/Blackmagic Design/DaVinci Resolve", sharedWith: []),
            .init(path: "Library/Application Support/Blackmagic Design/Shared.dylib", sharedWith: ["com.blackmagic-design.raw"]),
        ])
    }

    @Test func helperAppsInsideOwnedFolderAreNotOtherApps() {
        let resolve = AppBundle(
            url: URL(fileURLWithPath: "/Applications/DaVinci Resolve/DaVinci Resolve.app"),
            name: "DaVinci Resolve", bundleID: "com.blackmagic-design.DaVinciResolve", teamID: nil
        )
        let db = FakePackages(
            receipts: ["com.blackmagic-design.resolve": [
                "DaVinci Resolve/DaVinci Resolve.app/Contents/Info.plist",
                "DaVinci Resolve/Uninstall Resolve.app/Contents/Info.plist",
                "DaVinci Resolve/Documents/manual.pdf",
                "Blackmagic RAW Player.app/Contents/Info.plist",
            ]],
            locations: ["com.blackmagic-design.resolve": "Applications"]
        )
        #expect(db.packages(for: resolve).first?.otherApps == ["Blackmagic RAW Player.app"])
    }
}
