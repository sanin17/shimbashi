import Foundation

/// Narrow seam around `GeminiTextClient` purely for testability — lets
/// `TranslationService`/`StruggleExtractor`/`ConversationStore` be tested
/// against a scripted fake instead of hitting the real network, the same
/// pattern `WebSocketChannel` already uses for the live transport.
protocol GeminiTextGenerating: Sendable {
    func generate(system: String, userMessage: String) async throws -> String
}

/// Plain (non-live) Gemini text generation — used for translation, not the
/// voice conversation itself. Same API key as the live session; no separate
/// account needed.
struct GeminiTextClient: GeminiTextGenerating {
    enum GeminiTextError: Error {
        case requestFailed(status: Int, body: String)
        case noTextContent
    }

    let apiKey: String
    var session = URLSession(configuration: .default)
    /// Pause before each retry after a transient failure; its length is also
    /// the retry budget. The free tier throttles bursts (a reply finishing
    /// can fire a translation, a breakdown and speech at once), and a
    /// one-off 429/503 shouldn't surface as a red error the learner has to
    /// tap through — a short wait nearly always clears it.
    var retryDelays: [Duration] = [.milliseconds(700), .milliseconds(1800)]

    /// Tried in order on every call. The first is a low-latency, cost-effective
    /// model built for lightweight tasks like this one (Google's named
    /// successor to the retiring gemini-3.1-flash-lite); the second is a
    /// different, larger Flash model. Overload ("high demand" 503s) is
    /// per-model, so falling over to a second one clears most bursts at once
    /// instead of waiting on a retry. Both are on the free tier.
    var models = ["gemini-3.5-flash-lite", "gemini-3.6-flash"]

    func generate(system: String, userMessage: String) async throws -> String {
        var delays = retryDelays[...]
        var lastError: Error = GeminiTextError.noTextContent
        while true {
            var sawTransient = false
            for model in models {
                do {
                    return try await attempt(model: model, system: system, userMessage: userMessage)
                } catch {
                    lastError = error
                    if Self.isModelUnavailable(error) {
                        // This key can't use this model (retired, or not on its
                        // tier) — move on at once; waiting wouldn't change that.
                        debugLog("[DEBUG GeminiTextClient] \(model) unavailable, trying next: \(error)")
                        continue
                    }
                    guard Self.isTransient(error) else { throw error }
                    sawTransient = true
                    debugLog("[DEBUG GeminiTextClient] \(model) transient failure, trying next: \(error)")
                }
            }
            // Every model failed this round. Only wait and go around again
            // if something might clear by itself.
            guard sawTransient, let delay = delays.popFirst() else { throw lastError }
            debugLog("[DEBUG GeminiTextClient] all models failed, retrying in \(delay)")
            try await Task.sleep(for: delay)
        }
    }

    /// A 404 means the model itself isn't there for this key.
    static func isModelUnavailable(_ error: Error) -> Bool {
        if case GeminiTextError.requestFailed(let status, _) = error { return status == 404 }
        return false
    }

    /// Failures worth another try: throttling, server-side hiccups, a
    /// dropped connection, or an empty reply. Anything else (a rejected key,
    /// a malformed request) would fail identically, so it's surfaced at once.
    static func isTransient(_ error: Error) -> Bool {
        switch error {
        case GeminiTextError.requestFailed(let status, _):
            return [408, 429, 500, 502, 503, 504].contains(status)
        case GeminiTextError.noTextContent:
            return true
        default:
            if let urlError = error as? URLError { return urlError.code != .cancelled }
            return false
        }
    }

    private func attempt(model: String, system: String, userMessage: String) async throws -> String {
        // Key goes in a header rather than the query string so it can't
        // surface in a URLError's description or in URL logs.
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

        let body: [String: Any] = [
            "contents": [["role": "user", "parts": [["text": userMessage]]]],
            "systemInstruction": ["parts": [["text": system]]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw GeminiTextError.requestFailed(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }

        struct GenerateResponse: Decodable {
            struct Candidate: Decodable {
                struct Content: Decodable {
                    struct Part: Decodable { var text: String? }
                    var parts: [Part]?
                }
                var content: Content?
            }
            var candidates: [Candidate]?
        }
        let decoded = try JSONDecoder().decode(GenerateResponse.self, from: data)
        guard let text = decoded.candidates?.first?.content?.parts?.first?.text else {
            throw GeminiTextError.noTextContent
        }
        return text
    }
}
