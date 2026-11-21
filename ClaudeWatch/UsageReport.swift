import Foundation

enum Period: String, CaseIterable, Identifiable, Sendable {
    case today, week, month, all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "Today"
        case .week: "7 days"
        case .month: "Month"
        case .all: "All"
        }
    }

    /// Start of the period in the user's calendar; nil means no lower bound.
    func start(now: Date = .now, calendar: Calendar = .current) -> Date? {
        switch self {
        case .today: calendar.startOfDay(for: now)
        case .week: calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now))
        case .month: calendar.dateInterval(of: .month, for: now)?.start
        case .all: nil
        }
    }
}

/// Costs and tokens for one group of requests.
struct Totals: Sendable, Equatable {
    /// Billed by AWS or Google Cloud, at Anthropic list price plus the configured surcharge.
    var cloudCost: Double = 0
    /// Plan (or API key) usage, valued at Anthropic API list prices.
    var planValue: Double = 0
    var tokens: Int = 0
    /// Tokens that count toward your plan (everything not billed by a cloud provider).
    var planTokens: Int = 0
    var requests: Int = 0
    var lastActivity: Date?
    /// Requests for models missing from the price table.
    var unpricedRequests: Int = 0
    /// Part of the cost from side requests that aren't in the transcript (see `SideRequests`).
    var sideRequestCost: Double = 0

    var cost: Double { cloudCost + planValue }
    var cloudTokens: Int { tokens - planTokens }

    /// - Parameter factor: side-request factor for this message (1 when there is none).
    mutating func add(_ entry: UsageEntry, factor: Double = 1, cloudSurcharge: Double) {
        let base = Pricing.cost(of: entry)
        if base == nil { unpricedRequests += 1 }
        let markup = entry.backend.isCloudBilled ? 1 + cloudSurcharge : 1
        let cost = (base ?? 0) * factor * markup
        if entry.backend.isCloudBilled {
            cloudCost += cost
        } else {
            planValue += cost
        }
        sideRequestCost += (base ?? 0) * (factor - 1) * markup
        tokens += entry.totalTokens
        if !entry.backend.isCloudBilled { planTokens += entry.totalTokens }
        requests += 1
        if lastActivity.map({ entry.timestamp > $0 }) ?? true { lastActivity = entry.timestamp }
    }

    mutating func merge(_ other: Totals) {
        cloudCost += other.cloudCost
        planValue += other.planValue
        tokens += other.tokens
        planTokens += other.planTokens
        requests += other.requests
        unpricedRequests += other.unpricedRequests
        sideRequestCost += other.sideRequestCost
        if let last = other.lastActivity, lastActivity.map({ last > $0 }) ?? true { lastActivity = last }
    }
}

/// A row in the menu: a pinned session, a project or a single session.
struct UsageRow: Identifiable, Sendable, Equatable {
    var id: String
    var title: String
    var subtitle: String?
    var totals = Totals()
    var models: [String: Totals] = [:]
    var live: LiveSession?
    var children: [UsageRow] = []
}

struct UsageReport: Sendable, Equatable {
    var period: Period
    var overall = Totals()
    var pinned: [UsageRow] = []
    var desktop = UsageRow(id: "desktop", title: "Claude Desktop")
    var otherCLI = UsageRow(id: "other", title: "Other Claude Code sessions")

    static let empty = UsageReport(period: .today)

