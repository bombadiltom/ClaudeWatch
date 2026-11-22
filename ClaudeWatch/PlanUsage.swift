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
    /// True if `resetsAt` came from Claude Code, not inferred from the transcripts.
    var resetIsExact = false
    /// The newest real reading of this limit, as Desktop or Claude Code saved it: shown next to the
    /// estimate, so an old reading plus a large estimate doesn't pass for a measurement.
    var reading: Reading?
    /// The part of `utilization` that `PlanEstimator` added from the transcripts since `reading`.
    var estimatedPart = 0.0

    struct Reading: Sendable, Equatable {
        enum Source: Sendable { case desktop, claudeCode }
        var source: Source
        var utilization: Double
        var date: Date
    }
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
    /// When Claude Code last reported the limits (see `LimitReading`), if the numbers use that.
    var liveAsOf: Date?

    /// True if Claude Code's numbers are newer than Desktop's sample.
    var isLive: Bool { liveAsOf.map { $0 >= asOf } ?? false }

    /// The time of the newest numbers, from Claude Code or Desktop.
    var updated: Date { max(asOf, liveAsOf ?? asOf) }

    /// Desktop samples every 15 minutes while it runs. An older sample may no longer be true.
    func isStale(now: Date = .now) -> Bool { now.timeIntervalSince(updated) > 30 * 60 }

    /// The 5-hour utilization, or nil if the sample is older than the window itself.
    func fiveHour(now: Date = .now) -> Double? {
        guard let limit = limit(PlanUsageReader.fiveHour) else { return nil }
        let windowRunning = limit.resetsAt.map { $0 > now } ?? false
        guard now.timeIntervalSince(updated) < 5 * 3600 || limit.isEstimated || windowRunning else { return nil }
        return limit.utilization
    }

    func limit(_ id: String) -> PlanLimit? { limits.first { $0.id == id } }
}

/// An exact reading of one plan limit from Claude Code: the account-wide utilization the API
/// reported, so it includes Desktop chats and Cowork, with the window's exact reset time.
struct LimitReading: Codable, Sendable, Equatable {
    /// `PlanUsageReader.fiveHour` or `.weekly`.
    var id: String
    /// 0–100
    var utilization: Double
    var resetsAt: Date
    /// When Claude Code got it.
    var date: Date

    /// The window id for Claude Code's names (`five_hour`, `seven_day`); nil for other limits.
    static func id(for name: String) -> String? {
        switch name {
        case "five_hour": PlanUsageReader.fiveHour
        case "seven_day": PlanUsageReader.weekly
        default: nil
        }
    }
}

