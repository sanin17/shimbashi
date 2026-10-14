import Foundation
import VoiceCore

/// Watches `VoiceSession.turns` and layers Gemini's romaji/English
/// translation on top of each one as it finalizes. Kept separate from
/// `VoiceSession` itself — that type is Gemini/audio-only, translation is a
/// distinct concern layered on top in the UI.
@MainActor
@Observable
final class ConversationCoordinator {
    private(set) var displayTurns: [DisplayTurn] = []
    /// Romaji/English for the model's turn while it's still mid-flight, so
    /// the learner can follow along as the sentence is spoken rather than
    /// waiting for it to finish — see `updateLivePreview`.
    private(set) var livePartialTranslation: TranslationResult?
    /// Bumped on any change that should trigger a re-scroll: a turn added, a
    /// turn's translation loading in, or the live preview updating. Views
    /// observe this one `Int` instead of diffing the turns array by hand.
    private(set) var revision = 0

    /// Fired once a turn's translation/breakdown resolves to `.loaded` — lets
    /// `ConversationView` persist it via `ConversationStore`, so a later
    /// launch never re-fetches it. Not fired for `.notApplicable`/`.failed`.
    var onTranslationLoaded: ((UUID, TranslationResult) -> Void)?
    var onBreakdownLoaded: ((UUID, [PhraseGloss]) -> Void)?
    /// Fired when a breakdown's phrases don't reconstruct the sentence they
    /// supposedly came from — see `logIfPhraseMismatch`. `(turnID, source,
    /// joinedPhrases)`. Purely a testing/observability hook; production has
    /// no listener today beyond the console print.
    var onPhraseMismatch: ((UUID, String, String) -> Void)?

    private let translationService: TranslationService
    /// Bumped whenever a turn finalizes, to invalidate any live-preview call
    /// still in flight — its result would otherwise arrive after the turn
    /// already has its authoritative translation and stomp it.
    private var liveTranslateGeneration = 0
    private var isLiveTranslateInFlight = false
    /// The most recent partial text seen while a translate call was already
    /// in flight — picked up the moment that call returns, so at most one
    /// call runs at a time and each one starts on the freshest text.
    private var pendingLiveText: String?
    private var lastLiveTranslatedText = ""

    init(translationService: TranslationService) {
        self.translationService = translationService
    }

    /// Call whenever `session.turns` changes. Additive only — appends any
    /// turn not already present in `displayTurns` and kicks off its
    /// translation/breakdown; never removes or replaces anything already
    /// there (a turn added this way is always live, so nothing is ever
    /// pre-cached — contrast `loadHistoricalSession`).
    func sync(with turns: [Turn]) {
        // TEMPORARY DEBUG
        debugLog("[DEBUG ConversationCoordinator] sync() called with \(turns.count) turn(s), current displayTurns=\(displayTurns.count)")
        for turn in turns {
            guard !displayTurns.contains(where: { $0.id == turn.id }) else { continue }
            var displayTurn = DisplayTurn(id: turn.id, speaker: turn.speaker, japanese: turn.text, audio: turn.audio)
            if !turn.text.containsJapaneseScript {
                displayTurn.translation = .notApplicable
                displayTurn.breakdown = .notApplicable
            } else if turn.speaker == .model {
                if let preview = livePartialTranslation {
                    // Seed with the last live preview instead of a blank
                    // spinner — the sentence just finished, so this is
                    // already an accurate (or near-accurate) translation.
                    // Avoids visibly clearing text that was already on
                    // screen while the authoritative call below loads in
                    // behind it.
                    displayTurn.translation = .loaded(preview)
                }
                // Model turns always get their breakdown auto-fetched now
                // (the breakdown screen auto-opens on every reply — see
                // ConversationView), so translation and breakdown are
                // always needed together. One combined call covers both
                // instead of two separate ones.
                displayTurn.breakdown = .pending
                analyzeModelTurn(displayTurn)
            } else {
                translate(displayTurn)
            }
            displayTurns.append(displayTurn)
        }
        livePartialTranslation = nil
        revision += 1
    }

