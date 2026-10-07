#if DEBUG
import AppKit
import PoofCore

/// Development aid: POOF_SNAPSHOT=/path/prefix renders the window to PNG files without
/// needing Screen Recording permission. POOF_SELECT picks a sidebar item first
/// ("orphans", "quarantine" or an app name). Not compiled into release builds.
@MainActor
enum DebugSnapshot {
    static func runIfRequested(model: AppModel) {
        let env = ProcessInfo.processInfo.environment
        guard let prefix = env["POOF_SNAPSHOT"] else { return }
        // cacheDisplay skips the window's material background, which hides dark-mode text.
        NSApp.appearance = NSAppearance(named: env["POOF_DARK"] == nil ? .aqua : .darkAqua)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            if let target = env["POOF_SELECT"]?.lowercased() {
                switch target {
                case "orphans": model.selection = .orphans
                case "quarantine": model.selection = .quarantine
                case "developer": model.selection = .developer
                default:
                    if let app = model.apps.first(where: { $0.displayName.lowercased().contains(target) }) {
                        model.selection = .app(app.url.path)
                    }
                }
            }
            try? await Task.sleep(for: .seconds(Double(env["POOF_WAIT"] ?? "") ?? 8))
            guard let view = NSApp.windows.first(where: \.isVisible)?.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(2) }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: prefix + ".png"))
            exit(0)
        }
    }
}
#endif
