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
