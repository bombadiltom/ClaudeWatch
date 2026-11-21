import Foundation

/// A Claude Code session you start with a fixed `--session-id`, shown as its own row.
struct PinnedSession: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var label: String
    var sessionID: String

    /// A session belongs to this pin if its id matches, or if its title (`-n <name>`) equals the label.
    /// The title match keeps a pin working when the id was never applied, e.g. a typo in the shell config.
    func matches(sessionID other: String, title: String?) -> Bool {
        if !sessionID.isEmpty, other.caseInsensitiveCompare(sessionID) == .orderedSame { return true }
        if let title, !label.isEmpty, title == label { return true }
        return false
    }
}

/// Finds pinned sessions in a shell config such as `~/.zshrc`.
///
/// It looks for variables holding a UUID (`ACME_MAIN_ID=11111111-…`). If a call like
/// `_claude_pinned acme-main "$ACME_MAIN_ID"` passes that variable after a name, the name
/// becomes the label; otherwise the label comes from the variable name (`acme-main`).
enum ShellConfigImporter {
    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zshrc")
    }

    static func pinnedSessions(in text: String) -> [PinnedSession] {
        let assignment = try! NSRegularExpression(
            pattern: #"^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=["']?([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})["']?"#,
            options: [.anchorsMatchLines]
        )
        // `<command> <name> "$VAR"` or `<command> <name> ${VAR}`
        let call = try! NSRegularExpression(
            pattern: #"\s([A-Za-z0-9][A-Za-z0-9._-]*)\s+"?\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?"?"#
        )
        let range = NSRange(text.startIndex..., in: text)

        var namesByVariable: [String: String] = [:]
        for match in call.matches(in: text, range: range) {
            guard let name = Range(match.range(at: 1), in: text), let variable = Range(match.range(at: 2), in: text) else {
                continue
            }
            namesByVariable[String(text[variable])] = String(text[name])
        }

        var result: [PinnedSession] = []
        var seenIDs = Set<String>()
        for match in assignment.matches(in: text, range: range) {
            guard let variable = Range(match.range(at: 1), in: text), let uuid = Range(match.range(at: 2), in: text) else {
                continue
            }
            let name = String(text[variable])
            let id = text[uuid].lowercased()
            guard seenIDs.insert(id).inserted else { continue }
            let label = namesByVariable[name] ?? defaultLabel(forVariable: name)
            result.append(PinnedSession(label: label, sessionID: id))
        }
        return result
    }

    static func pinnedSessions(from url: URL = defaultURL) -> [PinnedSession] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return pinnedSessions(in: text)
    }

    /// `ACME_MAIN_ID` → `acme-main`
    static func defaultLabel(forVariable name: String) -> String {
        var base = name
        for suffix in ["_SESSION_ID", "_ID"] where base.uppercased().hasSuffix(suffix) {
            base = String(base.dropLast(suffix.count))
            break
        }
        return base.lowercased().replacingOccurrences(of: "_", with: "-")
    }
}
