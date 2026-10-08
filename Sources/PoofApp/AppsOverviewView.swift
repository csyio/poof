import AppKit
import PoofCore
import SwiftUI

/// One table row with sort keys for every column.
struct InsightRow: Identifiable {
    let insight: AppInsight

    var id: String { insight.id }
    var name: String { insight.name }
    var vendor: String { insight.vendor ?? "" }
    var origin: String { insight.origin.label }
    /// Days since last use; running apps first, apps with no record by days since added.
    var idle: Int { insight.signals.isRunning ? -1 : insight.idleDays ?? Int.max }
    var size: Int64 { insight.signals.size ?? 0 }
    var verdict: String { insight.verdict.word }
}

/// Every installed app with where it came from, when it was last used and Poof's verdict.
struct AppsOverviewView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: String?

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            SectionHeader(style: .apps, stats: stats) {
                TextField("Filter", text: $model.appsFilter, prompt: Text("Filter apps"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 130)
                Button {
                    // Reload the list too: apps added or removed since the last look count.
                    Task { await model.loadApps() }
                } label: {
                    Label("Check Again", systemImage: "arrow.clockwise")
                }
                .disabled(model.isLoadingInsights || model.isLoadingApps)
            }

            if model.insights.isEmpty {
                if model.isLoadingInsights || model.isLoadingApps {
                    LoadingState(text: "Looking at \(model.apps.count) apps…")
                } else {
                    EmptyState(symbol: "app.dashed", title: "No apps found",
                               caption: "Poof looks in /Applications, ~/Applications and the folders inside them.")
                }
            } else {
                Table(rows, selection: $selection, sortOrder: $model.appsSort) {
                    TableColumn("Name", value: \.name) { row in
                        HStack(spacing: Space.s) {
                            FileIcon(path: row.insight.signals.path, size: 18)
                            Text(row.name).lineLimit(1)
                        }
                    }
                    .width(min: 100, ideal: 120)
                    TableColumn("Developer", value: \.vendor) { row in
                        Text(row.insight.vendor ?? "—").lineLimit(1)
                            .foregroundStyle(row.insight.vendor == nil ? .tertiary : .secondary)
                    }
                    .width(min: 70, ideal: 88)
                    TableColumn("Origin", value: \.origin) { row in
                        Text(row.origin).lineLimit(1).foregroundStyle(.secondary)
                    }
                    .width(min: 60, ideal: 70)
                    TableColumn("Last Used", value: \.idle) { row in
                        Text(row.insight.lastUsedText)
                            .lineLimit(1)
                            .fontWeight(row.insight.verdict.isRemovalCandidate ? .semibold : .regular)
                            .foregroundStyle(row.insight.verdict.isRemovalCandidate ? AnyShapeStyle(Tone.positive.color) : AnyShapeStyle(.secondary))
                    }
                    .width(min: 62, ideal: 76)
                    TableColumn("Size", value: \.size) { row in
                        Text(row.insight.signals.size.map(formatSize) ?? "—")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(min: 52, ideal: 62)
                    TableColumn("Verdict", value: \.verdict) { row in
                        VerdictBadge(verdict: row.insight.verdict)
                    }
                    .width(min: 76, ideal: 86)
                }
                .onChange(of: selection) { _, path in
                    if let path { model.selection = .app(path) }
                }
                HStack(spacing: Space.s) {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                    Text("Unused means not opened in \(AppInsight.defaultUnusedDays) days or more. Select an app to see why it is here.")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    if model.isLoadingInsights { ProgressView().controlSize(.small) }
                }
                .font(.callout)
                .padding(.horizontal, Space.xl)
                .padding(.vertical, Space.s + 2)
                .background(.bar)
                .overlay(alignment: .top) { Divider() }
            }
        }
    }

    private var stats: [Stat] {
        let all = Array(model.insights.values)
        let ready = !all.isEmpty
        let unused = all.filter(\.verdict.isRemovalCandidate)
        let background = all.filter { if case .runsInBackground = $0.verdict { true } else { false } }
        let unusedSize = unused.reduce(Int64(0)) { $0 + ($1.signals.size ?? 0) }
        return [
            Stat(label: "Apps", value: ready ? "\(all.count)" : "—", symbol: "square.grid.2x2.fill", tint: .blue),
            Stat(label: "Unused", value: ready ? "\(unused.count)" : "—", symbol: "moon.zzz.fill", tint: .green),
            Stat(label: "Unused size", value: ready ? tileSize(unusedSize) : "—", symbol: "externaldrive.fill", tint: .purple),
            Stat(label: "Background", value: ready ? "\(background.count)" : "—", symbol: "gearshape.2.fill", tint: .orange),
        ]
    }

    private var rows: [InsightRow] {
        let filter = model.appsFilter.trimmingCharacters(in: .whitespaces)
        let all = model.insights.values.map(InsightRow.init)
        let shown = filter.isEmpty ? all : all.filter {
            $0.name.localizedCaseInsensitiveContains(filter) || $0.vendor.localizedCaseInsensitiveContains(filter)
                || $0.insight.signals.bundleID.localizedCaseInsensitiveContains(filter)
        }
        return shown.sorted(using: model.appsSort)
    }
}

/// "About this app": the verdict, the recommendation and the findings behind them.
struct AppInsightPanel: View {
    @Environment(AppModel.self) private var model
    let app: AppBundle
    @State private var expanded = AppInsightPanel.expandedByDefault

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(spacing: Space.s) {
                Text("About this app").font(.headline)
                Spacer()
                if let insight {
                    VerdictBadge(verdict: insight.verdict, large: true)
                }
            }
            if let insight {
                Text(insight.recommendation)
                    .font(.body)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                DisclosureGroup(isExpanded: $expanded) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(insight.findings.enumerated()), id: \.offset) { index, finding in
                            if index > 0 { Divider().padding(.leading, 34) }
                            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                                Image(systemName: index == 0 ? insight.origin.symbol : "circle.fill")
                                    .font(.system(size: index == 0 ? 12 : 5))
                                    .foregroundStyle(index == 0 ? AnyShapeStyle(insight.verdict.tone.solid) : AnyShapeStyle(.tertiary))
                                    .frame(width: 18)
                                Text(finding)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, Space.s)
                            .padding(.vertical, 7)
                        }
                    }
                    .font(.callout)
                    .textSelection(.enabled)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: Radius.small + 2, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Radius.small + 2, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                    }
                    .padding(.top, Space.s)
                } label: {
                    Text("What Poof found (\(insight.findings.count))")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            } else if !model.isInstalled(app) {
                Text("\(app.displayName) is no longer installed.").foregroundStyle(.secondary)
            } else {
                HStack(spacing: Space.s) {
                    ProgressView().controlSize(.small)
                    Text("Looking into where it came from…").foregroundStyle(.secondary)
                }
            }
        }
        .card(padding: Space.l)
        // Runs again when the cached insight goes away (a reload that dropped it), so the
        // panel never waits on an insight nobody is gathering.
        .task(id: "\(app.url.path)\n\(insight == nil)") {
            if insight == nil, model.isInstalled(app) { _ = await model.insight(for: app) }
        }
    }

    private var insight: AppInsight? { model.insights[app.url.path] }

    /// Collapsed in normal use; the DEBUG demo opens it for screenshots.
    static var expandedByDefault: Bool {
        #if DEBUG
        DemoData.isEnabled
        #else
        false
        #endif
    }
}
