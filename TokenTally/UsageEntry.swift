import Foundation

/// Where a request was billed, told apart by the API message id prefix.
enum Backend: String, Codable, Sendable {
    /// Amazon Bedrock (`msg_bdrk_…`): billed to your AWS account.
    case bedrock
    /// Google Vertex AI (`msg_vrtx_…`): billed to your Google Cloud account.
    case vertex
    /// Anthropic (`msg_01…`): your Pro/Max plan or an API key.
    case anthropic

    init(messageID: String) {
        if messageID.hasPrefix("msg_bdrk_") {
            self = .bedrock
        } else if messageID.hasPrefix("msg_vrtx_") {
            self = .vertex
        } else {
            self = .anthropic
        }
    }

    /// True when the cost is an actual cloud bill, not an API-equivalent value of plan usage.
    var isCloudBilled: Bool { self != .anthropic }
}

/// One API response as recorded in a Claude Code transcript.
struct UsageEntry: Codable, Sendable, Equatable {
    var messageID: String
    var timestamp: Date
    var sessionID: String
    var project: String
    /// `cli`, `sdk-cli`, `claude-desktop`, …
    var entrypoint: String
    var model: String
    var backend: Backend
    var input: Int
    var output: Int
    var cacheRead: Int
    var cacheWrite5m: Int
    var cacheWrite1h: Int
    var fast: Bool

    var totalTokens: Int { input + output + cacheRead + cacheWrite5m + cacheWrite1h }
    var promptTokens: Int { input + cacheRead + cacheWrite5m + cacheWrite1h }
    var isDesktop: Bool { entrypoint == "claude-desktop" }
}
