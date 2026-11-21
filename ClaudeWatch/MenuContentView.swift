import AppKit
import SwiftUI

struct MenuContentView: View {
    @Bindable var store: UsageStore
    @State private var showingSettings = false
    @State private var expanded: Set<String>

    init(store: UsageStore, expanded: Set<String> = []) {
        self.store = store
        _expanded = State(initialValue: expanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showingSettings {
                SettingsView(store: store, done: { showingSettings = false })
            } else {
                usage
            }
        }
        .padding(14)
        .frame(width: 380)
        .onAppear { store.refresh() }
    }

    // MARK: - Usage page

    private var usage: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Claude usage").font(.headline)
                Spacer()
                Picker("Period", selection: $store.period) {
                    ForEach(Period.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 210)
            }

            if !store.hasScanned {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading transcripts…").foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            } else {
                PlanUsageView(usage: store.planUsage)
                SummaryView(totals: store.report.overall)

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if !store.pinned.isEmpty {
                            MenuSection(title: "Pinned sessions") {
                                ForEach(store.report.pinned) { row in
                                    DisclosureRow(row: row, level: 0, expanded: $expanded, showModels: true,
                                                  sessionAction: unpinAction)
                                }
                            }
                        }
                        GroupSection(row: store.report.desktop, expanded: $expanded,
                                     note: "Plan usage counts toward your plan limits. ≈ $ is its value at API list prices.",
                                     sessionAction: pinAction)
                        GroupSection(row: store.report.otherCLI, expanded: $expanded, note: nil,
                                     sessionAction: pinAction)
                    }
                }
                .frame(maxHeight: 420)
                .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack {
                if let updated = store.lastUpdated {
                    Text("Updated \(updated, format: .relative(presentation: .named))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh") { store.refresh() }
                Button("Settings…") { showingSettings = true }
                Button("Quit") { NSApp.terminate(nil) }
            }
            .controlSize(.small)
        }
    }

    private var pinAction: SessionAction {
        SessionAction(title: "Pin Session") { row in store.pin(sessionID: row.id, label: row.title) }
    }

    private var unpinAction: SessionAction {
        SessionAction(title: "Unpin") { row in
            if let id = UUID(uuidString: row.id) { store.unpin(id) }
        }
    }
}

/// The context-menu command on a session row.
struct SessionAction {
    let title: String
    let run: (UsageRow) -> Void
}

extension Totals {
    /// The main figure for a row: AWS cost when there is any, otherwise the tokens on your plan.
    var headline: String {
        if cloudCost > 0 { return Format.money(cloudCost) }
        if planTokens > 0 { return Format.tokens(planTokens) + " tok" }
        return requests == 0 ? "–" : Format.tokens(tokens) + " tok"
    }

    /// The line under `headline`.
    var headlineDetail: String {
        if cloudCost > 0 { return planTokens > 0 ? "AWS + \(Format.tokens(planTokens)) plan tok" : "AWS" }
        if planValue > 0 { return "≈ " + Format.money(planValue) }
        return ""
    }
}

// MARK: - Pieces

private struct SummaryView: View {
    let totals: Totals

    var body: some View {
        HStack(spacing: 18) {
            Metric(title: "AWS", value: Format.money(totals.cloudCost),
                   help: "Billed by AWS (Bedrock) at list price, \(Format.tokens(totals.cloudTokens)) tokens.")
            Metric(title: "Plan tokens", value: Format.tokens(totals.planTokens),
                   help: "Input, output and cache tokens of Claude Code sessions on your plan.")
            Metric(title: "Plan value", value: Format.money(totals.planValue),
                   help: "Plan usage valued at Anthropic API list prices. You don't pay this.")
            Spacer()
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .help(totals.sideRequestCost >= 0.01
              ? "Includes \(Format.money(totals.sideRequestCost)) of side requests (auto-mode classifier, summaries, titles) from Claude Code's own cost tally."
              : "")
    }
}

private struct Metric: View {
    let title: String
    let value: String
    let help: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
        }
        .help(help)
    }
}

private struct PlanUsageView: View {
    let usage: PlanUsage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Plan limits").font(.subheadline.weight(.semibold))
                Spacer()
                if let usage {
                    Text(asOf(usage))
                        .font(.caption2)
                        .foregroundStyle(usage.isStale() ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .help("Claude Desktop records your plan usage about every 15 minutes while it runs.")
                }
            }
            if let usage {
                ForEach(usage.limits) { limit in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(limit.label).font(.callout)
                            Spacer()
                            Text("\(Int(limit.utilization.rounded()))% used").monospacedDigit()
                        }
                        ProgressView(value: min(limit.utilization, 100), total: 100)
                            .tint(limit.utilization >= 90 ? .red : limit.utilization >= 70 ? .orange : .accentColor)
                    }
                }
            } else {
                Text("Claude Desktop records your 5-hour and weekly plan usage while it runs. Open Claude Desktop to see it here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private func asOf(_ usage: PlanUsage) -> String {
        let when = usage.asOf.formatted(.relative(presentation: .named))
        return usage.isStale() ? "Claude Desktop not running · as of \(when)" : "Claude Desktop · \(when)"
    }
}

