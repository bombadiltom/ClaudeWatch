import Foundation

/// Accounts for requests Claude Code makes but doesn't write to the transcript as messages: the
/// auto-mode classifier, away summaries, title generation and the like. In small sessions they can
/// be a third of the bill.
///
/// Claude Code records a running total per process run (`cost-state`). For each run, the
/// transcript's messages up to that record are scaled so they add up to Claude Code's total, and
/// later messages of the same run get the same factor.
enum SideRequests {
    /// Message id → factor (≥ 1) to apply to that message's list-price cost.
    static func factors(entries: [UsageEntry], snapshots: [CostSnapshot]) -> [String: Double] {
        guard !snapshots.isEmpty else { return [:] }
        let entriesBySession = Dictionary(grouping: entries, by: \.sessionID)
        var factors: [String: Double] = [:]

        for (session, sessionSnapshots) in Dictionary(grouping: snapshots, by: \.sessionID) {
            guard let sessionEntries = entriesBySession[session] else { continue }

            // The total is cumulative, so each run's largest snapshot is its latest.
            var latestByRun: [Date: CostSnapshot] = [:]
            for snapshot in sessionSnapshots {
                if let existing = latestByRun[snapshot.runStart], existing.cost >= snapshot.cost { continue }
                latestByRun[snapshot.runStart] = snapshot
            }
            let runs = latestByRun.values.sorted { $0.runStart < $1.runStart }

            for (index, run) in runs.enumerated() {
                let runEnd = index + 1 < runs.count ? runs[index + 1].runStart : .distantFuture
                let inRun = sessionEntries.filter { $0.timestamp >= run.runStart && $0.timestamp < runEnd }
                let covered = inRun
                    .filter { $0.timestamp <= run.asOf }
                    .reduce(0) { $0 + (Pricing.cost(of: $1) ?? 0) }
                guard covered > 0, run.cost > covered else { continue }
                let factor = run.cost / covered
                for entry in inRun { factors[entry.messageID] = factor }
            }
        }
        return factors
    }
}