    /// Call whenever `session.partialModelText` changes. Rather than a fixed
    /// delay, this re-fires the instant the previous translate call
    /// completes — so it updates as fast as the API can sustain, with at
    /// most one request in flight at a time (an update mid-flight is queued
    /// as `pendingLiveText`, not fired as a second overlapping call). Once
    /// the turn finalizes, the caller passes an empty string and the
    /// preview clears; the authoritative translation for the completed turn
    /// comes from `sync`.
    func updateLivePreview(partialModelText: String) {
        guard !partialModelText.isEmpty else {
            liveTranslateGeneration += 1
            isLiveTranslateInFlight = false
            pendingLiveText = nil
            livePartialTranslation = nil
            lastLiveTranslatedText = ""
            return
        }
        guard partialModelText != lastLiveTranslatedText else { return }
        // The tutor mostly speaks Japanese, but a rescue-on-stall moment can
        // be English — translating that live preview would just paraphrase
        // it, same issue as `translate(_:)` below.
        guard partialModelText.containsJapaneseScript else { return }
        guard !isLiveTranslateInFlight else {
            pendingLiveText = partialModelText
            return
        }
        fireLiveTranslate(partialModelText)
    }

    private func fireLiveTranslate(_ text: String) {
        lastLiveTranslatedText = text
        pendingLiveText = nil
        isLiveTranslateInFlight = true
        let myGeneration = liveTranslateGeneration
        Task {
            let result = try? await translationService.translate(text)
            guard myGeneration == self.liveTranslateGeneration else { return }
            isLiveTranslateInFlight = false
            if let result {
                livePartialTranslation = result
                revision += 1
            }
            if let next = pendingLiveText, next != lastLiveTranslatedText {
                fireLiveTranslate(next)
            }
        }
    }

    /// Call when the learner taps a turn to expand it. Fetches lazily and
    /// only once — a second tap while `.pending`/`.loaded` is a no-op; a
    /// turn that previously `.failed` is retried. Deliberately doesn't bump
    /// `revision` — that drives auto-scroll-to-bottom, and expanding a
    /// breakdown can happen on any turn in the transcript, not just the
    /// latest one, so it shouldn't yank the view down while reading it.
    func requestBreakdown(for turnID: UUID) {
        guard let index = displayTurns.firstIndex(where: { $0.id == turnID }) else { return }
        switch displayTurns[index].breakdown {
        case .pending, .loaded: return
        case .notRequested, .failed, .notApplicable: break
        }
        let turn = displayTurns[index]
        guard turn.japanese.containsJapaneseScript else {
            displayTurns[index].breakdown = .notApplicable
            return
        }
        displayTurns[index].breakdown = .pending

        // Model turns are always analyzed via the combined
        // translation+breakdown call (see sync()) — retrying that here
        // (rather than fetching just the breakdown half again) keeps a
        // failed translation from being left stale next to a freshly
        // loaded breakdown.
        if turn.speaker == .model {
            analyzeModelTurn(turn)
            return
        }

        Task {
            do {
                let phrases = try await translationService.breakdown(turn.japanese)
                logIfPhraseMismatch(phrases, against: turn.japanese, turnID: turnID)
                updateBreakdown(id: turnID, state: .loaded(phrases))
            } catch {
                updateBreakdown(id: turnID, state: .failed)
            }
        }
    }

    /// A sanity check, not a correction — logs loudly if the phrase chunks
    /// don't reconstruct the sentence they supposedly came from, so a
    /// mismatch (the model hallucinating/dropping content while chunking)
    /// is caught immediately instead of looking like "the breakdown added
    /// words" with no way to tell it apart from the source transcript
    /// itself already being off.
    private func logIfPhraseMismatch(_ phrases: [PhraseGloss], against japanese: String, turnID: UUID) {
        let joined = phrases.map(\.japanese).joined()
        guard normalizedForComparison(joined) != normalizedForComparison(japanese) else { return }
        debugLog("[DEBUG ConversationCoordinator] PHRASE MISMATCH id=\(turnID) — source: \"\(japanese)\" vs joined phrases: \"\(joined)\"")
        onPhraseMismatch?(turnID, japanese, joined)
    }

    /// Strips whitespace and normalizes fullwidth/halfwidth punctuation
    /// variants (e.g. "？" vs "?") before comparing — the model sometimes
    /// normalizes punctuation width when echoing text back in a phrase
    /// breakdown, which isn't a real content mismatch. Applied identically
    /// to both sides, so this only affects what counts as equal, never what
    /// gets displayed.
    private func normalizedForComparison(_ text: String) -> String {
        let widthNormalized = text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text
        return widthNormalized.filter { !$0.isWhitespace }
    }

