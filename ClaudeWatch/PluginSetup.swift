import Foundation

/// Installs ClaudeWatch's Claude Code plugin (`plugin/claudewatch`, bundled with the app). Like the
/// status line, it saves the plan limits Claude Code gets with every response for `LiveLimitsReader`,
/// but a plugin also runs in Claude Desktop's Code tab, which has no status line.
///
/// Setting up copies the plugin into a one-plugin marketplace in `~/.claude/claudewatch-plugin/` and
/// installs it with Claude Code's own commands (`claude plugin marketplace add`, `claude plugin
/// install`), so ClaudeWatch never edits Claude Code's plugin files itself. Removing uninstalls it and
/// removes that marketplace. Someone who added the marketplace from GitHub instead keeps it.
struct PluginSetup: Sendable {
    static let marketplace = "claudewatch"
    static let pluginID = "claudewatch@claudewatch"
    static let folderName = "claudewatch-plugin"

    /// Runs `claude` with these arguments and returns its exit status and output.
    typealias Runner = @Sendable (_ arguments: [String]) throws -> (status: Int32, output: String)

    enum State: Equatable {
        case notSetUp
        case setUp
    }

    enum SetupError: LocalizedError, Equatable {
        case pluginNotBundled
        case claudeNotFound
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .pluginNotBundled: "The plugin is missing from ClaudeWatch.app. Reinstall ClaudeWatch."
            case .claudeNotFound: "ClaudeWatch couldn't find the claude command. Install Claude Code for the terminal, or add the plugin by hand as its README shows."
            case .commandFailed(let output): "Claude Code couldn't install the plugin: \(output)"
            }
        }
    }

    var claudeDirectory: URL
    var bundledPlugin: URL?
    /// Finds the `claude` command; nil if there is none.
    var runner: @Sendable () -> Runner?

    init(
        claudeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true),
        bundledPlugin: URL? = Bundle.main.url(forResource: "claudewatch", withExtension: nil),
        runner: @escaping @Sendable () -> Runner? = { ClaudeCommand.locate().map(ClaudeCommand.runner) }
    ) {
        self.claudeDirectory = claudeDirectory
        self.bundledPlugin = bundledPlugin
        self.runner = runner
    }

    var settingsURL: URL { claudeDirectory.appendingPathComponent("settings.json") }
    var marketplaceDirectory: URL { claudeDirectory.appendingPathComponent(Self.folderName, isDirectory: true) }
    var installedCopy: URL { marketplaceDirectory.appendingPathComponent("claudewatch", isDirectory: true) }

    // MARK: - State

    /// Set up when Claude Code has the plugin turned on, wherever it was installed from.
    func state() -> State {
        guard let data = try? Data(contentsOf: settingsURL),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let enabled = settings["enabledPlugins"] as? [String: Any],
              enabled[Self.pluginID] as? Bool == true
        else { return .notSetUp }
        return .setUp
    }

    // MARK: - Setting up and removing

    func install() throws {
        guard let bundledPlugin, FileManager.default.fileExists(atPath: bundledPlugin.path) else {
            throw SetupError.pluginNotBundled
        }
        guard let run = runner() else { throw SetupError.claudeNotFound }
        try copyPlugin(from: bundledPlugin)

        if marketplaces(run).keys.contains(Self.marketplace) {
            _ = try? run(["plugin", "marketplace", "update", Self.marketplace])
        } else {
            try check(run(["plugin", "marketplace", "add", marketplaceDirectory.path]))
        }
        // Installing what's installed fails, and a disabled plugin only needs turning on.
        let installed = try run(["plugin", "install", Self.pluginID])
        if state() != .setUp {
            let enabled = try run(["plugin", "enable", Self.pluginID])
            if state() != .setUp { try check(installed); try check(enabled) }
        }
    }

    func remove() throws {
        guard let run = runner() else { throw SetupError.claudeNotFound }
        if state() == .setUp {
            try check(run(["plugin", "uninstall", Self.pluginID]))
        }
        // Only our own marketplace: one added from GitHub stays.
        if marketplaces(run)[Self.marketplace] == marketplaceDirectory.standardizedFileURL.path {
            try check(run(["plugin", "marketplace", "remove", Self.marketplace]))
        }
        if FileManager.default.fileExists(atPath: marketplaceDirectory.path) {
            try FileManager.default.removeItem(at: marketplaceDirectory)
        }
    }

    /// After an update, brings the installed plugin up to the bundled version. Only if it's set up
    /// from ClaudeWatch's own marketplace. Runs `claude`, so call it off the main thread.
    func updateIfSetUp() {
        guard state() == .setUp, let bundledPlugin,
              FileManager.default.fileExists(atPath: installedCopy.path),
              let bundled = Self.version(of: bundledPlugin),
              bundled != Self.version(of: installedCopy),
              let run = runner()
        else { return }
        try? copyPlugin(from: bundledPlugin)
        _ = try? run(["plugin", "marketplace", "update", Self.marketplace])
        _ = try? run(["plugin", "update", Self.pluginID])
    }

    // MARK: - Helpers

    /// The plugin in a marketplace of its own, so `claude plugin marketplace add` can take the folder.
    private func copyPlugin(from source: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: marketplaceDirectory.path) {
            try fileManager.removeItem(at: marketplaceDirectory)
        }
        let manifests = marketplaceDirectory.appendingPathComponent(".claude-plugin", isDirectory: true)
        try fileManager.createDirectory(at: manifests, withIntermediateDirectories: true)
        try fileManager.copyItem(at: source, to: installedCopy)
        let manifest = """
        {
          "name": "\(Self.marketplace)",
          "owner": { "name": "ClaudeWatch" },
          "plugins": [{ "name": "claudewatch", "source": "./claudewatch" }]
        }

        """
        try Data(manifest.utf8).write(to: manifests.appendingPathComponent("marketplace.json"), options: .atomic)
    }

    /// Marketplace names, each with its folder if it's a local one.
    private func marketplaces(_ run: Runner) -> [String: String] {
        guard let result = try? run(["plugin", "marketplace", "list", "--json"]), result.status == 0,
              let start = result.output.firstIndex(of: "["),
              let list = try? JSONSerialization.jsonObject(with: Data(result.output[start...].utf8)) as? [[String: Any]]
        else { return [:] }
        var names: [String: String] = [:]
        for entry in list {
            guard let name = entry["name"] as? String else { continue }
            names[name] = (entry["path"] as? String).map { URL(fileURLWithPath: $0).standardizedFileURL.path } ?? ""
        }
        return names
    }

    private func check(_ result: (status: Int32, output: String)) throws {
        guard result.status == 0 else {
            let message = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SetupError.commandFailed(message.isEmpty ? "exit status \(result.status)" : String(message.suffix(300)))
        }
    }

    static func version(of plugin: URL) -> String? {
        guard let data = try? Data(contentsOf: plugin.appendingPathComponent(".claude-plugin/plugin.json")),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return manifest["version"] as? String
    }
}

