import Foundation

/// Sets up ClaudeWatch's status line in Claude Code (`scripts/claudewatch-statusline.sh`, bundled with
/// the app), which hands ClaudeWatch the live plan limits (see `LiveLimitsReader`).
///
/// Setting up copies the script to `~/.claude/` and points `statusLine` in `~/.claude/settings.json` at
/// it. If you already have a status line, it stays: the script gets your command as its argument,
/// runs it with the same input and prints its output, and any other `statusLine` fields are kept.
/// Removing undoes both. Only the `statusLine` entry of `settings.json` is touched; the rest of the
/// file keeps its text, order and formatting.
struct StatusLineSetup {
    static let scriptName = "claudewatch-statusline.sh"
    /// The command as it goes into `settings.json`. Claude Code runs it in a shell, which expands `~`.
    static let command = "~/.claude/\(scriptName)"

    enum State: Equatable {
        case notSetUp
        /// `wrapping` is the user's own status line command that keeps running.
        case setUp(wrapping: String?)
        /// The user's own status line. Setting up keeps it.
        case otherStatusLine(String)
        /// `settings.json` isn't valid JSON (or its `statusLine` isn't a command), so it's left alone.
        case unreadable
    }

    enum SetupError: LocalizedError, Equatable {
        case unreadableSettings
        case unsupportedStatusLine
        case scriptNotBundled
        case editFailed

        var errorDescription: String? {
            switch self {
            case .unreadableSettings: "~/.claude/settings.json isn't valid JSON, so ClaudeWatch left it alone."
            case .unsupportedStatusLine: "Your status line in ~/.claude/settings.json has no command to keep, so ClaudeWatch left it alone."
            case .scriptNotBundled: "The status line script is missing from ClaudeWatch.app. Reinstall ClaudeWatch."
            case .editFailed: "ClaudeWatch couldn't edit ~/.claude/settings.json safely, so it left it alone."
            }
        }
    }

    var claudeDirectory: URL
    var bundledScript: URL?

