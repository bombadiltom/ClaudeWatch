import Foundation

/// Anthropic list prices in USD per million tokens.
struct ModelPrice: Sendable, Equatable {
    let input: Double
    let output: Double
    let cacheRead: Double
    /// 5-minute cache writes cost 1.25× input, 1-hour writes 2× input.
    var cacheWrite5m: Double { input * 1.25 }
    var cacheWrite1h: Double { input * 2 }
}

enum Pricing {
    /// Keyed by the bare model id. A key also matches dated snapshots such as `claude-opus-4-20250514`.
    /// Claude Code computes its own `costUSD` with these same first-party rates, Bedrock sessions included.
    static let table: [String: ModelPrice] = {
        var t: [String: ModelPrice] = [:]
        func add(_ ids: [String], _ input: Double, _ output: Double, _ cacheRead: Double) {
            for id in ids { t[id] = ModelPrice(input: input, output: output, cacheRead: cacheRead) }
        }
        add(["claude-fable-5-2", "claude-mythos-5-2"], 8, 40, 0.20)
        add(["claude-fable-5-1", "claude-mythos-5-1"], 10, 50, 0.25)
        add(["claude-fable-5", "claude-mythos-5"], 10, 50, 1.00)
        add(["claude-opus-5-5"], 4, 20, 0.20)
        add(["claude-opus-5", "claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-6", "claude-opus-4-5"], 5, 25, 0.50)
        add(["claude-opus-4-1", "claude-opus-4", "claude-3-opus"], 15, 75, 1.50)
        add(["claude-sonnet-5-5"], 2, 10, 0.10)
        add(["claude-sonnet-5"], 2, 10, 0.20)
        add(["claude-sonnet-4-6", "claude-sonnet-4-5", "claude-sonnet-4", "claude-3-7-sonnet", "claude-3-5-sonnet"], 3, 15, 0.30)
        add(["claude-haiku-5-5"], 0.10, 0.50, 0.01)
        add(["claude-haiku-4-5"], 1, 5, 0.10)
        add(["claude-3-5-haiku"], 0.80, 4, 0.08)
        add(["claude-3-haiku"], 0.25, 1.25, 0.03)
        return t
    }()

    /// Claude Haiku 5.5 costs more once a prompt passes 100K tokens.
    static let haiku55LongPrompt = ModelPrice(input: 0.50, output: 2.50, cacheRead: 0.05)

    /// Turns `eu.anthropic.claude-opus-5-5`, `anthropic.claude-sonnet-4-5-20250929-v1:0`,
    /// `claude-opus-4-5@20251101` or `claude-opus-5-5[1m]` into the bare id used by `table`.
    static func normalize(_ model: String) -> String {
        var id = model.lowercased()
        if let bracket = id.firstIndex(of: "[") { id = String(id[..<bracket]) }
        if let at = id.firstIndex(of: "@") { id = String(id[..<at]) }
        if let range = id.range(of: "claude-") { id = String(id[range.lowerBound...]) }
        if let range = id.range(of: #"-v\d+(:\d+)?$"#, options: .regularExpression) { id.removeSubrange(range) }
        if let range = id.range(of: #"-\d{8}$"#, options: .regularExpression) { id.removeSubrange(range) }
        return id
    }

    static func price(for model: String) -> ModelPrice? {
        table[normalize(model)]
    }

    /// Cost in USD at Anthropic list prices, or nil if the model isn't in the table.
    static func cost(of entry: UsageEntry) -> Double? {
        guard var price = price(for: entry.model) else { return nil }
        if normalize(entry.model) == "claude-haiku-5-5", entry.promptTokens > 100_000 {
            price = haiku55LongPrompt
        }
        let perMillion = Double(entry.input) * price.input
            + Double(entry.output) * price.output
            + Double(entry.cacheRead) * price.cacheRead
            + Double(entry.cacheWrite5m) * price.cacheWrite5m
            + Double(entry.cacheWrite1h) * price.cacheWrite1h
        // Fast mode bills every token at twice the standard rate.
        return perMillion / 1_000_000 * (entry.fast ? 2 : 1)
    }
}
