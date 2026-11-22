import XCTest
@testable import ClaudeWatch

/// Everything runs in a temporary folder standing in for `~/.claude`. The script comes from the app
/// bundle (the test host), which also checks that it's bundled.
final class StatusLineSetupTests: XCTestCase {
    private var directory: URL!
    private var setup: StatusLineSetup!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent(".claude")
        setup = StatusLineSetup(claudeDirectory: directory)
        XCTAssertNotNil(setup.bundledScript, "the script must be bundled with the app")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
    }

    private func writeSettings(_ text: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try text.write(to: setup.settingsURL, atomically: true, encoding: .utf8)
    }

    private func settings() throws -> String { try String(contentsOf: setup.settingsURL, encoding: .utf8) }

    func testSetsUpWithoutSettingsFile() throws {
        XCTAssertEqual(setup.state(), .notSetUp)
        try setup.install()

        XCTAssertEqual(try settings(), """
        {
          "statusLine": {
            "type": "command",
            "command": "~/.claude/claudewatch-statusline.sh"
          }
        }

        """)
        XCTAssertEqual(try Data(contentsOf: setup.scriptURL), try Data(contentsOf: XCTUnwrap(setup.bundledScript)))
        let permissions = try FileManager.default.attributesOfItem(atPath: setup.scriptURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o755)
        XCTAssertEqual(setup.state(), .setUp(wrapping: nil))

        try setup.remove()
        XCTAssertEqual(try settings(), "{}\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: setup.scriptURL.path))
        XCTAssertEqual(setup.state(), .notSetUp)
    }

    func testKeepsTheRestOfTheFileAsItWas() throws {
        // Key order, nested objects, braces and escaped quotes inside strings, a key after an array.
        let original = """
        {
          "cleanupPeriodDays": 365,
          "hooks": {
            "Notification": [{ "hooks": [{ "type": "command", "command": "echo \\"}\\" >/dev/null" }] }]
          },
          "enabledPlugins": { "acme@globex": true },
          "permissions": ["Bash(ls:*)", "Read(~/{a,b}/**)"]
        }

        """
        try writeSettings(original)
        try setup.install()
        XCTAssertEqual(try settings(), original.replacingOccurrences(of: """
          "permissions": ["Bash(ls:*)", "Read(~/{a,b}/**)"]
        """, with: """
          "permissions": ["Bash(ls:*)", "Read(~/{a,b}/**)"],
          "statusLine": {
            "type": "command",
            "command": "~/.claude/claudewatch-statusline.sh"
          }
        """))

        try setup.remove()
        XCTAssertEqual(try settings(), original)
    }

    func testKeepsTheUsersOwnStatusLine() throws {
        let theirs = #"input=$(cat); echo "$input" | jq -r '.model.display_name'"#
        let original = """
        {
            "statusLine": {"type": "command", "command": \(JSONText.encode(theirs)), "padding": 0},
            "model": "opus"
        }
        """
        try writeSettings(original)
        XCTAssertEqual(setup.state(), .otherStatusLine(theirs))

        try setup.install()
        let installed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(try settings().utf8)) as? [String: Any]
        )["statusLine"] as? [String: Any]
        XCTAssertEqual(installed?["command"] as? String, StatusLineSetup.command + " " + StatusLineSetup.shellQuoted(theirs))
        XCTAssertEqual(installed?["padding"] as? Int, 0)
        XCTAssertEqual(setup.state(), .setUp(wrapping: theirs))

        // Setting up twice changes nothing.
        let once = try settings()
        try setup.install()
        XCTAssertEqual(try settings(), once)

        try setup.remove()
        XCTAssertEqual(try settings(), original)
        XCTAssertEqual(setup.state(), .otherStatusLine(theirs))
    }

    func testLeavesUnreadableSettingsAlone() throws {
        let broken = "{ \"model\": \"opus\", // a comment\n}"
        try writeSettings(broken)
        XCTAssertEqual(setup.state(), .unreadable)
        XCTAssertThrowsError(try setup.install()) { XCTAssertEqual($0 as? StatusLineSetup.SetupError, .unreadableSettings) }
        XCTAssertEqual(try settings(), broken)
        XCTAssertFalse(FileManager.default.fileExists(atPath: setup.scriptURL.path))
    }

    func testRepairsAMissingScript() throws {
        // Set up by hand from the README, then the script went missing.
        let original = #"{"statusLine": {"type": "command", "command": "~/.claude/claudewatch-statusline.sh"}}"#
        try writeSettings(original)
        XCTAssertEqual(setup.state(), .notSetUp)
        try setup.install()
        XCTAssertEqual(try settings(), original)
        XCTAssertEqual(setup.state(), .setUp(wrapping: nil))
    }

    func testEditsOneLineObjects() throws {
        let text = #"{"a": 1, "b": [1, {"c": "}"}], "d": "x"}"#
        XCTAssertEqual(try JSONText.setting("e", to: "true", in: text), #"{"a": 1, "b": [1, {"c": "}"}], "d": "x", "e": true}"#)
        XCTAssertEqual(try JSONText.setting("b", to: nil, in: text), #"{"a": 1, "d": "x"}"#)
        XCTAssertEqual(try JSONText.setting("d", to: nil, in: text), #"{"a": 1, "b": [1, {"c": "}"}]}"#)
        XCTAssertEqual(try JSONText.setting("a", to: "2", in: text), #"{"a": 2, "b": [1, {"c": "}"}], "d": "x"}"#)
    }

    func testQuotesCommandsForTheShell() {
        for command in ["echo hi", "echo 'it'\\''s'", "a'b", "''", "x 'y' z"] {
            let wrapped = StatusLineSetup.command + " " + StatusLineSetup.shellQuoted(command)
            XCTAssertEqual(StatusLineSetup.wrappedCommand(in: wrapped), command)
        }
        XCTAssertNil(StatusLineSetup.wrappedCommand(in: StatusLineSetup.command))
    }
}
