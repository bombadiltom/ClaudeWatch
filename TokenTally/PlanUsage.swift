import Foundation

/// One usage window of a Pro/Max plan, e.g. the 5-hour session or the weekly limit.
struct PlanLimit: Identifiable, Sendable, Equatable {
    var id: String
    var label: String
    /// 0–100
    var utilization: Double
}

/// The plan's utilization as Claude Desktop last saw it.
struct PlanUsage: Sendable, Equatable {
    var limits: [PlanLimit]
    /// When Claude Desktop took the sample.
    var asOf: Date

    /// Desktop samples every 15 minutes while it runs. An older sample may no longer be true.
    func isStale(now: Date = .now) -> Bool { now.timeIntervalSince(asOf) > 30 * 60 }

    /// The 5-hour utilization, or nil if the sample is older than the window itself.
    func fiveHour(now: Date = .now) -> Double? {
        guard now.timeIntervalSince(asOf) < 5 * 3600 else { return nil }
        return limits.first { $0.id == PlanUsageReader.fiveHour }?.utilization
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

    static func read(from url: URL = defaultURL) -> PlanUsage? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parse(data)
    }

    static func parse(_ data: Data) -> PlanUsage? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let samples = object["samples"] as? [[String: Any]]
        else { return nil }

        let newest = samples
            .compactMap { sample -> (Date, [String: Any])? in
                guard let t = (sample["t"] as? NSNumber)?.doubleValue,
                      let usage = sample["u"] as? [String: Any]
                else { return nil }
                return (Date(timeIntervalSince1970: t / 1000), usage)
            }
            .max { $0.0 < $1.0 }
        guard let (date, usage) = newest else { return nil }

        let limits = usage
            .compactMap { key, value -> PlanLimit? in
                guard let utilization = (value as? NSNumber)?.doubleValue else { return nil }
                return PlanLimit(id: key, label: label(for: key), utilization: utilization)
            }
            .sorted { order(of: $0.id) < order(of: $1.id) }
        return limits.isEmpty ? nil : PlanUsage(limits: limits, asOf: date)
    }

    static let fiveHour = "fh"

    static func label(for key: String) -> String {
        switch key {
        case "fh": "5-hour session"
        case "sd": "Weekly"
        default: key
        }
    }

    private static func order(of key: String) -> String {
        switch key {
        case "fh": "0"
        case "sd": "1"
        default: "2" + key
        }
    }
}
