import Foundation

/// Asks Google whether a Gemini API key is usable, so a typo or a revoked
/// key is caught at the moment it's entered rather than on the first
/// conversation. Uses the model-listing endpoint: it's free, spends no
/// generation quota, and rejects a bad key the same way every other call
/// does. The key travels in a header, never the URL.
///
/// This proves the key is *recognized*, not that every model (Live audio,
/// TTS) is enabled for it — those still surface through the connection
/// error messages if they fail.
struct GeminiKeyValidator {
    enum Outcome: Equatable {
        /// Google accepted the key.
        case valid
        /// Google says the key can't be used (invalid, revoked, or its
        /// project lacks access).
        case rejected
        /// The key is recognized but currently throttled — still a real key.
        case rateLimited
        /// Couldn't get an answer: offline, timed out, or cancelled.
        case unreachable
        /// Google answered with something unexpected.
        case unknown(status: Int)
    }

    var session: URLSession = .shared

    private static let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1")!

    func validate(_ key: String) async -> Outcome {
        var request = URLRequest(url: Self.url)
        request.timeoutInterval = 10
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .unknown(status: -1) }
            switch http.statusCode {
            case 200..<300: return .valid
            // Google answers an invalid key with 400 (API_KEY_INVALID);
            // 401/403 cover revoked keys and projects without access.
            case 400, 401, 403: return .rejected
            case 429: return .rateLimited
            default: return .unknown(status: http.statusCode)
            }
        } catch {
            return .unreachable
        }
    }
}
