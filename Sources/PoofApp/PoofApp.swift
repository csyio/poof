import AppKit
import PoofCore
import SwiftUI

@main
struct PoofApp: App {
    @State private var model = AppModel()

    init() {
        // Needed when launched as a bare SwiftPM binary; a no-op inside Poof.app.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        Window("Poof", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 860, minHeight: 540)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var isDropTargeted = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.selection) {
                Section {
                    SidebarLabel(title: "Apps", style: .apps)
                        .tag(SidebarItem.appsOverview)
                    SidebarLabel(title: "Leftovers", style: .leftovers)
                        .tag(SidebarItem.orphans)
                    SidebarLabel(title: "Developer", style: .developer)
                        .tag(SidebarItem.developer)
                    SidebarLabel(title: "Login Items", style: .loginItems)
                        .tag(SidebarItem.loginItems)
                    SidebarLabel(title: "Extensions", style: .extensions)
                        .tag(SidebarItem.extensions)
                    SidebarLabel(title: "Quarantine", style: .quarantine)
                        .badge(model.sessions.count)
                        .tag(SidebarItem.quarantine)
                }
                Section("Applications") {
                    if model.isLoadingApps && model.apps.isEmpty {
                        ProgressView().controlSize(.small)
                    }
                    ForEach(filteredApps, id: \.url.path) { app in
                        AppRow(app: app).tag(SidebarItem.app(app.url.path))
                    }
                }
            }
            .searchable(text: $search, placement: .sidebar, prompt: "Search apps")
            .navigationSplitViewColumnWidth(min: 220, ideal: 250)
        } detail: {
            VStack(spacing: 0) {
                if !model.hasFullDiskAccess {
                    FullDiskAccessBanner()
                        .padding([.horizontal, .top], Space.m)
                }
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .tint(Brand.accent)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Brand.gradient, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { $0.pathExtension == "app" }) else { return false }
            model.open(url)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .task {
            model.refreshSessions()
            await model.loadApps()
            #if DEBUG
            DebugSnapshot.runIfRequested(model: model)
            #endif
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshAccess()
        }
    }

    private var filteredApps: [AppBundle] {
        guard !search.isEmpty else { return model.apps }
        return model.apps.filter { $0.displayName.localizedCaseInsensitiveContains(search) }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.selection {
        case .appsOverview:
            AppsOverviewView()
        case .orphans, nil:
            OrphansView()
        case .developer:
            DeveloperView()
        case .loginItems:
            LoginItemsView()
        case .extensions:
            ExtensionsView()
        case .quarantine:
            QuarantineView()
        case .app(let path):
            if let app = model.app(at: path) {
                AppDetailView(app: app).id(path)
            } else {
                EmptyState(symbol: "questionmark.app.dashed", title: "App not found",
                           caption: "It may have been moved or removed since the list was loaded.")
            }
        }
    }
}

/// A sidebar section with its System Settings style icon.
struct SidebarLabel: View {
    let title: String
    let style: SectionStyle

    var body: some View {
        Label {
            Text(title)
        } icon: {
            IconTile(symbol: style.symbol, tint: style.tint, size: 20)
        }
    }
}

struct AppRow: View {
    let app: AppBundle

    var body: some View {
        Label {
            Text(app.displayName).lineLimit(1)
        } icon: {
            FileIcon(path: app.url.path, size: 20)
        }
    }
}

struct FullDiskAccessBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Banner(symbol: "lock.shield.fill", tone: .caution,
               title: "Poof needs Full Disk Access to see every file",
               message: "Without it, macOS hides other apps' sandboxed data and Poof cannot measure or move it.") {
            VStack(alignment: .trailing, spacing: Space.xs) {
                Button("Open System Settings") { FullDiskAccess.openSettings() }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                Button("Check Again") { model.refreshAccess() }
                    .buttonStyle(.borderless)
                    .font(.callout)
            }
        }
    }
}
