import Foundation

/// Safari extensions are `.appex` bundles inside ordinary apps (`Contents/PlugIns`). Whether
/// each one is switched on lives in Safari's own container, which Poof does not read, so the
/// state is unknown. Removing the app removes its extensions.
extension BrowserExtensionScanner {
    func scanSafari() -> [BrowserInstall] {
        let fm = FileManager.default
        var found: [BrowserExtension] = []
        for app in apps {
            let plugIns = app.url.appendingPathComponent("Contents/PlugIns")
            let appName = app.url.deletingPathExtension().lastPathComponent
            for appex in ((try? fm.contentsOfDirectory(at: plugIns, includingPropertiesForKeys: nil)) ?? [])
            where appex.pathExtension == "appex" {
                let info = Self.plist(at: appex.appendingPathComponent("Contents/Info.plist"))
                    ?? Self.plist(at: appex.appendingPathComponent("Info.plist"))
                guard let info,
                      let point = (info["NSExtension"] as? [String: Any])?["NSExtensionPointIdentifier"] as? String,
                      point.hasPrefix("com.apple.Safari") else { continue }
                found.append(BrowserExtension(
                    name: (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String)
                        ?? appex.deletingPathExtension().lastPathComponent,
                    version: (info["CFBundleShortVersionString"] as? String) ?? (info["CFBundleVersion"] as? String) ?? "",
                    extensionID: (info["CFBundleIdentifier"] as? String) ?? appex.lastPathComponent,
                    kind: Self.safariKind(point),
                    state: .unknown,
                    source: .app,
                    path: appex.path,
                    size: LeftoverScanner.size(of: appex),
                    providedBy: appName))
            }
        }
        guard !found.isEmpty else { return [] }

        let safari = ["/Applications/Safari.app", "/System/Cryptexes/App/System/Applications/Safari.app"]
            .first { fm.fileExists(atPath: $0) }
        let profile = BrowserProfile(name: "Extensions from installed apps", directory: "", path: "",
                                     extensions: Self.sorted(found))
        return [BrowserInstall(
            name: "Safari", family: .safari, isInstalled: true, appPath: safari, dataPath: nil, profiles: [profile],
            note: "Each extension comes with an app; removing the app removes the extension. "
                + "Turn them on or off in Safari > Settings > Extensions.")]
    }

    static func safariKind(_ point: String) -> String {
        switch point {
        case "com.apple.Safari.web-extension": "Safari web extension"
        case "com.apple.Safari.extension": "Safari app extension"
        case "com.apple.Safari.content-blocker": "Safari content blocker"
        default: "Safari extension"
        }
    }
}
