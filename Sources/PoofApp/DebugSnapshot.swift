#if DEBUG
import AppKit
import PoofCore

/// Development aid: POOF_SNAPSHOT=/path/prefix renders the window to PNG files without
/// needing Screen Recording permission. Not compiled into release builds.
///
/// - POOF_SELECT: "apps", "leftovers" (or "orphans"), "developer", "login", "extensions",
///   "quarantine", or part of an app's name to open its detail.
/// - POOF_DARK=1: dark appearance.
/// - POOF_SIZE=1100x700: window content size in points.
/// - POOF_WAIT: seconds to wait after selecting (default 8).
/// - POOF_DEMO=1 (see DemoData): fictional apps instead of this Mac's.
@MainActor
enum DebugSnapshot {
    static func runIfRequested(model: AppModel) {
        let env = ProcessInfo.processInfo.environment
        guard let prefix = env["POOF_SNAPSHOT"] else { return }
        let appearance = NSAppearance(named: env["POOF_DARK"] == nil ? .aqua : .darkAqua)
        NSApp.appearance = appearance
        // An active window draws prominent buttons and selections in colour, as people see them.
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in
            if let size = env["POOF_SIZE"].flatMap(parseSize), let window = NSApp.windows.first(where: \.isVisible) {
                window.setContentSize(size)
            }
            try? await Task.sleep(for: .seconds(env["POOF_DEMO"] == "1" ? 1 : 4))
            if let target = env["POOF_SELECT"]?.lowercased() {
                switch target {
                case "orphans", "leftovers": model.selection = .orphans
                case "quarantine": model.selection = .quarantine
                case "developer": model.selection = .developer
                case "apps": model.selection = .appsOverview
                case "login", "loginitems": model.selection = .loginItems
                case "extensions": model.selection = .extensions
                default:
                    if let app = model.apps.first(where: { $0.displayName.lowercased().contains(target) }) {
                        model.selection = .app(app.url.path)
                    }
                }
            }
            try? await Task.sleep(for: .seconds(Double(env["POOF_WAIT"] ?? "") ?? 8))
            guard let window = NSApp.windows.first(where: \.isVisible) else { exit(2) }
            let ok = write(window, to: URL(fileURLWithPath: prefix + ".png"))
            exit(ok ? 0 : 2)
        }
    }

    private static func parseSize(_ text: String) -> NSSize? {
        let parts = text.lowercased().split(separator: "x").compactMap { Double($0) }
        return parts.count == 2 ? NSSize(width: parts[0], height: parts[1]) : nil
    }

    /// Draws the window's content over the window background. `cacheDisplay` leaves vibrant
    /// materials (the sidebar) transparent, which made dark text unreadable on a white PNG;
    /// compositing over the appearance's window colour fixes it. The title bar is not drawn:
    /// capturing the frame view instead draws scrolled content outside its clip.
    private static func write(_ window: NSWindow, to url: URL) -> Bool {
        guard let view = window.contentView else { return false }
        guard let layer = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: layer)

        guard let output = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: layer.pixelsWide, pixelsHigh: layer.pixelsHigh,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return false }
        // Draw in pixels; the point size is set afterwards so the PNG carries the 2x scale.
        guard let context = NSGraphicsContext(bitmapImageRep: output) else { return false }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let rect = NSRect(x: 0, y: 0, width: layer.pixelsWide, height: layer.pixelsHigh)
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            // Matches the sidebar's material closely enough for a screenshot.
            NSColor.windowBackgroundColor.setFill()
            rect.fill()
        }
        layer.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        output.size = layer.size
        guard let png = output.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url)) != nil
    }
}
#endif