    /// Groups entries into pinned sessions, Claude Desktop (by project, then session) and the rest.
    static func build(
        entries: [UsageEntry],
        period: Period,
        pinned: [PinnedSession],
        titles: [String: String],
        live: [LiveSession],
        cloudSurcharge: Double,
        factors: [String: Double] = [:],
        now: Date = .now
    ) -> UsageReport {
        let start = period.start(now: now)
        let liveByID = Dictionary(live.map { ($0.sessionID, $0) }, uniquingKeysWith: { a, _ in a })
        func title(of session: String) -> String? { titles[session] ?? liveByID[session]?.name }

        var report = UsageReport(period: period)
        var pinnedRows = pinned.map { UsageRow(id: $0.id.uuidString, title: $0.label.isEmpty ? "Unnamed pin" : $0.label) }
        var pinnedIndexBySession: [String: Int?] = [:]
        func pinIndex(for session: String) -> Int? {
            if let cached = pinnedIndexBySession[session] { return cached }
            let index = pinned.firstIndex { $0.matches(sessionID: session, title: title(of: session)) }
            pinnedIndexBySession[session] = index
            return index
        }

        // project path → session id → row
        var desktopProjects: [String: [String: UsageRow]] = [:]
        var otherProjects: [String: [String: UsageRow]] = [:]

        for entry in entries {
            if let start, entry.timestamp < start { continue }
            let factor = factors[entry.messageID] ?? 1
            report.overall.add(entry, factor: factor, cloudSurcharge: cloudSurcharge)

            if let index = pinIndex(for: entry.sessionID) {
                add(entry, factor: factor, to: &pinnedRows[index], cloudSurcharge: cloudSurcharge)
                continue
            }
            let group = entry.isDesktop ? \UsageReport.desktop : \UsageReport.otherCLI
            report[keyPath: group].totals.add(entry, factor: factor, cloudSurcharge: cloudSurcharge)
            var sessionRow = (entry.isDesktop ? desktopProjects : otherProjects)[entry.project]?[entry.sessionID]
                ?? UsageRow(id: entry.sessionID, title: title(of: entry.sessionID) ?? "Session \(entry.sessionID.prefix(8))")
            add(entry, factor: factor, to: &sessionRow, cloudSurcharge: cloudSurcharge)
            if entry.isDesktop {
                desktopProjects[entry.project, default: [:]][entry.sessionID] = sessionRow
            } else {
                otherProjects[entry.project, default: [:]][entry.sessionID] = sessionRow
            }
        }

        // Live status for pinned rows: any running process whose session matches the pin.
        for (index, pin) in pinned.enumerated() {
            pinnedRows[index].live = live.first { pin.matches(sessionID: $0.sessionID, title: $0.name ?? titles[$0.sessionID]) }
            pinnedRows[index].subtitle = pinnedRows[index].live.flatMap { $0.cwd.map(displayPath) }
        }
        report.pinned = pinnedRows
        report.desktop.children = projectRows(desktopProjects, live: liveByID, prefix: "desktop")
        report.otherCLI.children = projectRows(otherProjects, live: liveByID, prefix: "other")
        return report
    }

    private static func add(_ entry: UsageEntry, factor: Double, to row: inout UsageRow, cloudSurcharge: Double) {
        row.totals.add(entry, factor: factor, cloudSurcharge: cloudSurcharge)
        row.models[Pricing.normalize(entry.model), default: Totals()].add(entry, factor: factor, cloudSurcharge: cloudSurcharge)
    }

    private static func projectRows(
        _ projects: [String: [String: UsageRow]], live: [String: LiveSession], prefix: String
    ) -> [UsageRow] {
        projects.map { path, sessions in
            var row = UsageRow(id: "\(prefix):\(path)", title: projectName(path), subtitle: displayPath(path))
            row.children = sessions.values.map { session in
                var session = session
                session.live = live[session.id]
                return session
            }.sorted(by: byCost)
            for child in row.children { row.totals.merge(child.totals) }
            return row
        }.sorted(by: byCost)
    }

    private static func byCost(_ a: UsageRow, _ b: UsageRow) -> Bool {
        if a.totals.cost != b.totals.cost { return a.totals.cost > b.totals.cost }
        return a.title < b.title
    }

    static func projectName(_ path: String) -> String {
        if path.isEmpty { return "Unknown folder" }
        if path.contains("/Library/Application Support/Claude/") { return "Scratch" }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    static func displayPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