    init(
        claudeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true),
        bundledScript: URL? = Bundle.main.url(forResource: "claudewatch-statusline", withExtension: "sh")
    ) {
        self.claudeDirectory = claudeDirectory
        self.bundledScript = bundledScript
    }

    var settingsURL: URL { claudeDirectory.appendingPathComponent("settings.json") }
    var scriptURL: URL { claudeDirectory.appendingPathComponent(Self.scriptName) }

    // MARK: - State

    func state() -> State {
        guard let text = try? String(contentsOf: settingsURL, encoding: .utf8) else { return .notSetUp }
        guard let settings = Self.object(text) else { return .unreadable }
        guard let statusLine = settings["statusLine"] else { return .notSetUp }
        guard let command = (statusLine as? [String: Any])?["command"] as? String else { return .unreadable }
        guard isOurs(command) else { return .otherStatusLine(command) }
        // Pointing at a script that's gone: setting up again copies it.
        guard FileManager.default.fileExists(atPath: scriptURL.path) else { return .notSetUp }
        return .setUp(wrapping: Self.wrappedCommand(in: command))
    }

    /// Our command, alone or wrapping another one; also the absolute path someone may have typed.
    func isOurs(_ command: String) -> Bool {
        [Self.command, scriptURL.path].contains { command == $0 || command.hasPrefix($0 + " ") }
    }

    // MARK: - Setting up and removing

    func install() throws {
        guard let bundledScript, FileManager.default.fileExists(atPath: bundledScript.path) else {
            throw SetupError.scriptNotBundled
        }
        let exists = FileManager.default.fileExists(atPath: settingsURL.path)
        let text = exists ? try String(contentsOf: settingsURL, encoding: .utf8) : "{}\n"
        guard var settings = Self.object(text) else { throw SetupError.unreadableSettings }

        let edited: String
        if let existing = settings["statusLine"] {
            guard var statusLine = existing as? [String: Any], let command = statusLine["command"] as? String else {
                throw SetupError.unsupportedStatusLine
            }
            if isOurs(command) { return try copyScript(from: bundledScript) }
            let wrapping = Self.command + " " + Self.shellQuoted(command)
            statusLine["command"] = wrapping
            settings["statusLine"] = statusLine
            edited = try JSONText.editingNested("statusLine", member: "command", to: JSONText.encode(wrapping), in: text)
        } else {
            settings["statusLine"] = ["type": "command", "command": Self.command]
            let indent = JSONText.indent(of: text)
            let value = indent.isEmpty
                ? #"{"type": "command", "command": \#(JSONText.encode(Self.command))}"#
                : "{\n\(indent)\(indent)\"type\": \"command\",\n\(indent)\(indent)\"command\": \(JSONText.encode(Self.command))\n\(indent)}"
            edited = try JSONText.setting("statusLine", to: value, in: text)
        }
        // The script before the settings, so the status line never points at a missing file.
        try copyScript(from: bundledScript)
        try write(edited, expecting: settings)
    }

    func remove() throws {
        if let text = try? String(contentsOf: settingsURL, encoding: .utf8) {
            guard var settings = Self.object(text) else { throw SetupError.unreadableSettings }
            if var statusLine = settings["statusLine"] as? [String: Any],
               let command = statusLine["command"] as? String, isOurs(command) {
                let edited: String
                if let original = Self.wrappedCommand(in: command) {
                    statusLine["command"] = original
                    settings["statusLine"] = statusLine
                    edited = try JSONText.editingNested("statusLine", member: "command", to: JSONText.encode(original), in: text)
                } else {
                    settings["statusLine"] = nil
                    edited = try JSONText.setting("statusLine", to: nil, in: text)
                }
                try write(edited, expecting: settings)
            }
        }
        if FileManager.default.fileExists(atPath: scriptURL.path) {
            try FileManager.default.removeItem(at: scriptURL)
        }
    }

    /// After an update, brings the installed script up to the bundled version. Only if it's set up.
    func updateScriptIfSetUp() {
        guard case .setUp = state(), let bundledScript,
              let bundled = try? Data(contentsOf: bundledScript),
              (try? Data(contentsOf: scriptURL)) != bundled
        else { return }
        try? copyScript(from: bundledScript)
    }

    // MARK: - Helpers

    private func copyScript(from source: URL) throws {
        try FileManager.default.createDirectory(at: claudeDirectory, withIntermediateDirectories: true)
        let data = try Data(contentsOf: source)
        try data.write(to: scriptURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }

    /// Writes only if the edited text parses to exactly the settings intended.
    private func write(_ text: String, expecting settings: [String: Any]) throws {
        guard let result = Self.object(text), NSDictionary(dictionary: result).isEqual(to: settings) else {
            throw SetupError.editFailed
        }
        try Data(text.utf8).write(to: settingsURL, options: .atomic)
    }

    private static func object(_ text: String) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
    }

    /// `'it'\''s'` for `it's`: safe as one argument in any POSIX shell.
    static func shellQuoted(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// The user's command in `<our command> '<their command>'`, or nil if ours stands alone.
    static func wrappedCommand(in command: String) -> String? {
        guard let space = command.firstIndex(of: " ") else { return nil }
        let argument = String(command[command.index(after: space)...])
        guard argument.count >= 2, argument.hasPrefix("'"), argument.hasSuffix("'") else { return nil }
        let original = String(argument.dropFirst().dropLast()).replacingOccurrences(of: #"'\''"#, with: "'")
        return shellQuoted(original) == argument ? original : nil
    }
}

/// Edits one member of a JSON object in place, keeping the rest of the text exactly as it was. A
/// decode/encode round trip would reorder the keys and reformat the whole file.
///
/// The text must be valid JSON; callers check that first, so the scanner can stay simple.
enum JSONText {
    struct Member {
        var key: String
        var start: Int
        var valueStart: Int
        var valueEnd: Int
    }

    struct Object {
        var open: Int
        var close: Int
        var members: [Member]
    }

    enum ScanError: Error { case notAnObject }

    /// Sets `key` to the JSON text `value`, adding it as the last member if needed, or removes it.
    static func setting(_ key: String, to value: String?, in text: String) throws -> String {
        var bytes = Array(text.utf8)
        let object = try scanObject(bytes)
        if let index = object.members.firstIndex(where: { $0.key == key }) {
            let member = object.members[index]
            if let value {
                bytes.replaceSubrange(member.valueStart..<member.valueEnd, with: Array(value.utf8))
            } else if index + 1 < object.members.count {
                bytes.removeSubrange(member.start..<object.members[index + 1].start)
            } else if index > 0 {
                bytes.removeSubrange(object.members[index - 1].valueEnd..<member.valueEnd)
            } else {
                bytes.removeSubrange(object.open + 1..<object.close)
            }
        } else if let value {
            let entry = encode(key) + ": " + value
            if let last = object.members.last {
                let separator = indent(of: text).isEmpty ? ", " : ",\n" + indent(of: text)
                bytes.insert(contentsOf: Array((separator + entry).utf8), at: last.valueEnd)
            } else {
                bytes.replaceSubrange(object.open + 1..<object.close, with: Array("\n  \(entry)\n".utf8))
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Sets one member of the object that is the value of `key`.
    static func editingNested(_ key: String, member: String, to value: String?, in text: String) throws -> String {
        let bytes = Array(text.utf8)
        guard let outer = try scanObject(bytes).members.first(where: { $0.key == key }) else { throw ScanError.notAnObject }
        let inner = String(decoding: bytes[outer.valueStart..<outer.valueEnd], as: UTF8.self)
        return try setting(key, to: setting(member, to: value, in: inner), in: text)
    }

    /// The whitespace before the object's first member on its line: "  " for a file indented by two.
    /// Empty for a one-line object.
    static func indent(of text: String) -> String {
        let bytes = Array(text.utf8)
        guard let first = (try? scanObject(bytes))?.members.first else { return "  " }
        var start = first.start
        while start > 0, bytes[start - 1] == 0x20 || bytes[start - 1] == 0x09 { start -= 1 }
        guard start > 0, bytes[start - 1] == 0x0A else { return "" }
        return String(decoding: bytes[start..<first.start], as: UTF8.self)
    }

    /// A JSON string literal, without escaping `/`.
    static func encode(_ string: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return (try? encoder.encode(string)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
    }

    // MARK: Scanning

    static func scanObject(_ b: [UInt8]) throws -> Object {
        var i = 0
        skipWhitespace(b, &i)
        guard i < b.count, b[i] == UInt8(ascii: "{") else { throw ScanError.notAnObject }
        let open = i
        i += 1
        var members: [Member] = []
        while true {
            skipWhitespace(b, &i)
            guard i < b.count else { throw ScanError.notAnObject }
            if b[i] == UInt8(ascii: "}") { return Object(open: open, close: i, members: members) }
            let start = i
            guard b[i] == UInt8(ascii: "\"") else { throw ScanError.notAnObject }
            skipString(b, &i)
            let key = (try? JSONSerialization.jsonObject(with: Data(b[start..<i]), options: .fragmentsAllowed)) as? String
            skipWhitespace(b, &i)
            guard let key, i < b.count, b[i] == UInt8(ascii: ":") else { throw ScanError.notAnObject }
            i += 1
            skipWhitespace(b, &i)
            let valueStart = i
            skipValue(b, &i)
            members.append(Member(key: key, start: start, valueStart: valueStart, valueEnd: i))
            skipWhitespace(b, &i)
            guard i < b.count else { throw ScanError.notAnObject }
            if b[i] == UInt8(ascii: ",") { i += 1; continue }
            guard b[i] == UInt8(ascii: "}") else { throw ScanError.notAnObject }
            return Object(open: open, close: i, members: members)
        }
    }

    private static func skipWhitespace(_ b: [UInt8], _ i: inout Int) {
        while i < b.count, [0x20, 0x09, 0x0A, 0x0D].contains(b[i]) { i += 1 }
    }

    /// From an opening quote to just past the closing one.
    private static func skipString(_ b: [UInt8], _ i: inout Int) {
        i += 1
        while i < b.count {
            if b[i] == UInt8(ascii: "\\") { i += 2; continue }
            i += 1
            if b[i - 1] == UInt8(ascii: "\"") { return }
        }
    }

    private static func skipValue(_ b: [UInt8], _ i: inout Int) {
        guard i < b.count else { return }
        switch b[i] {
        case UInt8(ascii: "\""):
            skipString(b, &i)
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            var depth = 0
            while i < b.count {
                switch b[i] {
                case UInt8(ascii: "\""):
                    skipString(b, &i)
                    continue
                case UInt8(ascii: "{"), UInt8(ascii: "["):
                    depth += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    depth -= 1
                default:
                    break
                }
                i += 1
                if depth == 0 { return }
            }
        default:
            let ends: Set<UInt8> = [UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]"), 0x20, 0x09, 0x0A, 0x0D]
            while i < b.count, !ends.contains(b[i]) { i += 1 }
        }
    }
}
