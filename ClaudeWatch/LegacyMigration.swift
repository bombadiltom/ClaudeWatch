import Foundation

/// Carries settings and the scanner cache over from the app's first bundle id.
///
/// Up to 1.6 the app was `de.lorenz-unna.claudewatch`. Its settings live in that defaults domain and its
/// cache in a folder of that name. The cache matters: it holds the usage of transcripts Claude Code has
/// deleted since, which can't be read again.
enum LegacyMigration {
    static let legacyBundleID = "de.lorenz-unna.claudewatch"
    static let bundleID = "de.idiotentruppe.claudewatch"
    private static let doneKey = "migratedFromLegacyBundleID"

    static func run(defaults: UserDefaults = .standard, fileManager: FileManager = .default) {
        // The test host is the app itself: a test run must not move the real cache of a running older app.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              !defaults.bool(forKey: doneKey) else { return }
        migrateSettings(to: defaults)
        migrateCache(fileManager: fileManager)
        defaults.set(true, forKey: doneKey)
    }

    /// Copies every old setting that isn't set in the new domain yet.
    static func migrateSettings(to defaults: UserDefaults, from legacy: [String: Any]? = nil) {
        guard let legacy = legacy ?? UserDefaults.standard.persistentDomain(forName: legacyBundleID) else { return }
        for (key, value) in legacy where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
    }

    /// Moves the old cache folder, unless the new one already exists.
    static func migrateCache(fileManager: FileManager, caches: URL? = nil) {
        guard let caches = caches ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let old = caches.appendingPathComponent(legacyBundleID, isDirectory: true)
        let new = caches.appendingPathComponent(bundleID, isDirectory: true)
        guard fileManager.fileExists(atPath: old.path), !fileManager.fileExists(atPath: new.path) else { return }
        try? fileManager.moveItem(at: old, to: new)
    }
}
