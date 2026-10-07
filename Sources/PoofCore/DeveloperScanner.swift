import Foundation

/// Caches and build output left by developer tools. Read-only.
///
/// Items fall into four groups:
/// - caches the tool rebuilds or downloads again when needed,
/// - build output of projects that no longer exist (Xcode records each DerivedData
///   folder's project path, so this is certain),
/// - data worth a look first (archives, toolchains, build folders of idle projects),
/// - data a tool manages itself, which should be cleaned with its own command; moving
///   simulator folders by hand, say, leaves simctl pointing at devices that are gone.
public struct DeveloperScanner: Sendable {
    let home: URL

    public init(home: URL = UserContext.home) {
        self.home = home
    }

    struct Location {
        let path: String  // relative to home
        let title: String
        let reason: Leftover.Reason
        var command: String? = nil
    }

    static let locations: [Location] = [
        .init(path: "Library/Caches/org.swift.swiftpm", title: "SwiftPM package cache", reason: .devCache),
        .init(path: "Library/Caches/com.apple.dt.Xcode", title: "Xcode cache", reason: .devCache),
        .init(path: "Library/Developer/CoreSimulator/Caches", title: "Simulator caches", reason: .devCache),
        .init(path: "Library/Caches/ms-playwright", title: "Playwright browsers", reason: .devCache),
        .init(path: ".cache/ms-playwright", title: "Playwright browsers", reason: .devCache),
        .init(path: ".cache/puppeteer", title: "Puppeteer browsers (Chrome for Testing)", reason: .devCache),
        .init(path: ".npm/_cacache", title: "npm cache", reason: .devCache),
        .init(path: "Library/Caches/Yarn", title: "Yarn cache", reason: .devCache),
        .init(path: "Library/pnpm/store", title: "pnpm store", reason: .devCache),
        .init(path: ".bun/install/cache", title: "Bun cache", reason: .devCache),
        .init(path: "Library/Caches/node-gyp", title: "node-gyp headers", reason: .devCache),
        .init(path: ".cache/node-gyp", title: "node-gyp headers", reason: .devCache),
        .init(path: "Library/Caches/typescript", title: "TypeScript cache", reason: .devCache),
        .init(path: "Library/Caches/electron", title: "Electron downloads", reason: .devCache),
        .init(path: "Library/Caches/electron-builder", title: "electron-builder downloads", reason: .devCache),
        .init(path: "Library/Caches/CocoaPods", title: "CocoaPods cache", reason: .devCache),
        .init(path: "Library/Caches/pip", title: "pip cache", reason: .devCache),
        .init(path: ".cache/uv", title: "uv cache", reason: .devCache),
        .init(path: ".cargo/registry", title: "Cargo registry", reason: .devCache),
        .init(path: ".gradle/caches", title: "Gradle cache", reason: .devCache),
        .init(path: "Library/Caches/deno", title: "Deno cache", reason: .devCache),
        .init(path: "Library/Developer/Xcode/iOS DeviceSupport", title: "iOS device symbols", reason: .devCache),
        .init(path: "Library/Developer/Xcode/watchOS DeviceSupport", title: "watchOS device symbols", reason: .devCache),
        .init(path: "Library/Developer/Xcode/macOS DeviceSupport", title: "macOS device symbols", reason: .devCache),
        .init(path: "Library/Developer/Xcode/Archives", title: "Xcode archives (builds sent to App Store or testers)", reason: .devReview),
        .init(path: ".rustup/toolchains", title: "Rust toolchains", reason: .devReview, command: "rustup toolchain list, then rustup toolchain uninstall <name>"),
        .init(path: ".m2/repository", title: "Maven repository", reason: .devReview),
        .init(path: ".android/avd", title: "Android emulators", reason: .devReview),
        .init(path: "Library/Developer/CoreSimulator/Devices", title: "iOS simulators", reason: .devReview,
              command: "xcrun simctl delete unavailable (removes simulators for missing runtimes), xcrun simctl erase all (resets every simulator)"),
        .init(path: "Library/Caches/Homebrew", title: "Homebrew downloads", reason: .devCache, command: "brew cleanup --prune=all"),
        .init(path: "go/pkg/mod", title: "Go module cache", reason: .devCache, command: "go clean -modcache"),
    ]

