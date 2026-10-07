import Foundation
import Testing
@testable import PoofCore

struct DeveloperScannerTests {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("dev-\(UUID())")

    func write(_ relative: String, _ contents: String = "x") throws -> URL {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }

    func derivedData(_ name: String, workspace: String?) throws {
        let folder = "Library/Developer/Xcode/DerivedData/\(name)"
        _ = try write("\(folder)/Build/x")
        if let workspace {
            try (["WorkspacePath": workspace] as NSDictionary)
                .write(to: home.appendingPathComponent("\(folder)/info.plist"))
        }
    }

    @Test func classifiesDerivedDataByWhetherTheProjectStillExists() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let project = try write("Code/Live/Live.xcodeproj/project.pbxproj")
        try derivedData("Live-abc", workspace: project.deletingLastPathComponent().path)
        try derivedData("Gone-def", workspace: home.appendingPathComponent("Code/Gone/Gone.xcodeproj").path)
        try derivedData("ModuleCache.noindex", workspace: nil)

        let items = Dictionary(uniqueKeysWithValues: DeveloperScanner(home: home).derivedData()
            .map { ($0.url.lastPathComponent, $0.reason) })
        #expect(items == ["Live-abc": .devReview, "Gone-def": .devOrphanedBuild, "ModuleCache.noindex": .devCache])
    }

    @Test func findsBuildFoldersOnlyInIdleProjectsWithTheirMarkerFile() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let old = Date().addingTimeInterval(-90 * 86_400)
        for project in ["idle", "active", "unmarked"] {
            _ = try write("Projects/\(project)/node_modules/pkg/index.js")
            _ = try write("Projects/\(project)/src/main.js")
        }
        _ = try write("Projects/idle/package.json")
        _ = try write("Projects/active/package.json")
        for entry in ["package.json", "src"] {
            try FileManager.default.setAttributes([.modificationDate: old],
                                                  ofItemAtPath: home.appendingPathComponent("Projects/idle/\(entry)").path)
        }
        try FileManager.default.setAttributes([.modificationDate: old],
                                              ofItemAtPath: home.appendingPathComponent("Projects/unmarked/src").path)

        let found = DeveloperScanner(home: home).idleBuildFolders(in: home.appendingPathComponent("Projects"), idleDays: 30)
        #expect(found.map { $0.url.deletingLastPathComponent().lastPathComponent } == ["idle"])
        #expect(found.first?.reason == .devReview)
    }

    @Test func toolManagedDataIsNeverMoved() {
        let simulators = Leftover(url: URL(fileURLWithPath: "/tmp/Devices"), reason: .devReview, size: 1,
                                  cleanupCommand: "xcrun simctl delete unavailable")
        let plan = Remover(canWriteSystem: true, stopService: { _ in }).plan([simulators])
        #expect(plan.first?.action == .skip("managed by its tool; clean it with: xcrun simctl delete unavailable"))
    }
}
