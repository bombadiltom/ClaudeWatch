import XCTest
@testable import ClaudeWatch

final class PricingTests: XCTestCase {
    func testNormalizesProviderDecorations() {
        XCTAssertEqual(Pricing.normalize("eu.anthropic.claude-opus-5-5"), "claude-opus-5-5")
        XCTAssertEqual(Pricing.normalize("anthropic.claude-sonnet-4-5-20250929-v1:0"), "claude-sonnet-4-5")
        XCTAssertEqual(Pricing.normalize("claude-opus-4-5@20251101"), "claude-opus-4-5")
        XCTAssertEqual(Pricing.normalize("claude-opus-5-5[1m]"), "claude-opus-5-5")
        XCTAssertEqual(Pricing.normalize("claude-opus-4-20250514"), "claude-opus-4")
    }

    func testDoesNotConfuseNeighbouringModels() {
        XCTAssertEqual(Pricing.price(for: "claude-opus-5-5")?.input, 4)
        XCTAssertEqual(Pricing.price(for: "claude-opus-5")?.input, 5)
        XCTAssertEqual(Pricing.price(for: "claude-sonnet-5-5")?.cacheRead, 0.10)
        XCTAssertEqual(Pricing.price(for: "claude-sonnet-5")?.cacheRead, 0.20)
        XCTAssertNil(Pricing.price(for: "claude-opus-9"))
    }

    /// Claude Code's own `cost-state` record for a real Bedrock session said $3.9360296 for these tokens.
    func testMatchesClaudeCodesOwnCost() throws {
        let entry = UsageEntry.fixture(
            model: "claude-opus-5-5", input: 150_794, output: 49_529, cacheRead: 2_398_443, cacheWrite5m: 372_517
        )
        XCTAssertEqual(try XCTUnwrap(Pricing.cost(of: entry)), 3.9360296, accuracy: 0.000001)
    }

    func testOneHourCacheWritesCostTwiceInput() throws {
        let entry = UsageEntry.fixture(model: "claude-opus-5-5", cacheWrite1h: 1_000_000)
        XCTAssertEqual(try XCTUnwrap(Pricing.cost(of: entry)), 8, accuracy: 0.0001)
    }

    func testFastModeDoublesCost() throws {
        var entry = UsageEntry.fixture(model: "claude-opus-5-5", input: 1_000_000, output: 1_000_000)
        entry.fast = true
        XCTAssertEqual(try XCTUnwrap(Pricing.cost(of: entry)), 48, accuracy: 0.0001) // $8 + $40
    }

    func testHaikuLongPromptTier() throws {
        let short = UsageEntry.fixture(model: "claude-haiku-5-5", input: 100_000, output: 1_000_000)
        let long = UsageEntry.fixture(model: "claude-haiku-5-5", input: 100_001, output: 1_000_000)
        XCTAssertEqual(try XCTUnwrap(Pricing.cost(of: short)), 0.01 + 0.5, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(Pricing.cost(of: long)), 0.0500005 + 2.5, accuracy: 0.0001)
    }
}

