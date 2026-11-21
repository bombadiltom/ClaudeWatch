import AppKit
import SwiftUI
import XCTest
@testable import TokenTally

/// Renders the menu with your real data to a PNG, for looking at the layout without clicking the
/// menu bar. Skipped unless `TOKENTALLY_SNAPSHOT_DIR` is set:
///
///     TEST_RUNNER_TOKENTALLY_SNAPSHOT_DIR=/tmp/shots xcodebuild test -scheme TokenTally \
///       -only-testing:TokenTallyTests/SnapshotTests
@MainActor
final class SnapshotTests: XCTestCase {
    func testRenderMenu() async throws {
        guard let path = ProcessInfo.processInfo.environment["TOKENTALLY_SNAPSHOT_DIR"] else {
            throw XCTSkip("set TOKENTALLY_SNAPSHOT_DIR to render the menu")
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
        }
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