/// Reads the limits that `scripts/claudewatch-statusline.sh` saves from Claude Code's status line
/// input: one `<session-id>.json` per session holding its `rate_limits` object, e.g.
/// `{"five_hour":{"used_percentage":12,"resets_at":1795372800},"seven_day":{…}}`.
///
/// Claude Code reruns the status line after each response, so the file's modification time is
/// when the numbers were current.
enum LiveLimitsReader {
    static var defaultDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(LegacyMigration.bundleID, isDirectory: true)
            .appendingPathComponent("rate-limits", isDirectory: true)
    }

    /// Files of sessions idle this long are deleted; their windows have reset anyway.
    static let maxAge: TimeInterval = 8 * 86_400

    static func read(from directory: URL? = defaultDirectory, now: Date = .now, prune: Bool = true) -> [LimitReading] {
        guard let directory,
              let urls = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles
              )
        else { return [] }
        var readings: [LimitReading] = []
        for url in urls where url.pathExtension == "json" {
            guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            else { continue }
            if now.timeIntervalSince(modified) > maxAge {
                if prune { try? FileManager.default.removeItem(at: url) }
                continue
            }
            guard let data = try? Data(contentsOf: url) else { continue }
            readings += parse(data, date: modified)
        }
        return readings
    }

    /// Accepts the `rate_limits` object itself or the whole status line input that contains it.
    static func parse(_ data: Data, date: Date) -> [LimitReading] {
        guard var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        if let nested = object["rate_limits"] as? [String: Any] { object = nested }
        return object.compactMap { name, value in
            guard let id = LimitReading.id(for: name),
                  let window = value as? [String: Any],
                  let used = (window["used_percentage"] as? NSNumber)?.doubleValue,
                  let resetsAt = Self.date(from: window["resets_at"])
            else { return nil }
            return LimitReading(id: id, utilization: used, resetsAt: resetsAt, date: date)
        }
    }

    /// Epoch seconds (or milliseconds), or an ISO 8601 string.
    static func date(from value: Any?) -> Date? {
        if let number = value as? NSNumber {
            let seconds = number.doubleValue
            return Date(timeIntervalSince1970: seconds > 100_000_000_000 ? seconds / 1000 : seconds)
        }
        if let string = value as? String {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)
        }
        return nil
    }
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

    static func order(of key: String) -> String {
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
/// transcripts also give its reset time. Desktop chats and Cowork aren't in the transcripts, so with
/// heavy use there the estimate stays low and the inferred window can start too late.
///
/// Exact readings from Claude Code (`LimitReading`: its status line input, or a "limit reached"
/// error) beat both: they are account-wide and carry the exact reset time. The newest of Desktop's
/// sample and Claude Code's reading is the base, and only the usage after it is estimated.
enum PlanEstimator {
    struct Usage: Sendable {
        var date: Date
        /// API list-price value, including side requests.
        var value: Double
    }

    static let window: TimeInterval = 5 * 3600
    static let week: TimeInterval = 7 * 86_400
    /// Readings further apart than this may hide a reset in between, so they don't teach the rate.
    static let maxGap: TimeInterval = 3600
    static let lookback: TimeInterval = 3 * 86_400

    static func estimate(_ usage: PlanUsage?, plan: [Usage], readings: [LimitReading] = [], now: Date = .now) -> PlanUsage? {
        let plan = plan.filter { $0.date > now.addingTimeInterval(-week) && $0.date <= now }.sorted { $0.date < $1.date }
        let readings = readings.filter { $0.date <= now.addingTimeInterval(60) && $0.resetsAt > now.addingTimeInterval(-week) }
        let fh = PlanUsageReader.fiveHour, sd = PlanUsageReader.weekly

        // Without Desktop, Claude Code's readings alone make the numbers.
        guard var result = usage ?? readings.map(\.date).max().map({ PlanUsage(limits: [], asOf: $0) }) else { return nil }
        let desktopIDs = Set((usage?.limits ?? []).map(\.id))
        for id in [fh, sd] where !desktopIDs.contains(id) && readings.contains(where: { $0.id == id }) {
            result.limits.append(PlanLimit(id: id, label: PlanUsageReader.label(for: id), utilization: 0))
        }
        result.limits.sort { PlanUsageReader.order(of: $0.id) < PlanUsageReader.order(of: $1.id) }

        let samples = usage?.samples ?? []
        let fhRate = rate(fh, samples: samples, plan: plan, now: now, minValue: 3)
        let sdRate = rate(sd, samples: samples, plan: plan, now: now, minValue: 10)

        for index in result.limits.indices {
            var limit = result.limits[index]
            // Desktop's value for this limit and when it took it, if it has one.
            let desktopAsOf = desktopIDs.contains(limit.id) ? usage?.asOf : nil
            let (length, limitRate): (TimeInterval, Double?) = switch limit.id {
                case fh: (window, fhRate)
                case sd: (week, sdRate)
                default: (0, nil)
            }
            let live = newestReading(limit.id, in: readings)
            if let live { result.liveAsOf = max(result.liveAsOf ?? live.date, live.date) }
            let desktopReading = desktopAsOf.map { PlanLimit.Reading(source: .desktop, utilization: limit.utilization, date: $0) }
            let liveReading = live.map { PlanLimit.Reading(source: .claudeCode, utilization: $0.utilization, date: $0.date) }
            limit.reading = [desktopReading, liveReading].compactMap { $0 }.max { $0.date < $1.date }

            if let live, live.resetsAt > now {
                // Claude Code knows the running window: start from the newer of its reading and
                // Desktop's, and add the plan usage since.
                var base = live.utilization, since = live.date
                if let desktopAsOf, desktopAsOf > live.date, desktopAsOf > live.resetsAt.addingTimeInterval(-length) {
                    base = max(base, limit.utilization)
                    since = desktopAsOf
                }
                let added = (limitRate ?? 0) * value(plan, after: since)
                limit.utilization = base + added
                limit.estimatedPart = added
                limit.isEstimated = added > 0
                limit.resetsAt = live.resetsAt
                limit.resetIsExact = true
            } else {
                // A window Claude Code reported has ended since: nothing before its reset counts.
                let knownReset = live?.resetsAt
                if let knownReset, desktopAsOf.map({ $0 < knownReset }) ?? true {
                    limit.utilization = 0
                    limit.isEstimated = true
                }
                let readingAsOf = knownReset.map { max($0, desktopAsOf ?? $0) } ?? desktopAsOf
                switch limit.id {
                case fh:
                    // A sample at 0 % means no window was running then: the next one starts after it,
                    // whatever the transcripts show before (Cowork or a chat may have started theirs).
                    let emptyAt = desktopAsOf.flatMap { knownReset == nil && limit.utilization == 0 ? $0 : nil }
                    estimateFiveHour(
                        &limit, asOf: readingAsOf, after: knownReset ?? emptyAt, plan: plan, rate: limitRate, now: now
                    )
                case sd:
                    guard let rate = limitRate, let readingAsOf, now.timeIntervalSince(readingAsOf) < 86_400 || knownReset != nil else { break }
                    let added = rate * value(plan, after: readingAsOf)
                    if added > 0 { limit.utilization += added; limit.estimatedPart += added; limit.isEstimated = true }
                default:
                    break
                }
            }
            limit.utilization = min(limit.utilization, 100)
            limit.estimatedPart = min(limit.estimatedPart, limit.utilization)
            result.limits[index] = limit
        }
        return result
    }

    /// The 5-hour window from the transcripts alone: the newest one they show starting, after
    /// `knownReset` if Claude Code reported when the previous one ended.
    private static func estimateFiveHour(
        _ limit: inout PlanLimit, asOf: Date?, after knownReset: Date?, plan: [Usage], rate: Double?, now: Date
    ) {
        var windowStart: Date?
        for request in plan where request.date >= (knownReset ?? .distantPast)
            && windowStart.map({ request.date >= $0.addingTimeInterval(window) }) ?? true {
            windowStart = request.date
        }
        guard let start = windowStart, let asOf else { return }
        let end = start.addingTimeInterval(window)
        guard now < end else {
            // The window the transcripts know of is over: unless a Desktop chat or Cowork started a
            // new one, nothing is used.
            if asOf < end { limit.utilization = 0; limit.isEstimated = true }
            return
        }
        limit.resetsAt = end
        guard let rate else { return }
        if asOf >= start {
            let added = rate * value(plan, after: asOf)
            if added > 0 { limit.utilization += added; limit.estimatedPart += added; limit.isEstimated = true }
        } else {
            // The reading is from the previous window.
            limit.utilization = rate * value(plan, after: start.addingTimeInterval(-1))
            limit.estimatedPart = limit.utilization
            limit.isEstimated = true
        }
    }

    /// The newest reading of a limit. Within one window, usage only rises, so it takes the highest
    /// value any session saw for that window: a session that idled can't pull it back down.
    static func newestReading(_ id: String, in readings: [LimitReading]) -> LimitReading? {
        let ofLimit = readings.filter { $0.id == id }
        guard var newest = ofLimit.max(by: { $0.date < $1.date }) else { return nil }
        // Reset times of one window can differ by a few seconds between responses.
        let sameWindow = ofLimit.filter { abs($0.resetsAt.timeIntervalSince(newest.resetsAt)) < 3600 }
        newest.utilization = sameWindow.map(\.utilization).max() ?? newest.utilization
        return newest
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