/// The `claude` command. An app started from Finder doesn't get the shell's `PATH`, so this looks in
/// the usual install locations first and then asks the login shell.
enum ClaudeCommand {
    static func locate(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let candidates = [
            home.appendingPathComponent(".local/bin/claude"),
            home.appendingPathComponent(".claude/local/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude"),
        ]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
            return found
        }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard let result = try? run(URL(fileURLWithPath: shell), ["-l", "-c", "command -v claude"], timeout: 10),
              result.status == 0
        else { return nil }
        let path = result.output.split(separator: "\n").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return path.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    static func runner(_ claude: URL) -> PluginSetup.Runner {
        { arguments in try run(claude, arguments, timeout: 120) }
    }

    /// Runs a command with stdin closed and returns its exit status with stdout and stderr together.
    static func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        // Read while it runs, so a full pipe can't block it.
        let output = Output()
        let read = DispatchSemaphore(value: 0)
        let handle = pipe.fileHandleForReading
        DispatchQueue.global().async {
            output.data = handle.readDataToEndOfFile()
            read.signal()
        }
        try process.run()
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            finished.wait()
        }
        // A child it left running may hold the pipe open.
        let data = read.wait(timeout: .now() + 5) == .success ? output.data : Data()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private final class Output: @unchecked Sendable {
        var data = Data()
    }
}
