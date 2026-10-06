import Foundation
import Testing
@testable import PoofCore

final class StoppedServices: @unchecked Sendable {
    var plists: [String] = []
}

struct RemovalTests {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("poof-\(UUID())")
    var quarantine: Quarantine { Quarantine(root: base.appendingPathComponent("Quarantine")) }

    func makeFile(_ relative: String, contents: String = "x") throws -> URL {
        let url = base.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }

    func leftover(_ url: URL, _ reason: Leftover.Reason = .bundleID, sharedWith: [String] = []) -> Leftover {
        Leftover(url: url, reason: reason, size: 1, sharedWith: sharedWith)
    }

    @Test func plansToKeepSharedItemsAndSystemExtensions() throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let own = try makeFile("Library/Caches/com.example.app/data")
        let shared = try makeFile("Library/Group Containers/TEAM.shared/x")
        let remover = Remover(quarantine: quarantine, isRoot: false, stopService: { _ in })
        let plan = remover.plan([
            leftover(own.deletingLastPathComponent()),
            leftover(shared, .packageFile, sharedWith: ["com.example.other"]),
            leftover(URL(fileURLWithPath: "/Library/SystemExtensions/X/a.dext"), .systemExtension),
        ])
        #expect(plan.map(\.action) == [
            .move,
            .skip("also used by com.example.other"),
            .skip("system extensions are protected by macOS; remove it in System Settings > General > Login Items & Extensions"),
        ])
    }

    @Test func flagsPersonalData() throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let profile = try makeFile("Browser/Default/Login Data")
        _ = try makeFile("Browser/Default/Bookmarks")
        _ = try makeFile("Browser/Default/History")
        let found = SensitiveData.find(in: profile.deletingLastPathComponent().deletingLastPathComponent()).sorted()
        #expect(found == ["Default/Bookmarks", "Default/Login Data"])
    }

    @Test func movesToQuarantineAndRestores() throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let cache = try makeFile("Library/Caches/com.example.app/data", contents: "cache")
        let agent = try makeFile("Library/LaunchAgents/com.example.app.plist")
        let stopped = StoppedServices()
        let remover = Remover(quarantine: quarantine, isRoot: false, stopService: { stopped.plists.append($0.lastPathComponent) })

        let plan = remover.plan([leftover(cache.deletingLastPathComponent()), leftover(agent, .launchItem)])
        let (session, outcomes) = try remover.execute(plan, appName: "Example", bundleID: "com.example.app")

        #expect(outcomes.allSatisfy { if case .moved = $0.1 { true } else { false } })
        #expect(stopped.plists == ["com.example.app.plist"])
        #expect(!FileManager.default.fileExists(atPath: cache.path))
        #expect(!FileManager.default.fileExists(atPath: agent.path))
        #expect(quarantine.sessions().map(\.id) == [session.id])

        let results = try quarantine.restore(session.id)
        #expect(results.allSatisfy { $0.1 == nil })
        #expect(try String(contentsOf: cache, encoding: .utf8) == "cache")
        #expect(FileManager.default.fileExists(atPath: agent.path))
        #expect(quarantine.sessions().isEmpty)
    }

    @Test func restoreKeepsItemsWhoseOriginalPathIsTaken() throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let prefs = try makeFile("Library/Preferences/com.example.app.plist", contents: "old")
        var session = try quarantine.begin(appName: "Example", bundleID: nil)
        try quarantine.move(prefs, size: 3, into: &session)
        _ = try makeFile("Library/Preferences/com.example.app.plist", contents: "reinstalled")

        let results = try quarantine.restore(session.id)
        #expect(results.first?.1 != nil)
        #expect(try String(contentsOf: prefs, encoding: .utf8) == "reinstalled")
        #expect(quarantine.sessions().first?.entries.count == 1)
    }

    @Test func purgeDeletesTheSession() throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let file = try makeFile("Library/Caches/x")
        var session = try quarantine.begin(appName: "Example", bundleID: nil)
        try quarantine.move(file, size: 1, into: &session)
        try quarantine.purge(session.id)
        #expect(quarantine.sessions().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: quarantine.root.appendingPathComponent(session.id).path))
    }
}
