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
    private let session = URLSession(configuration: .default)

    /// Low-latency, cost-effective model built for high-frequency, lightweight
    /// tasks like this one — not the same model the live conversation uses.
    private static let model = "gemini-3.1-flash-lite"

    func generate(system: String, userMessage: String) async throws -> String {
        // Key goes in a header rather than the query string so it can't
        // surface in a URLError's description or in URL logs.
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(Self.model):generateContent")!

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