final class TranscriptTests: XCTestCase {
    func testParsesAssistantLine() throws {
        let line = #"""
        {"type":"assistant","timestamp":"2026-11-13T12:53:40.883Z","sessionId":"s1","cwd":"/tmp/p","entrypoint":"cli","message":{"id":"msg_bdrk_abc","model":"claude-opus-5-5","usage":{"input_tokens":2,"cache_creation_input_tokens":300,"cache_read_input_tokens":12233,"output_tokens":113,"speed":"standard","cache_creation":{"ephemeral_1h_input_tokens":100,"ephemeral_5m_input_tokens":200}}}}
        """#
        let entry = try XCTUnwrap(TranscriptScanner(cacheURL: nil).entry(fromLine: Data(line.utf8)))
        XCTAssertEqual(entry.backend, .bedrock)
        XCTAssertEqual(entry.cacheWrite5m, 200)
        XCTAssertEqual(entry.cacheWrite1h, 100)
        XCTAssertEqual(entry.cacheRead, 12233)
        XCTAssertFalse(entry.fast)
        XCTAssertEqual(entry.totalTokens, 2 + 300 + 12233 + 113)
    }

    func testSkipsSyntheticMessages() {
        let line = #"{"type":"assistant","timestamp":"2026-11-13T12:53:40.883Z","sessionId":"s1","message":{"id":"x","model":"<synthetic>","usage":{"input_tokens":0,"output_tokens":0}}}"#
        XCTAssertNil(TranscriptScanner(cacheURL: nil).entry(fromLine: Data(line.utf8)))
    }

    func testScansIncrementallyAndDeduplicates() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let project = root.appendingPathComponent("-tmp-p")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func line(_ id: String, _ session: String, _ time: String) -> String {
            #"{"type":"assistant","timestamp":"\#(time)","sessionId":"\#(session)","cwd":"/tmp/p","message":{"id":"\#(id)","model":"claude-opus-5-5","usage":{"input_tokens":10,"output_tokens":5}}}"# + "\n"
        }
        let file = project.appendingPathComponent("s1.jsonl")
        // The same message twice (one line per content block), plus a title.
        try (line("m1", "s1", "2026-11-13T10:00:00.000Z") + line("m1", "s1", "2026-11-13T10:00:00.000Z")
            + #"{"type":"custom-title","customTitle":"globex-main","sessionId":"s1"}"# + "\n")
            .write(to: file, atomically: true, encoding: .utf8)
        // A fork copies m1 into another file.
        try line("m1", "s2", "2026-11-13T10:00:00.000Z")
            .write(to: project.appendingPathComponent("s2.jsonl"), atomically: true, encoding: .utf8)

        let scanner = TranscriptScanner(root: root, cacheURL: nil)
        var result = await scanner.scan()
        XCTAssertEqual(result.entries.count, 1)
        XCTAssertEqual(result.titles["s1"], "globex-main")

        // Append a new message plus a half-written line.
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line("m2", "s1", "2026-11-13T11:00:00.000Z") + #"{"type":"assis"#).utf8))
        try handle.close()
        result = await scanner.scan()
        XCTAssertEqual(Set(result.entries.map(\.messageID)), ["m1", "m2"])
    }
}

final class ReportTests: XCTestCase {
    func testGroupsPinnedDesktopAndOther() {
        let now = ISO8601DateFormatter().date(from: "2026-11-21T12:00:00Z")!
        let pins = [
            PinnedSession(label: "globex-main", sessionID: "aaaa"),
            PinnedSession(label: "acme-review", sessionID: "never-used"),
        ]
        let entries = [
            UsageEntry.fixture(id: "1", session: "aaaa", model: "claude-opus-5-5", input: 1_000_000, backend: .bedrock, at: now),
            // Matches the second pin by title even though the id differs.
            UsageEntry.fixture(id: "2", session: "bbbb", model: "claude-opus-5-5", input: 1_000_000, backend: .bedrock, at: now),
            UsageEntry.fixture(id: "3", session: "cccc", model: "claude-opus-5-5", input: 1_000_000, entrypoint: "claude-desktop", at: now),
            UsageEntry.fixture(id: "4", session: "dddd", model: "claude-opus-5-5", input: 1_000_000, at: now),
            // Yesterday: outside "today".
            UsageEntry.fixture(id: "5", session: "aaaa", model: "claude-opus-5-5", input: 1_000_000, backend: .bedrock,
                               at: now.addingTimeInterval(-86_400)),
        ]
        let report = UsageReport.build(
            entries: entries, period: .today, pinned: pins, titles: ["bbbb": "acme-review", "cccc": "Desktop chat"],
            live: [], cloudSurcharge: 0.1, now: now
        )
        XCTAssertEqual(report.pinned[0].totals.cloudCost, 4.4, accuracy: 0.0001)
        XCTAssertEqual(report.pinned[1].totals.cloudCost, 4.4, accuracy: 0.0001)
        XCTAssertEqual(report.desktop.totals.planValue, 4, accuracy: 0.0001)
        XCTAssertEqual(report.desktop.children.first?.children.first?.title, "Desktop chat")
        XCTAssertEqual(report.otherCLI.totals.requests, 1)
        XCTAssertEqual(report.overall.cloudCost, 8.8, accuracy: 0.0001)
        XCTAssertEqual(report.overall.planValue, 8, accuracy: 0.0001)
    }
}

final class SideRequestTests: XCTestCase {
    func testScalesEachRunToClaudeCodesTotal() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        func entry(_ id: String, _ offset: TimeInterval) -> UsageEntry {
            .fixture(id: id, session: "s", model: "claude-opus-5-5", input: 1_000_000, at: t0.addingTimeInterval(offset)) // $4 each
        }
        let entries = [entry("a", 10), entry("b", 20), entry("c", 30), entry("d", 1010)]
        let snapshots = [
            // Run 1: an early snapshot, then the latest one covering a and b ($8) at $10.
            CostSnapshot(sessionID: "s", runStart: t0, cost: 5, asOf: t0.addingTimeInterval(10)),
            CostSnapshot(sessionID: "s", runStart: t0, cost: 10, asOf: t0.addingTimeInterval(20)),
            // Run 2: Claude Code counted less than the transcript, so no adjustment.
            CostSnapshot(sessionID: "s", runStart: t0.addingTimeInterval(1000), cost: 3, asOf: t0.addingTimeInterval(1010)),
        ]
        let factors = SideRequests.factors(entries: entries, snapshots: snapshots)
        XCTAssertEqual(factors["a"] ?? 0, 1.25, accuracy: 0.0001)
        XCTAssertEqual(factors["b"] ?? 0, 1.25, accuracy: 0.0001)
        XCTAssertEqual(factors["c"] ?? 0, 1.25, accuracy: 0.0001, "later messages of the run get the run's factor")
        XCTAssertNil(factors["d"])

        let report = UsageReport.build(
            entries: entries, period: .all, pinned: [], titles: [:], live: [], cloudSurcharge: 0, factors: factors
        )
        XCTAssertEqual(report.overall.planValue, 3 * 5 + 4, accuracy: 0.0001)
        XCTAssertEqual(report.overall.sideRequestCost, 3, accuracy: 0.0001)
    }
}

final class PlanUsageTests: XCTestCase {
    func testReadsNewestDesktopSample() throws {
        let json = #"""
        {"version":2,"samples":[
          {"t":1795000000000,"org":"o","u":{"fh":92,"sd":31}},
          {"t":1795100000000,"org":"o","u":{"fh":30,"sd":35}},
          {"t":1795050000000,"org":"o","u":{"fh":0,"sd":33}}
        ]}
        """#
        let usage = try XCTUnwrap(PlanUsageReader.parse(Data(json.utf8)))
        XCTAssertEqual(usage.limits.map(\.id), ["fh", "sd"])
        XCTAssertEqual(usage.limits.map(\.utilization), [30, 35])
        XCTAssertEqual(usage.asOf, Date(timeIntervalSince1970: 1_795_100_000))
        XCTAssertTrue(usage.isStale(now: usage.asOf.addingTimeInterval(31 * 60)))
        XCTAssertFalse(usage.isStale(now: usage.asOf.addingTimeInterval(10 * 60)))
    }

    func testIgnoresUnreadableFiles() {
        XCTAssertNil(PlanUsageReader.parse(Data("{}".utf8)))
        XCTAssertNil(PlanUsageReader.parse(Data(#"{"samples":[]}"#.utf8)))
    }
}

extension UsageEntry {
    static func fixture(
        id: String = UUID().uuidString, session: String = "s", model: String,
        input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite5m: Int = 0, cacheWrite1h: Int = 0,
        entrypoint: String = "cli", backend: Backend = .anthropic, at date: Date = .now
    ) -> UsageEntry {
        UsageEntry(
            messageID: id, timestamp: date, sessionID: session, project: "/tmp/p", entrypoint: entrypoint,
            model: model, backend: backend, input: input, output: output, cacheRead: cacheRead,
            cacheWrite5m: cacheWrite5m, cacheWrite1h: cacheWrite1h, fast: false
        )
    }
}
