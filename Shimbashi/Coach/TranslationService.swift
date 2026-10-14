import Foundation

struct TranslationResult: Sendable, Decodable {
    var romaji: String
    var english: String
}

/// One meaningful chunk of a turn, for the tap-to-expand breakdown —
/// distinct from `TranslationResult`, which glosses the whole sentence at
/// once. Deliberately phrase-sized, not word-sized: splitting strictly by
/// word regularly produces pieces whose individual meaning doesn't match
/// what they mean combined (compound verbs, set phrases, a particle that
/// only makes sense attached to what it modifies).
struct PhraseGloss: Sendable, Codable {
    var japanese: String
    var romaji: String
    var english: String
}

/// Combined result of `TranslationService.analyzeReply` — the whole-sentence
/// gloss plus its phrase breakdown from a single call, for turns where both
/// are always needed together (see its doc comment).
struct ReplyAnalysis: Sendable, Decodable {
    var romaji: String
    var english: String
    var phrases: [PhraseGloss]
}

/// Fills in the romaji and English lines under a finalized Japanese turn,
/// and — on request — breaks a turn down into meaningful phrase chunks.
/// Runs off the audio/transcript path entirely — the Japanese line appears
/// instantly from Gemini's own transcript, this fills in the other two
/// lines ~400ms later. Uses the same Gemini key as the live conversation;
/// no second API account needed.
struct TranslationService {
    enum TranslationError: Error {
        case noJSONFound
    }

    let client: any GeminiTextGenerating

    private static let systemPrompt = """
    You are a precise Japanese-to-English translation assistant for a language \
    learning app. Given a Japanese sentence, respond with ONLY a JSON object \
    with exactly two fields: "romaji" (Hepburn romanization) and "english" \
    (a natural, conversational English translation). No other text, no \
    markdown code fences — just the raw JSON object.
    """

    private static let breakdownSystemPrompt = """
    You are breaking a Japanese sentence down for a language learner who \
    tapped on it to study it more closely. Given a Japanese sentence, split \
    it into meaningful phrase chunks, in reading order — NOT strictly word \
    by word. In Japanese, a word's dictionary meaning frequently doesn't \
    match what it means combined with its neighbors: compound verbs (e.g. \
    出かける), set expressions (e.g. お願いします, 気をつけて), a verb plus its \
    auxiliary or -te form construction, and a noun plus the particle(s) \
    marking its role should all stay together as one chunk, since splitting \
    them apart would teach the wrong meaning. Only split where each \
    resulting piece still carries real, correct meaning on its own as used \
    in this specific sentence. Respond with ONLY a JSON array, no other \
    text, no markdown code fences. Each element has exactly three fields: \
    "japanese" (the chunk exactly as it appears in the sentence), "romaji" \
    (Hepburn romanization of that chunk), and "english" (a short gloss of \
    that chunk's meaning as used in this sentence — a few words, not a \
    restatement of the whole sentence).
    """

    /// Same phrase-splitting rules as `breakdownSystemPrompt`, plus the
    /// whole-sentence gloss, in one response — used for the tutor's replies,
    /// which now always get both the inline translation and the breakdown
    /// (the breakdown screen auto-opens on every reply), so a single call
    /// covering both halves saves a full round-trip over fetching them
    /// separately.
    private static let replyAnalysisSystemPrompt = """
    You are analyzing a Japanese sentence spoken by a tutor, for a language \
    learning app. Given a Japanese sentence, respond with ONLY a JSON object \
    with exactly three fields: "romaji" (Hepburn romanization of the whole \
    sentence), "english" (a natural, conversational English translation of \
    the whole sentence), and "phrases" (an array breaking the sentence into \
    meaningful phrase chunks, in reading order — NOT strictly word by word. \
    In Japanese, a word's dictionary meaning frequently doesn't match what \
    it means combined with its neighbors: compound verbs (e.g. 出かける), set \
    expressions (e.g. お願いします, 気をつけて), a verb plus its auxiliary or \
    -te form construction, and a noun plus the particle(s) marking its role \
    should all stay together as one chunk, since splitting them apart would \
    teach the wrong meaning. Only split where each resulting piece still \
    carries real, correct meaning on its own as used in this specific \
    sentence. Each element of "phrases" has exactly three fields: "japanese" \
    (the chunk exactly as it appears in the sentence), "romaji" (Hepburn \
    romanization of that chunk), and "english" (a short gloss of that \
    chunk's meaning as used in this sentence — a few words, not a \
    restatement of the whole sentence)). No other text, no markdown code \
    fences — just the raw JSON object.
    """

    func analyzeReply(_ japanese: String) async throws -> ReplyAnalysis {
        let raw = try await client.generate(system: Self.replyAnalysisSystemPrompt, userMessage: japanese)
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}") else {
            throw TranslationError.noJSONFound
        }
        let json = raw[start...end]
        guard let data = json.data(using: .utf8) else { throw TranslationError.noJSONFound }
        return try JSONDecoder().decode(ReplyAnalysis.self, from: data)
    }

    func translate(_ japanese: String) async throws -> TranslationResult {
        let raw = try await client.generate(system: Self.systemPrompt, userMessage: japanese)
        // Slice out the JSON object rather than assuming the response has no
        // surrounding text or code fences — robust to minor model variance
        // without needing full structured-output plumbing for two fields.
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}") else {
            throw TranslationError.noJSONFound
        }
        let json = raw[start...end]
        guard let data = json.data(using: .utf8) else { throw TranslationError.noJSONFound }
        return try JSONDecoder().decode(TranslationResult.self, from: data)
    }

    func breakdown(_ japanese: String) async throws -> [PhraseGloss] {
        let raw = try await client.generate(system: Self.breakdownSystemPrompt, userMessage: japanese)
        guard let start = raw.firstIndex(of: "["), let end = raw.lastIndex(of: "]") else {
            throw TranslationError.noJSONFound
        }
        let json = raw[start...end]
        guard let data = json.data(using: .utf8) else { throw TranslationError.noJSONFound }
        return try JSONDecoder().decode([PhraseGloss].self, from: data)
    }
}
