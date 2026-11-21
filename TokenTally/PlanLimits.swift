import Foundation
import Security

/// One usage window of a Pro/Max plan, e.g. the 5-hour session or the weekly limit.
struct PlanLimit: Identifiable, Sendable, Equatable {
    var id: String
    var label: String
    /// 0–100
    var utilization: Double
    var resetsAt: Date?
}

enum PlanLimitsError: LocalizedError {
    case noLogin
    case expired
    case http(Int)
    case unreadable

    var errorDescription: String? {
        switch self {
        case .noLogin:
            "No Claude Code login found. Run `claude` once without Bedrock and sign in with your plan."
        case .expired:
            "The Claude Code login has expired. Run `claude` once without Bedrock to refresh it."
        case .http(let status):
            "Anthropic answered with HTTP \(status)."
        case .unreadable:
            "Couldn't read the plan usage response."
        }
    }
}

/// Reads plan utilization the way Claude Code's `/usage` does: with Claude Code's own subscription
/// login from the keychain. macOS asks once whether TokenTally may read that keychain item.
///
/// The endpoint is not a documented public API, so parsing is deliberately loose: every top-level
/// object with a numeric `utilization` becomes a row.
enum PlanLimitsClient {
    static let keychainService = "Claude Code-credentials"
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    static func fetch() async throws -> [PlanLimit] {
        let token = try accessToken()
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("TokenTally", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw http.statusCode == 401 ? PlanLimitsError.expired : PlanLimitsError.http(http.statusCode)
        }
        return try parse(data)
    }

    static func parse(_ data: Data) throws -> [PlanLimit] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PlanLimitsError.unreadable
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()

        let limits: [PlanLimit] = object.compactMap { key, value in
            guard let window = value as? [String: Any],
                  let utilization = (window["utilization"] as? NSNumber)?.doubleValue
            else { return nil }
            let reset = (window["resets_at"] as? String).flatMap { fractional.date(from: $0) ?? plain.date(from: $0) }
            return PlanLimit(id: key, label: label(for: key), utilization: utilization, resetsAt: reset)
        }
        return limits.sorted { order(of: $0.id) < order(of: $1.id) }
    }

    static func label(for key: String) -> String {
        switch key {
        case "five_hour": "5-hour session"
        case "seven_day": "Weekly, all models"
        case "seven_day_opus": "Weekly, Opus"
        case "seven_day_sonnet": "Weekly, Sonnet"
        default: key.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private static func order(of key: String) -> String {
        switch key {
        case "five_hour": "0"
        case "seven_day": "1"
        default: "2" + key
        }
    }

    private static func accessToken() throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = object["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String
        else { throw PlanLimitsError.noLogin }

        if let expiresAt = (oauth["expiresAt"] as? NSNumber)?.doubleValue,
           Date(timeIntervalSince1970: expiresAt / 1000) < .now {
            throw PlanLimitsError.expired
        }
        return token
    }
}