    /// Fires the combined translation+breakdown call for a model turn — see
    /// the callers in `sync()` and `requestBreakdown()`. Safe to call for a
    /// turn not yet in `displayTurns` (the `sync()` case): unlike
    /// `translate()`, this never needs to read `displayTurns` itself before
    /// the Task runs, only write to it once the call resolves.
    private func analyzeModelTurn(_ turn: DisplayTurn) {
        // TEMPORARY DEBUG
        debugLog("[DEBUG ConversationCoordinator] analyzeModelTurn() called for id=\(turn.id): \"\(turn.japanese)\"")
        Task {
            do {
                let analysis = try await translationService.analyzeReply(turn.japanese)
                debugLog("[DEBUG ConversationCoordinator] analyzeModelTurn() succeeded id=\(turn.id): \(analysis.english)")
                logIfPhraseMismatch(analysis.phrases, against: turn.japanese, turnID: turn.id)
                updateTranslation(id: turn.id, state: .loaded(TranslationResult(romaji: analysis.romaji, english: analysis.english)))
                updateBreakdown(id: turn.id, state: .loaded(analysis.phrases))
            } catch {
                debugLog("[DEBUG ConversationCoordinator] analyzeModelTurn() FAILED id=\(turn.id): \(error)")
                updateTranslation(id: turn.id, state: .failed)
                updateBreakdown(id: turn.id, state: .failed)
            }
        }
    }

    private func updateBreakdown(id: UUID, state: DisplayTurn.BreakdownState) {
        guard let index = displayTurns.firstIndex(where: { $0.id == id }) else { return }
        displayTurns[index].breakdown = state
        if case .loaded(let phrases) = state {
            onBreakdownLoaded?(id, phrases)
        }
    }

    /// Only for user turns now — model turns go through `analyzeModelTurn`
    /// instead, which fetches the breakdown in the same call (see `sync`).
    /// Only ever called for turns already confirmed to contain Japanese
    /// script — see `sync`, which handles the non-Japanese case inline
    /// since it can't go through `updateTranslation`'s displayTurns lookup
    /// (the turn isn't in `displayTurns` yet at that point in `sync`).
    private func translate(_ turn: DisplayTurn) {
        // TEMPORARY DEBUG
        debugLog("[DEBUG ConversationCoordinator] translate() called for \(turn.speaker) turn id=\(turn.id): \"\(turn.japanese)\"")
        Task {
            do {
                let result = try await translationService.translate(turn.japanese)
                debugLog("[DEBUG ConversationCoordinator] translate() succeeded id=\(turn.id): \(result.english)")
                updateTranslation(id: turn.id, state: .loaded(result))
            } catch {
                debugLog("[DEBUG ConversationCoordinator] translate() FAILED id=\(turn.id): \(error)")
                updateTranslation(id: turn.id, state: .failed)
            }
        }
    }

    private func updateTranslation(id: UUID, state: DisplayTurn.TranslationState) {
        guard let index = displayTurns.firstIndex(where: { $0.id == id }) else {
            // TEMPORARY DEBUG
            debugLog("[DEBUG ConversationCoordinator] updateTranslation() DROPPED — id=\(id) not found in displayTurns (count=\(displayTurns.count))")
            return
        }
        displayTurns[index].translation = state
        revision += 1
        if case .loaded(let result) = state {
            onTranslationLoaded?(id, result)
        }
    }

    /// Loads one past conversation's turns for a read-only detail view (see
    /// `ConversationHistoryView`) — reuses a cached translation/breakdown
    /// wherever the persisted row already has one (free, instant), and
    /// fires a fetch for anything that doesn't, same as a live turn would.
    /// Eager fetching is fine here specifically because it's bounded to one
    /// conversation's handful of turns — unlike doing this for every past
    /// conversation on every app launch, which is what this was written to
    /// avoid in the first place. Expects `persistedTurns` oldest-first.
    func loadHistoricalSession(_ persistedTurns: [PersistedTurn]) {
        for persisted in persistedTurns {
            guard !displayTurns.contains(where: { $0.id == persisted.id }) else { continue }
            var displayTurn = DisplayTurn(id: persisted.id, speaker: persisted.speaker, japanese: persisted.japanese, audio: nil)
            if !persisted.japanese.containsJapaneseScript {
                displayTurn.translation = .notApplicable
                displayTurn.breakdown = .notApplicable
            } else if let romaji = persisted.romaji {
                displayTurn.translation = .loaded(TranslationResult(romaji: romaji, english: persisted.english ?? ""))
                if let phrases = persisted.breakdown {
                    displayTurn.breakdown = .loaded(phrases)
                }
            } else if persisted.speaker == .model {
                displayTurn.breakdown = .pending
                analyzeModelTurn(displayTurn)
            } else {
                translate(displayTurn)
            }
            displayTurns.append(displayTurn)
        }
        revision += 1
    }
}
