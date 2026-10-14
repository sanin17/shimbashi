import Foundation
import VoiceCore

/// One turn as shown on screen: Gemini's Japanese transcript arrives first
/// and instantly; the romaji/English lines fill in ~400ms later once
/// Gemini's translation call returns.
struct DisplayTurn: Identifiable {
    enum TranslationState {
        case pending
        case loaded(TranslationResult)
        case failed
        /// The turn wasn't actually Japanese (e.g. an English "how do I say
        /// X" question) — translating it would just paraphrase the same
        /// English back, so this is skipped rather than shown as if it were
        /// a real translation.
        case notApplicable
    }

    /// Phrase-by-phrase breakdown, fetched lazily — only once the learner
    /// taps the turn to expand it, not eagerly for every turn.
    enum BreakdownState {
        case notRequested
        case pending
        case loaded([PhraseGloss])
        case failed
        case notApplicable
    }

    let id: UUID
    let speaker: Turn.Speaker
    let japanese: String
    /// The model's own already-streamed reply audio, carried over from
    /// `Turn.audio` — lets the main-sentence `PlayButton` replay it directly
    /// instead of paying for a fresh TTS call. `nil` for user turns.
    let audio: Data?
    var translation: TranslationState = .pending
    var breakdown: BreakdownState = .notRequested
}
