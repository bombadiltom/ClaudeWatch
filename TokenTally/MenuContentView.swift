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
                SummaryView(totals: store.report.overall)

                if store.showPlanLimits {
                    PlanLimitsView(limits: store.planLimits, error: store.planError)
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if !store.pinned.isEmpty {
                            MenuSection(title: "Pinned sessions") {
                                ForEach(store.report.pinned) { row in
                                    DisclosureRow(row: row, level: 0, expanded: $expanded, showModels: true)
                                }
                            }
                        }
                        GroupSection(row: store.report.desktop, expanded: $expanded,
                                     note: "Plan usage is valued at API list prices.")
                        GroupSection(row: store.report.otherCLI, expanded: $expanded, note: nil)
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
                Button("Refresh") {
                    store.refresh()
                    if store.showPlanLimits { store.refreshPlanLimits() }
                }
                Button("Settings…") { showingSettings = true }
                Button("Quit") { NSApp.terminate(nil) }
            }
            .controlSize(.small)
        }
    }
}

// MARK: - Pieces

private struct SummaryView: View {
    let totals: Totals

    var body: some View {
        HStack(spacing: 18) {
            Metric(title: "AWS", value: Format.money(totals.cloudCost), help: "Billed by AWS (Bedrock) at list price.")
            Metric(title: "Plan value", value: Format.money(totals.planValue),
                   help: "Pro plan usage valued at Anthropic API list prices. You don't pay this.")
            Metric(title: "Tokens", value: Format.tokens(totals.tokens), help: "Input, output and cache tokens.")
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

private struct PlanLimitsView: View {
    let limits: [PlanLimit]
    let error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Pro plan limits").font(.subheadline.weight(.semibold))
            if let error {
                Text(error).font(.caption).foregroundStyle(.orange)
            } else if limits.isEmpty {
                Text("Loading…").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(limits) { limit in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(limit.label).font(.callout)
                        Spacer()
                        Text("\(Int(limit.utilization.rounded()))%").monospacedDigit()
                    }
                    ProgressView(value: min(limit.utilization, 100), total: 100)
                        .tint(limit.utilization >= 90 ? .red : limit.utilization >= 70 ? .orange : .accentColor)
                    if let reset = limit.resetsAt {
                        Text("Resets \(reset, format: .relative(presentation: .named))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
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

    var body: some View {
        if row.totals.requests > 0 {
            MenuSection(title: row.title) {
                HStack {
                    Text(costBreakdown).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .help(note ?? "")
                ForEach(row.children) { project in
                    DisclosureRow(row: project, level: 0, expanded: $expanded, showModels: false)
                }
            }
        }
    }

    private var costBreakdown: String {
        var parts: [String] = []
        if row.totals.cloudCost > 0 { parts.append("AWS \(Format.money(row.totals.cloudCost))") }
        if row.totals.planValue > 0 { parts.append("plan value \(Format.money(row.totals.planValue))") }
        parts.append("\(Format.tokens(row.totals.tokens)) tokens")
        return parts.joined(separator: " · ")
    }
}

private struct DisclosureRow: View {
    let row: UsageRow
    let level: Int
    @Binding var expanded: Set<String>
    let showModels: Bool

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
                        Text(Format.money(row.totals.cost))
                            .monospacedDigit()
                            .foregroundStyle(row.totals.requests == 0 ? .secondary : .primary)
                        Text(costKind).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, CGFloat(level) * 14)
            .help(row.subtitle ?? "")

            if isExpanded {
                if showModels {
                    ForEach(row.models.sorted { $0.value > $1.value }, id: \.key) { model, cost in
                        HStack {
                            Text(model).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text(Format.money(cost)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
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
                    DisclosureRow(row: child, level: level + 1, expanded: $expanded, showModels: true)
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

    private var costKind: String {
        switch (row.totals.cloudCost > 0, row.totals.planValue > 0) {
        case (true, true): "AWS + plan"
        case (true, false): "AWS"
        case (false, true): "plan value"
        default: Format.tokens(row.totals.tokens) + " tok"
        }
    }
}
