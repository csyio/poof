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
                    Label("Leftovers", systemImage: "sparkles")
                        .tag(SidebarItem.orphans)
                    Label("Developer", systemImage: "hammer")
                        .tag(SidebarItem.developer)
                    Label("Quarantine", systemImage: "archivebox")
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
                }
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
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
        case .orphans, nil:
            OrphansView()
        case .developer:
            DeveloperView()
        case .quarantine:
            QuarantineView()
        case .app(let path):
            if let app = model.app(at: path) {
                AppDetailView(app: app).id(path)
            } else {
                ContentUnavailableView("App not found", systemImage: "questionmark.app")
            }
        }
    }
}

struct AppRow: View {
    let app: AppBundle

    var body: some View {
        Label {
            Text(app.displayName).lineLimit(1)
        } icon: {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                .resizable()
                .frame(width: 18, height: 18)
        }
    }
}

struct FullDiskAccessBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Poof needs Full Disk Access to see every file")
                    .font(.headline)
                Text("Without it, macOS hides other apps' sandboxed data and Poof cannot measure or move it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open System Settings") { FullDiskAccess.openSettings() }
            Button("Check Again") { model.refreshAccess() }
        }
        .padding(12)
        .background(.orange.opacity(0.1))
        .overlay(alignment: .bottom) { Divider() }
    }
}
