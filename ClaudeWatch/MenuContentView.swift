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
        .padding(Self.inset)
        .frame(width: 380)
        .onAppear { store.refresh() }
    }

    static let inset: CGFloat = 14

    // MARK: - Usage page

    private var usage: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Claude usage").font(.headline)
                Spacer()
                PeriodPicker(selection: $store.period)
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
                    // Inset the rows, not the scroll view, so the scroller sits at the popover's edge
                    // instead of on top of the numbers.
                    .padding(.horizontal, Self.inset)
                }
                .padding(.horizontal, -Self.inset)
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

/// A segmented control with equal, fixed-width segments. The native segmented picker is wider than
/// the space here and resizes its segments when the selection changes, so the buttons shifted.
private struct PeriodPicker: View {
    @Binding var selection: Period

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Period.allCases) { period in
                let selected = period == selection
                Button {
                    selection = period
                } label: {
                    Text(period.title)
                        .font(.callout)
                        .lineLimit(1)
                        .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                        .frame(width: 52, height: 22)
                        .background(selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
        .fixedSize()
    }
}

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

struct PlanUsageView: View {
    let usage: PlanUsage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Plan limits").font(.subheadline.weight(.semibold))
                Spacer()
                if let usage {
                    // Re-evaluated every 30 s, so the age and the stale colour don't freeze.
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(Self.source(usage, now: context.date))
                            .font(.caption2)
                            .foregroundStyle(usage.isStale(now: context.date) ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    }
                }
            }
            if let usage {
                ForEach(usage.limits) { limit in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(limit.label).font(.callout)
                            if let reset = limit.resetsAt {
                                Text("resets \(limit.resetIsExact ? "" : "about ")\(Self.time(reset))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(limit.isEstimated ? "≈ " : "")\(Int(limit.utilization.rounded()))% used").monospacedDigit()
                        }
                        LimitBar(limit: limit)
                        if let detail = Self.detail(limit) {
                            Text(detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Text(Self.footnote(usage))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Claude Desktop records your 5-hour and weekly plan usage while it runs. Open Claude Desktop, or add ClaudeWatch's status line to Claude Code, to see it here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    /// "Claude Code · 13:26" or "Claude Desktop · 13:26", whichever reported last, or
    /// "no new reading since Mon 13:26" for an old one. Desktop doesn't save a reading every
    /// 15 minutes all the time, even while it runs, so an old one doesn't mean it isn't running.
    static func source(_ usage: PlanUsage, now: Date = .now) -> String {
        let time = time(usage.updated, now: now)
        if usage.isStale(now: now) { return "no new reading since \(time)" }
        return usage.isLive ? "Claude Code · \(time)" : "Claude Desktop · \(time)"
    }

    /// The real reading behind an estimate, e.g. "Claude Desktop: 0% at Sat 22:52 · ≈ +70% from Claude
    /// Code since". Nil when the number shown is the reading itself.
    static func detail(_ limit: PlanLimit, now: Date = .now) -> String? {
        guard let reading = limit.reading else { return nil }
        let measured = limit.utilization - limit.estimatedPart
        let resetSince = reading.utilization > measured + 0.5
        guard limit.isEstimated || resetSince else { return nil }
        let source = reading.source == .desktop ? "Claude Desktop" : "Claude Code"
        var text = "\(source): \(Int(reading.utilization.rounded()))% at \(time(reading.date, now: now))"
        if resetSince { text += ", before the reset" }
        if limit.estimatedPart >= 0.5 {
            text += " · ≈ +\(Int(limit.estimatedPart.rounded()))% from Claude Code since"
        }
        return text
    }

    /// "13:26" today, "Mon 13:26" on another day.
    static func time(_ date: Date, now: Date = .now) -> String {
        Calendar.current.isDate(date, inSameDayAs: now)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    static func footnote(_ usage: PlanUsage) -> String {
        let estimated = usage.limits.contains(where: \.isEstimated)
        switch (usage.isLive, estimated) {
        case (true, false):
            return "Claude Code gets these with every response. They count all your use, Desktop and Cowork included."
        case (true, true):
            return "Claude Code gets these with every response, Desktop and Cowork included. ≈ adds your Claude Code use since its last one."
        case (false, true):
            return "≈ adds your Claude Code use on this Mac. Chats, Cowork and other devices only count from Desktop's next reading, so it can run low. ClaudeWatch's Claude Code status line gives exact numbers."
        case (false, false):
            return "Claude Desktop saves these every 15 minutes, so they can trail its own Usage view. ClaudeWatch's Claude Code status line gives exact numbers."
        }
    }
}

/// A plan limit's bar: the measured part solid, the part estimated since the last reading lighter.
private struct LimitBar: View {
    let limit: PlanLimit

    var body: some View {
        let total = min(max(limit.utilization, 0), 100) / 100
        let measured = min(max(limit.utilization - limit.estimatedPart, 0), 100) / 100
        let tint: Color = limit.utilization >= 90 ? .red : limit.utilization >= 70 ? .orange : .accentColor
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(tint.opacity(0.4)).frame(width: geometry.size.width * total)
                Capsule().fill(tint).frame(width: geometry.size.width * measured)
            }
        }
        .frame(height: 5)
        .accessibilityElement()
        .accessibilityLabel("\(Int(limit.utilization.rounded()))% used")
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
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(row.title.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(Format.money(row.totals.cost)).font(.callout.weight(.semibold)).monospacedDigit()
                    Text("·").foregroundStyle(.secondary)
                    Text("\(Format.tokens(row.totals.tokens)) tokens").font(.callout.weight(.semibold)).monospacedDigit()
                }
                .help("Everything in this section: AWS cost plus the plan usage valued at API list prices.")
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
