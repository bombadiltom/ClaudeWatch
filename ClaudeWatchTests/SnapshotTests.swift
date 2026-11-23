import AppKit
import SwiftUI
import XCTest
@testable import ClaudeWatch

/// Renders the menu with your real data to a PNG, for looking at the layout without clicking the
/// menu bar. Skipped unless `CLAUDEWATCH_SNAPSHOT_DIR` is set:
///
///     TEST_RUNNER_CLAUDEWATCH_SNAPSHOT_DIR=/tmp/shots xcodebuild test -scheme ClaudeWatch \
///       -only-testing:ClaudeWatchTests/SnapshotTests
@MainActor
final class SnapshotTests: XCTestCase {
    func testRenderMenu() async throws {
        guard let path = ProcessInfo.processInfo.environment["CLAUDEWATCH_SNAPSHOT_DIR"] else {
            throw XCTSkip("set CLAUDEWATCH_SNAPSHOT_DIR to render the menu")
        }
        let dir = URL(fileURLWithPath: path)
        let store = UsageStore()
        for _ in 0..<600 where !store.hasScanned { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(store.hasScanned)

        for period in [Period.today, .month] {
            store.period = period
            var expanded = Set(store.report.pinned.prefix(1).map(\.id))
            if let project = store.report.desktop.children.first { expanded.insert(project.id) }
            try render(MenuContentView(store: store, expanded: expanded), to: dir.appendingPathComponent("menu-\(period).png"))
            try render(MenuBarLabel(store: store).padding(4).background(.white), to: dir.appendingPathComponent("menubar-\(period).png"))
        }
        try render(SettingsView(store: store, done: {}).padding(14).frame(width: 380), to: dir.appendingPathComponent("settings.png"))

        // Live plan limits before setting up, next to a status line of your own (in a temporary folder).
        let claude = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: claude) }
        try #"{"statusLine": {"type": "command", "command": "~/.claude/statusline.sh"}}"#
            .write(to: claude.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        try render(
            LiveLimitsSetupView(lastReading: nil, setup: StatusLineSetup(claudeDirectory: claude), plugin: PluginSetup(claudeDirectory: claude)).padding(14).frame(width: 380),
            to: dir.appendingPathComponent("settings-live-limits.png")
        )

        // The plan limits as an example Claude Code status line reading makes them.
        let now = Date.now
        let live = PlanEstimator.estimate(store.planUsage, plan: [], readings: [
            LimitReading(id: PlanUsageReader.fiveHour, utilization: 3, resetsAt: now.addingTimeInterval(4.8 * 3600), date: now.addingTimeInterval(-60)),
            LimitReading(id: PlanUsageReader.weekly, utilization: 62, resetsAt: now.addingTimeInterval(3.2 * 86_400), date: now.addingTimeInterval(-60)),
        ], now: now)
        try render(PlanUsageView(usage: live).padding(14).frame(width: 380), to: dir.appendingPathComponent("plan-live.png"))
    }

    private func render<V: View>(_ view: V, to url: URL) throws {
        let host = NSHostingView(rootView: view)
        host.frame.size = host.fittingSize
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}

/// Removing a pin used to crash: the remove button read the pin through a binding while the
/// array was being mutated (Swift exclusivity violation).
@MainActor
final class SettingsViewTests: XCTestCase {
    func testRemovingPinsKeepsRendering() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ClaudeWatchTests.\(UUID().uuidString)"))
        let store = UsageStore(defaults: defaults)
        store.pinned = [
            PinnedSession(label: "one", sessionID: "11111111-1111-1111-1111-111111111111"),
            PinnedSession(label: "two", sessionID: ""),
        ]
        let host = NSHostingView(rootView: SettingsView(store: store, done: {}))
        host.frame.size = CGSize(width: 380, height: 500)
        host.layoutSubtreeIfNeeded()

        for pin in store.pinned {
            store.unpin(pin.id)
            host.layoutSubtreeIfNeeded()
        }
        XCTAssertTrue(store.pinned.isEmpty)

        store.pin(sessionID: "22222222-2222-2222-2222-222222222222", label: "three")
        store.pin(sessionID: "22222222-2222-2222-2222-222222222222", label: "dupe")
        XCTAssertEqual(store.pinned.map(\.label), ["three"])
    }
}
