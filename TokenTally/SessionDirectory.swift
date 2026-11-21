import Darwin
import Foundation

/// A Claude Code process that is running right now (from `~/.claude/sessions/<pid>.json`).
struct LiveSession: Sendable, Equatable {
    var pid: Int32
    var sessionID: String
    var name: String?
    /// `busy`, `idle`, `waiting`, … as Claude Code reports it.
    var status: String?
    var cwd: String?
    var entrypoint: String?
}

enum SessionDirectory {
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// Sessions whose process is still alive.
    static func liveSessions() -> [LiveSession] {
        let dir = home.appendingPathComponent(".claude/sessions", isDirectory: true)
        guard let urls = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        return urls.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = (object["pid"] as? NSNumber)?.int32Value,
                  let session = object["sessionId"] as? String,
                  isAlive(pid)
            else { return nil }
            return LiveSession(
                pid: pid,
                sessionID: session,
                name: object["name"] as? String,
                status: object["status"] as? String,
                cwd: object["cwd"] as? String,
                entrypoint: object["entrypoint"] as? String
            )
        }
    }

    /// Titles of Claude Desktop Code-tab sessions, keyed by the Claude Code session id.
    static func desktopTitles() -> [String: String] {
        let dir = home.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else {
            return [:]
        }
        var titles: [String: String] = [:]
        for case let url as URL in enumerator
        where url.pathExtension == "json" && url.lastPathComponent.hasPrefix("local_") {
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let session = object["cliSessionId"] as? String,
                  let title = object["title"] as? String, !title.isEmpty
            else { continue }
            titles[session] = title
        }
        return titles
    }

    private static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