    public func scan(projects: URL? = nil, idleDays: Int = 30) -> [Leftover] {
        var items: [Leftover] = []
        for location in Self.locations {
            let url = home.appendingPathComponent(location.path)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let size = LeftoverScanner.size(of: url)
            guard size > 0 else { continue }
            items.append(Leftover(url: url, reason: location.reason, size: size,
                                  detail: location.title, cleanupCommand: location.command))
        }
        items += derivedData()
        if let projects {
            items += idleBuildFolders(in: projects, idleDays: idleDays)
        }
        return items.sorted { $0.size > $1.size }
    }

    /// One item per DerivedData folder. Xcode writes the project path into each folder's
    /// info.plist; when that path is gone, the build output is certainly unused.
    func derivedData() -> [Leftover] {
        let root = home.appendingPathComponent("Library/Developer/Xcode/DerivedData")
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { folder in
            let size = LeftoverScanner.size(of: folder)
            guard size > 0 else { return nil }
            let info = NSDictionary(contentsOf: folder.appendingPathComponent("info.plist"))
            guard let workspace = info?["WorkspacePath"] as? String else {
                return Leftover(url: folder, reason: .devCache, size: size, detail: "Xcode build cache")
            }
            let project = (workspace as NSString).lastPathComponent
            if FileManager.default.fileExists(atPath: workspace) {
                // Safe to remove, but the project's next build starts from scratch.
                return Leftover(url: folder, reason: .devReview, size: size,
                                detail: "Xcode build output for \(project); its next build starts from scratch")
            }
            return Leftover(url: folder, reason: .devOrphanedBuild, size: size,
                            detail: "Xcode build output for \(project), which no longer exists at \(workspace)")
        }
    }

    /// Dependency and build folders that a project's own tools recreate, each paired with a
    /// file that proves the folder belongs to that tool ("target" alone could be anything).
    static let buildFolders: [(name: String, marker: String)] = [
        ("node_modules", "package.json"),
        (".build", "Package.swift"),
        ("target", "Cargo.toml"),
        (".next", "package.json"),
        ("Pods", "Podfile"),
        (".venv", ""),
        ("venv", "pyvenv.cfg"),
    ]

    /// Build folders of projects nobody has touched for `idleDays`.
    func idleBuildFolders(in root: URL, idleDays: Int) -> [Leftover] {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-Double(idleDays) * 86_400)
        var found: [Leftover] = []
        var queue: [(URL, Int)] = [(root, 0)]
        while let (dir, depth) = queue.popLast() {
            let entries = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            let names = Set(entries.map(\.lastPathComponent))
            for entry in entries {
                guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
                let name = entry.lastPathComponent
                if let rule = Self.buildFolders.first(where: { $0.name == name }) {
                    let markerPresent = rule.marker.isEmpty
                        || names.contains(rule.marker)
                        || fm.fileExists(atPath: entry.appendingPathComponent(rule.marker).path)
                    if markerPresent, let edited = Self.lastEdit(of: dir, ignoring: name), edited < cutoff {
                        let days = Int(Date().timeIntervalSince(edited) / 86_400)
                        found.append(Leftover(url: entry, reason: .devReview, size: LeftoverScanner.size(of: entry),
                                              detail: "\(dir.lastPathComponent) has not changed in \(days) days"))
                    }
                    continue  // never look inside a build folder
                }
                if depth < 4, !name.hasPrefix("."), entry.pathExtension.isEmpty {
                    queue.append((entry, depth + 1))
                }
            }
        }
        return found
    }

    /// Newest modification among a project's top-level entries, leaving out the build folder
    /// itself (installing packages would otherwise make the project look recently edited).
    static func lastEdit(of project: URL, ignoring buildFolder: String) -> Date? {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: project, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return entries
            .filter { $0.lastPathComponent != buildFolder && !buildFolders.map(\.name).contains($0.lastPathComponent) }
            .compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
            .max()
    }
}
