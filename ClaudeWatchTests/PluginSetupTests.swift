import XCTest
@testable import ClaudeWatch

/// A temporary folder stands in for `~/.claude`, and a fake `claude` command for Claude Code: it
/// records the commands and turns the plugin on or off in `settings.json` as Claude Code would. The
/// plugin comes from the app bundle (the test host), which also checks that it's bundled.
final class PluginSetupTests: XCTestCase {
    private var directory: URL!
    private var claude: FakeClaude!
    private var setup: PluginSetup!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        claude = FakeClaude(settings: directory.appendingPathComponent("settings.json"))
        let claude = claude!
        setup = PluginSetup(claudeDirectory: directory, runner: { claude.run })
        XCTAssertNotNil(setup.bundledPlugin, "the plugin must be bundled with the app")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
    }

    func testSetsUpThroughClaudeCode() throws {
        XCTAssertEqual(setup.state(), .notSetUp)
        try setup.install()

        XCTAssertEqual(setup.state(), .setUp)
        XCTAssertEqual(claude.commands, [
            "plugin marketplace list --json",
            "plugin marketplace add \(setup.marketplaceDirectory.path)",
            "plugin install claudewatch@claudewatch",
        ])
        let hooks = setup.installedCopy.appendingPathComponent("hooks/register.ts")
        XCTAssertTrue(FileManager.default.fileExists(atPath: hooks.path))
        let manifest = try String(contentsOf: setup.marketplaceDirectory.appendingPathComponent(".claude-plugin/marketplace.json"), encoding: .utf8)
        XCTAssertTrue(manifest.contains(#""source": "./claudewatch""#))
        XCTAssertNotNil(PluginSetup.version(of: setup.installedCopy))
    }

    func testTurnsOnAPluginThatIsInstalledButOff() throws {
        claude.marketplaces = ["claudewatch": setup.marketplaceDirectory.path]
        claude.installed = true
        try setup.install()

        XCTAssertEqual(setup.state(), .setUp)
        XCTAssertEqual(claude.commands.suffix(3), [
            "plugin marketplace update claudewatch",
            "plugin install claudewatch@claudewatch",
            "plugin enable claudewatch@claudewatch",
        ])
    }

    func testReportsWhatClaudeCodeSaid() {
        claude.failInstall = "Plugin not found"
        XCTAssertThrowsError(try setup.install()) { error in
            XCTAssertEqual(error as? PluginSetup.SetupError, .commandFailed("Plugin not found"))
        }
        XCTAssertEqual(setup.state(), .notSetUp)
    }

    func testWithoutClaudeCommand() {
        setup.runner = { nil }
        XCTAssertThrowsError(try setup.install()) { error in
            XCTAssertEqual(error as? PluginSetup.SetupError, .claudeNotFound)
        }
    }

    func testRemoveUndoesSetUp() throws {
        try setup.install()
        try setup.remove()

        XCTAssertEqual(setup.state(), .notSetUp)
        XCTAssertEqual(claude.commands.suffix(3), [
            "plugin uninstall claudewatch@claudewatch",
            "plugin marketplace list --json",
            "plugin marketplace remove claudewatch",
        ])
        XCTAssertFalse(FileManager.default.fileExists(atPath: setup.marketplaceDirectory.path))
    }

    func testRemoveKeepsAMarketplaceAddedFromGitHub() throws {
        claude.marketplaces = ["claudewatch": ""]
        claude.installed = true
        claude.enable()
        try setup.remove()

        XCTAssertEqual(setup.state(), .notSetUp)
        XCTAssertFalse(claude.commands.contains("plugin marketplace remove claudewatch"))
        XCTAssertEqual(claude.marketplaces.keys.sorted(), ["claudewatch"])
    }

    func testUpdatesAnOlderCopyAfterAnUpdate() throws {
        try setup.install()
        let manifest = setup.installedCopy.appendingPathComponent(".claude-plugin/plugin.json")
        try #"{ "name": "claudewatch", "version": "0.9.0" }"#.write(to: manifest, atomically: true, encoding: .utf8)
        claude.commands = []

        setup.updateIfSetUp()
        XCTAssertEqual(claude.commands, ["plugin marketplace update claudewatch", "plugin update claudewatch@claudewatch"])
        XCTAssertEqual(PluginSetup.version(of: setup.installedCopy), PluginSetup.version(of: try XCTUnwrap(setup.bundledPlugin)))

        claude.commands = []
        setup.updateIfSetUp()
        XCTAssertEqual(claude.commands, [], "nothing to do when the copy is current")
    }

    /// Opt-in, because it changes your real `~/.claude`: sets up, removes and sets up again with the
    /// real claude command, leaving the plugin installed. Run with
    /// `TEST_RUNNER_CLAUDEWATCH_REAL_PLUGIN=1 xcodebuild … test -only-testing:ClaudeWatchTests/PluginSetupTests/testWithRealClaudeCode`.
    func testWithRealClaudeCode() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CLAUDEWATCH_REAL_PLUGIN"] != nil, "changes ~/.claude")
        let real = PluginSetup()
        XCTAssertNotNil(ClaudeCommand.locate())
        try real.install()
        XCTAssertEqual(real.state(), .setUp)
        try real.remove()
        XCTAssertEqual(real.state(), .notSetUp)
        XCTAssertFalse(FileManager.default.fileExists(atPath: real.marketplaceDirectory.path))
        try real.install()
        XCTAssertEqual(real.state(), .setUp)
    }
}

/// Claude Code's plugin commands, as far as `PluginSetup` uses them.
private final class FakeClaude: @unchecked Sendable {
    let settings: URL
    var commands: [String] = []
    var marketplaces: [String: String] = [:]
    var installed = false
    var failInstall: String?

    init(settings: URL) { self.settings = settings }

    func enable(_ on: Bool = true) {
        let text = on ? #"{ "enabledPlugins": { "claudewatch@claudewatch": true } }"# : #"{ "enabledPlugins": {} }"#
        try? text.write(to: settings, atomically: true, encoding: .utf8)
    }

    func run(_ arguments: [String]) throws -> (status: Int32, output: String) {
        commands.append(arguments.joined(separator: " "))
        switch Array(arguments.dropFirst()) {
        case ["marketplace", "list", "--json"]:
            let list = marketplaces.map { name, path in
                path.isEmpty ? ["name": name, "source": "github"] : ["name": name, "source": "directory", "path": path]
            }
            let data = try JSONSerialization.data(withJSONObject: list)
            return (0, String(decoding: data, as: UTF8.self))
        case let command where command.starts(with: ["marketplace", "add"]):
            marketplaces["claudewatch"] = command[2]
            return (0, "Successfully added marketplace: claudewatch")
        case ["marketplace", "remove", "claudewatch"]:
            marketplaces["claudewatch"] = nil
            return (0, "")
        case ["install", "claudewatch@claudewatch"]:
            if let failInstall { return (1, failInstall + "\n") }
            if installed { return (1, "Plugin is already installed") }
            installed = true
            enable()
            return (0, "Successfully installed plugin")
        case ["enable", "claudewatch@claudewatch"]:
            guard installed else { return (1, "Plugin is not installed") }
            enable()
            return (0, "")
        case ["uninstall", "claudewatch@claudewatch"]:
            installed = false
            enable(false)
            return (0, "")
        default:
            return (0, "")
        }
    }
}
