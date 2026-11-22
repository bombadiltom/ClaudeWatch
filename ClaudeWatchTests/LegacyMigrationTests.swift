import XCTest
@testable import ClaudeWatch

final class LegacyMigrationTests: XCTestCase {
    func testCopiesOnlySettingsThatAreNotSetYet() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ClaudeWatchTests.\(UUID().uuidString)"))
        defaults.set(5.0, forKey: "cloudSurchargePercent")

        LegacyMigration.migrateSettings(to: defaults, from: ["cloudSurchargePercent": 10.0, "planAlertPercent": 70])

        XCTAssertEqual(defaults.double(forKey: "cloudSurchargePercent"), 5)
        XCTAssertEqual(defaults.integer(forKey: "planAlertPercent"), 70)
    }

    func testMovesCacheOnlyWhenTheNewOneIsMissing() throws {
        let fm = FileManager.default
        let caches = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: caches) }
        let old = caches.appendingPathComponent(LegacyMigration.legacyBundleID, isDirectory: true)
        let new = caches.appendingPathComponent(LegacyMigration.bundleID, isDirectory: true)
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: old.appendingPathComponent("transcripts.json"))

        LegacyMigration.migrateCache(fileManager: fm, caches: caches)

        XCTAssertFalse(fm.fileExists(atPath: old.path))
        XCTAssertEqual(try String(contentsOf: new.appendingPathComponent("transcripts.json"), encoding: .utf8), "old")

        // A second old folder (say, 1.6 started again) must not replace the migrated cache.
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        LegacyMigration.migrateCache(fileManager: fm, caches: caches)
        XCTAssertTrue(fm.fileExists(atPath: old.path))
        XCTAssertEqual(try String(contentsOf: new.appendingPathComponent("transcripts.json"), encoding: .utf8), "old")
    }
}
