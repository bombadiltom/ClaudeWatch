import Foundation

/// One usage window of a Pro/Max plan, e.g. the 5-hour session or the weekly limit.
struct PlanLimit: Identifiable, Sendable, Equatable {
    var id: String
    var label: String
    /// 0–100
    var utilization: Double
    /// True if `utilization` adds an estimate of the usage since Desktop's sample.
    var isEstimated = false
    var resetsAt: Date?
}

/// One reading Claude Desktop saved: utilization per window id (`fh`, `sd`).
struct PlanSample: Sendable, Equatable {
    var date: Date
    var values: [String: Double]
}

/// The plan's utilization as Claude Desktop last saw it, plus its earlier readings.
struct PlanUsage: Sendable, Equatable {
    var limits: [PlanLimit]
    /// When Claude Desktop took the newest sample.
    var asOf: Date
    /// All readings of the newest sample's organization, oldest first.
    var samples: [PlanSample] = []

    /// Desktop samples every 15 minutes while it runs. An older sample may no longer be true.
    func isStale(now: Date = .now) -> Bool { now.timeIntervalSince(asOf) > 30 * 60 }

    /// The 5-hour utilization, or nil if the sample is older than the window itself.
    func fiveHour(now: Date = .now) -> Double? {
        guard now.timeIntervalSince(asOf) < 5 * 3600 || limit(PlanUsageReader.fiveHour)?.isEstimated == true else { return nil }
        return limit(PlanUsageReader.fiveHour)?.utilization
    }

    func limit(_ id: String) -> PlanLimit? { limits.first { $0.id == id } }
}

/// Reads the plan usage Claude Desktop records in `plan-usage-history.json`: the 5-hour and weekly
/// utilization of your Pro/Max plan, the numbers Desktop's Settings › Usage shows. Desktop adds a
/// sample about every 15 minutes while it runs. No login or network access is needed.
///
/// The file isn't a documented format, so parsing is deliberately loose.
enum PlanUsageReader {
    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json")
    }

    static let fiveHour = "fh"
    static let weekly = "sd"

    static func read(from url: URL = defaultURL) -> PlanUsage? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parse(data)
    }

    static func parse(_ data: Data) -> PlanUsage? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["samples"] as? [[String: Any]]
        else { return nil }

        let samples = raw.compactMap { sample -> (org: String?, sample: PlanSample)? in
            guard let t = (sample["t"] as? NSNumber)?.doubleValue,
                  let usage = sample["u"] as? [String: Any]
            else { return nil }
            let values = usage.compactMapValues { ($0 as? NSNumber)?.doubleValue }
            guard !values.isEmpty else { return nil }
            return (sample["org"] as? String, PlanSample(date: Date(timeIntervalSince1970: t / 1000), values: values))
        }
        guard let newest = samples.max(by: { $0.sample.date < $1.sample.date }) else { return nil }

        let limits = newest.sample.values
            .map { PlanLimit(id: $0.key, label: label(for: $0.key), utilization: $0.value) }
            .sorted { order(of: $0.id) < order(of: $1.id) }
        let history = samples.filter { $0.org == newest.org }.map(\.sample).sorted { $0.date < $1.date }
        return PlanUsage(limits: limits, asOf: newest.sample.date, samples: history)
    }

    static func label(for key: String) -> String {
        switch key {
        case fiveHour: "5-hour session"
        case weekly: "Weekly"
        default: key
        }
    }

    private static func order(of key: String) -> String {
        switch key {
        case fiveHour: "0"
        case weekly: "1"
        default: "2" + key
        }
    }
}

/// Brings Desktop's last reading up to date with the Claude Code usage since then.
///
/// Desktop saves the plan usage only every 15 minutes, so during heavy use it trails Desktop's own
/// Usage view. Between two readings, the utilization rises roughly in proportion to the API value of
/// the plan requests in between (about 2.6% of the 5-hour window per dollar on a Pro plan). The rate
/// is learned from Desktop's own readings, so it fits whatever plan you have.
///
/// The 5-hour window starts with the first plan request after the previous window ended, so the
/// transcripts also give its reset time. Desktop chats aren't in the transcripts, so with heavy chat
/// use the estimate stays a little low.
enum PlanEstimator {
    struct Usage: Sendable {
        var date: Date
        /// API list-price value, including side requests.
        var value: Double
    }

    static let window: TimeInterval = 5 * 3600
    /// Readings further apart than this may hide a reset in between, so they don't teach the rate.
    static let maxGap: TimeInterval = 3600
    static let lookback: TimeInterval = 3 * 86_400

    static func estimate(_ usage: PlanUsage, plan: [Usage], now: Date = .now) -> PlanUsage {
        let plan = plan.filter { $0.date > now.addingTimeInterval(-7 * 86_400) && $0.date <= now }.sorted { $0.date < $1.date }
        var result = usage

        // 5-hour window: the newest one that the transcripts show starting.
        var windowStart: Date?
        for request in plan where windowStart.map({ request.date >= $0.addingTimeInterval(window) }) ?? true {
            windowStart = request.date
        }

        let fhRate = rate(PlanUsageReader.fiveHour, samples: usage.samples, plan: plan, now: now, minValue: 3)
        let sdRate = rate(PlanUsageReader.weekly, samples: usage.samples, plan: plan, now: now, minValue: 10)

        for index in result.limits.indices {
            var limit = result.limits[index]
            switch limit.id {
            case PlanUsageReader.fiveHour:
                guard let start = windowStart else { break }
                let end = start.addingTimeInterval(window)
                guard now < end else {
                    // The window the transcripts know of is over: unless a Desktop chat started a new
                    // one, nothing is used.
                    if usage.asOf < end { limit.utilization = 0; limit.isEstimated = true }
                    break
                }
                limit.resetsAt = end
                guard let fhRate else { break }
                if usage.asOf >= start {
                    let added = fhRate * value(plan, after: usage.asOf)
                    if added > 0 { limit.utilization += added; limit.isEstimated = true }
                } else {
                    // Desktop's reading is from the previous window.
                    limit.utilization = fhRate * value(plan, after: start.addingTimeInterval(-1))
                    limit.isEstimated = true
                }
            case PlanUsageReader.weekly:
                guard let sdRate, now.timeIntervalSince(usage.asOf) < 86_400 else { break }
                let added = sdRate * value(plan, after: usage.asOf)
                if added > 0 { limit.utilization += added; limit.isEstimated = true }
            default:
                break
            }
            limit.utilization = min(limit.utilization, 100)
            result.limits[index] = limit
        }
        return result
    }

    /// Percent per dollar of plan usage: the rise between consecutive readings (without a reset in
    /// between) divided by the value of the plan requests in those intervals.
    static func rate(_ id: String, samples: [PlanSample], plan: [Usage], now: Date, minValue: Double) -> Double? {
        var rise = 0.0, spent = 0.0
        let recent = samples.filter { $0.date > now.addingTimeInterval(-lookback) }
        for (a, b) in zip(recent, recent.dropFirst()) {
            guard let from = a.values[id], let to = b.values[id], to >= from,
                  b.date.timeIntervalSince(a.date) <= maxGap
            else { continue }
            rise += to - from
            spent += plan.lazy.filter { $0.date > a.date && $0.date <= b.date }.reduce(0) { $0 + $1.value }
        }
        guard spent >= minValue, rise > 0 else { return nil }
        return rise / spent
    }

    private static func value(_ plan: [Usage], after date: Date) -> Double {
        plan.lazy.filter { $0.date > date }.reduce(0) { $0 + $1.value }
    }
}