private struct MenuSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
    }
}

/// Claude Desktop or "other sessions": a header with totals, then projects that open into sessions.
private struct GroupSection: View {
    let row: UsageRow
    @Binding var expanded: Set<String>
    let note: String?
    let sessionAction: SessionAction?

    var body: some View {
        if row.totals.requests > 0 {
            MenuSection(title: row.title) {
                HStack {
                    Text(costBreakdown).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .help(note ?? "")
                ForEach(row.children) { project in
                    DisclosureRow(row: project, level: 0, expanded: $expanded, showModels: false,
                                  sessionAction: sessionAction)
                }
            }
        }
    }

    private var costBreakdown: String {
        var parts: [String] = []
        if row.totals.cloudCost > 0 {
            parts.append("AWS \(Format.money(row.totals.cloudCost)) for \(Format.tokens(row.totals.cloudTokens)) tokens")
        }
        if row.totals.planTokens > 0 {
            parts.append("plan \(Format.tokens(row.totals.planTokens)) tokens ≈ \(Format.money(row.totals.planValue))")
        }
        return parts.joined(separator: " · ")
    }
}

private struct DisclosureRow: View {
    let row: UsageRow
    let level: Int
    @Binding var expanded: Set<String>
    let showModels: Bool
    var sessionAction: SessionAction?

    private var canExpand: Bool { !row.children.isEmpty || (showModels && !row.models.isEmpty) }
    private var isExpanded: Bool { expanded.contains(row.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Button {
                guard canExpand else { return }
                if isExpanded { expanded.remove(row.id) } else { expanded.insert(row.id) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .opacity(canExpand ? 0.6 : 0)
                        .frame(width: 10)
                    if let live = row.live {
                        Circle()
                            .fill(live.status == "busy" ? Color.green : Color.green.opacity(0.45))
                            .frame(width: 7, height: 7)
                            .help("Running (\(live.status ?? "live"), pid \(live.pid))")
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        Text(row.title).lineLimit(1).truncationMode(.middle)
                        if let detail {
                            Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(row.totals.headline)
                            .monospacedDigit()
                            .foregroundStyle(row.totals.requests == 0 ? .secondary : .primary)
                        Text(row.totals.headlineDetail).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, CGFloat(level) * 14)
            .help(row.subtitle ?? "")
            .contextMenu {
                if let sessionAction, row.children.isEmpty {
                    Button(sessionAction.title) { sessionAction.run(row) }
                }
            }

            if isExpanded {
                if showModels {
                    ForEach(row.models.sorted { $0.value.tokens > $1.value.tokens }, id: \.key) { model, totals in
                        HStack {
                            Text(model).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text(totals.headline + (totals.cloudCost > 0 ? "" : "  " + totals.headlineDetail))
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .padding(.leading, CGFloat(level + 1) * 14 + 16)
                    }
                    if row.totals.sideRequestCost >= 0.01 {
                        HStack {
                            Text("incl. side requests").font(.caption).foregroundStyle(.tertiary)
                            Spacer()
                            Text(Format.money(row.totals.sideRequestCost))
                                .font(.caption).monospacedDigit().foregroundStyle(.tertiary)
                        }
                        .padding(.leading, CGFloat(level + 1) * 14 + 16)
                        .help("Classifier, summary and title requests Claude Code counts but doesn't list in the transcript.")
                    }
                }
                ForEach(row.children) { child in
                    DisclosureRow(row: child, level: level + 1, expanded: $expanded, showModels: true,
                                  sessionAction: sessionAction)
                }
            }
        }
    }

    private var detail: String? {
        var parts: [String] = []
        if let subtitle = row.subtitle, level == 0, row.children.isEmpty == false || row.live != nil {
            parts.append(subtitle)
        }
        if let last = row.totals.lastActivity {
            parts.append(last.formatted(.relative(presentation: .named)))
        } else if row.totals.requests == 0 {
            parts.append("no usage in this period")
        }
        if row.totals.unpricedRequests > 0 { parts.append("\(row.totals.unpricedRequests) unpriced") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
