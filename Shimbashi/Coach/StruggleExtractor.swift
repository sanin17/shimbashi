import Foundation

struct ExtractedStruggle: Sendable, Decodable {
    var phrase: String
    var note: String
}

struct SessionAnalysis: Sendable, Decodable {
    var summary: String
    var struggles: [ExtractedStruggle]
}

/// Reviews a finished session's transcript and produces both a short summary
/// (shown to the learner on resume, so they can judge whether to continue or
/// start fresh) and a list of specific things they struggled with (fed into
/// the next session's system prompt, not shown verbatim in the UI). Runs
/// once per session end, off the live conversation path entirely.
struct StruggleExtractor {
    enum ExtractorError: Error {
        case noJSONFound
    }

    let client: any GeminiTextGenerating

    private static let systemPrompt = """
    You are analyzing a transcript of a Japanese conversation-practice session \
    between an English-speaking learner and an AI tutor. Produce ONLY a JSON \
    object, no other text, no markdown code fences, with exactly two fields:

    "summary": a short (1-3 sentence) plain-English summary of what was \
    discussed and how the learner did overall — written directly to the \
    learner ("You practiced..."), so they can quickly judge whether to \
    continue this thread or start something new.

    "struggles": an array of up to 5 specific Japanese phrases, words, or \
    grammar points the learner struggled with — mispronounced, hesitated on, \
    asked how to say, or that the tutor had to correct or rephrase for them. \
    Each element has exactly two fields: "phrase" (the specific Japanese \
    phrase or grammar point, in Japanese) and "note" (a short English note on \
    what to practice, one sentence). Use an empty array if nothing notable \
    stood out.
    """

    func analyze(transcript: String) async throws -> SessionAnalysis {
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return SessionAnalysis(summary: "", struggles: [])
        }
        let raw = try await client.generate(system: Self.systemPrompt, userMessage: transcript)
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}") else {
            throw ExtractorError.noJSONFound
        }
        let json = raw[start...end]
        guard let data = json.data(using: .utf8) else { throw ExtractorError.noJSONFound }
        return try JSONDecoder().decode(SessionAnalysis.self, from: data)
    }
}
