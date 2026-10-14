import Foundation
import SwiftData
import VoiceCore

/// Owns conversation persistence: saving turns as they finalize, loading the
/// most recent session on launch so the app can show where you left off,
/// extracting struggle notes once a session ends, and wiping everything on
/// request.
@MainActor
@Observable
final class ConversationStore {
    private let context: ModelContext
    private var currentSession: ConversationSession?

    /// The most recently persisted session, loaded once at init — what
    /// "resume" shows before the user taps Start again.
    private(set) var mostRecentSession: ConversationSession?

    init(context: ModelContext) {
        self.context = context
        self.mostRecentSession = Self.fetchMostRecentSession(context: context)
        // TEMPORARY DEBUG — remove once the vanishing-history issue is diagnosed.
        let allSessions = (try? context.fetch(FetchDescriptor<ConversationSession>())) ?? []
        debugLog("[DEBUG store.init] found \(allSessions.count) ConversationSession row(s) total; mostRecentSession id=\(mostRecentSession.map { "\($0.persistentModelID)" } ?? "nil"), turns=\(mostRecentSession?.turns.count ?? -1)")
        for s in allSessions {
            debugLog("[DEBUG store.init]   session started=\(s.startedAt) ended=\(String(describing: s.endedAt)) turns=\(s.turns.count) summary=\(s.summary ?? "nil")")
        }
    }

    /// Call once when a new live session starts. Closes out whatever session
    /// was previously left open — e.g. the app got killed in the background,
    /// or backgrounded long enough that iOS reclaimed the process, before
    /// Stop was ever tapped. Without this, that session never gets a summary
    /// or struggle notes generated (that only happens on close) and — since
    /// the resume screen only ever shows the single most recent session —
    /// effectively disappears the moment a new one starts, even though its
    /// turns are still safely on disk. `client` is optional purely for
    /// defensive safety; when present, the dangling session is finalized
    /// exactly as `endSession` would have. The new session is always created
    /// regardless, since turn persistence for it depends on it existing.
    func beginSession(closingDanglingSessionWith client: (any GeminiTextGenerating)?) {
        // TEMPORARY DEBUG
        debugLog("[DEBUG beginSession] called, client=\(client == nil ? "nil" : "present"), currentSession=\(currentSession == nil ? "nil" : "present")")
        if let client, let dangling = currentSession ?? Self.fetchOpenSession(context: context) {
            debugLog("[DEBUG beginSession] finalizing dangling session id=\(dangling.persistentModelID), turns=\(dangling.turns.count)")
            finalize(dangling, extractingStrugglesWith: client)
        } else {
            debugLog("[DEBUG beginSession] no dangling session found to finalize")
        }
        let newSession = ConversationSession()
        context.insert(newSession)
        currentSession = newSession
        do {
            try context.save()
            debugLog("[DEBUG beginSession] new session saved id=\(newSession.persistentModelID)")
        } catch {
            debugLog("[DEBUG beginSession] SAVE FAILED: \(error)")
        }
    }

    /// Reopens an already-finished conversation so new turns append to it
    /// rather than starting a fresh one — see `ConversationView(resuming:)`.
    /// Clears `endedAt` so it reads as in-progress again; the summary is
    /// regenerated from the fuller transcript when it's next ended.
    ///
    /// Note this is only continuity of *the transcript*, not of the model's
    /// memory: Gemini Live has no cross-session recall, so the tutor gets
    /// this conversation's recap injected into its system prompt (see
    /// `recap(of:)`) exactly the way a brand-new conversation gets the most
    /// recent one's.
    func resumeSession(_ session: ConversationSession) {
        debugLog("[DEBUG resumeSession] resuming id=\(session.persistentModelID), turns=\(session.turns.count)")
        session.endedAt = nil
        currentSession = session
        mostRecentSession = session
        do {
            try context.save()
        } catch {
            debugLog("[DEBUG resumeSession] SAVE FAILED: \(error)")
        }
    }

    func persist(_ turn: Turn, romaji: String?, english: String?) {
        guard let currentSession else {
            debugLog("[DEBUG persist] DROPPED turn — currentSession is nil! text=\(turn.text)")
            return
        }
        let persisted = PersistedTurn(id: turn.id, speaker: turn.speaker, japanese: turn.text, romaji: romaji, english: english)
        persisted.session = currentSession
        currentSession.turns.append(persisted)
        do {
            try context.save()
            debugLog("[DEBUG persist] saved turn, session id=\(currentSession.persistentModelID) now has \(currentSession.turns.count) turn(s)")
        } catch {
            debugLog("[DEBUG persist] SAVE FAILED: \(error)")
        }
    }

    /// Called once a turn's translation loads in (moments after `persist`
    /// saved its bare text) — see `ConversationCoordinator.onTranslationLoaded`.
    /// Caches it permanently so a later app launch never re-fetches it.
    func updateTranslation(id: UUID, romaji: String, english: String) {
        guard let persisted = fetchPersistedTurn(id: id) else { return }
        persisted.romaji = romaji
        persisted.english = english
        do {
            try context.save()
        } catch {
            debugLog("[DEBUG updateTranslation] SAVE FAILED: \(error)")
        }
    }

    /// Same as `updateTranslation`, for the phrase breakdown — see
    /// `ConversationCoordinator.onBreakdownLoaded`.
    func updateBreakdownCache(id: UUID, phrases: [PhraseGloss]) {
        guard let persisted = fetchPersistedTurn(id: id) else { return }
        persisted.breakdown = phrases
        do {
            try context.save()
        } catch {
            debugLog("[DEBUG updateBreakdownCache] SAVE FAILED: \(error)")
        }
    }

    private func fetchPersistedTurn(id: UUID) -> PersistedTurn? {
        var descriptor = FetchDescriptor<PersistedTurn>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// Call when the live session stops. Marks the session closed and kicks
    /// off analysis (summary + struggle notes) in the background — see
    /// `finalize`.
    func endSession(extractingStrugglesWith client: any GeminiTextGenerating) {
        guard let session = currentSession else { return }
        finalize(session, extractingStrugglesWith: client)
        currentSession = nil
    }

    /// Marks a session closed, kicks off analysis (summary + struggle notes)
    /// in the background, and refreshes `mostRecentSession` so the next app
    /// launch (or the current screen, on next appearance) shows this session
    /// as the resume point. `summary` populates a moment later, once the
    /// analysis call returns — the UI reads it reactively off
    /// `mostRecentSession`.
    private func finalize(_ session: ConversationSession, extractingStrugglesWith client: any GeminiTextGenerating) {
        session.endedAt = Date()
        do {
            try context.save()
        } catch {
            debugLog("[DEBUG finalize] SAVE FAILED (endedAt): \(error)")
        }
        mostRecentSession = session
        debugLog("[DEBUG finalize] set mostRecentSession id=\(session.persistentModelID), turns=\(session.turns.count)")

        let transcript = session.turns
            .sorted { $0.timestamp < $1.timestamp }
            .map { "\($0.speaker == .user ? "Learner" : "Tutor"): \($0.japanese)" }
            .joined(separator: "\n")

        Task {
            let extractor = StruggleExtractor(client: client)
            do {
                let analysis = try await extractor.analyze(transcript: transcript)
                session.summary = analysis.summary
                for struggle in analysis.struggles {
                    context.insert(StruggleNote(phrase: struggle.phrase, note: struggle.note))
                }
                try context.save()
                debugLog("[DEBUG finalize] analysis saved, summary=\(analysis.summary.prefix(40))")
            } catch {
                debugLog("[DEBUG finalize] ANALYSIS/SAVE FAILED: \(error)")
            }
        }
    }

    /// Up to `limit` most recent struggle notes, for injecting into the next
    /// session's system prompt.
    func recentStruggleNotes(limit: Int = 5) -> [StruggleNote] {
        var descriptor = FetchDescriptor<StruggleNote>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }

    /// A short recap of the most recent session's content, for priming a new
    /// live connection with continuity after a resume — Gemini Live has no
    /// built-in way to resume text history into a fresh connection, so this
    /// gets sent as context instead.
    func recapOfMostRecentSession(turnLimit: Int = 6) -> String? {
        guard let session = mostRecentSession else { return nil }
        return recap(of: session, turnLimit: turnLimit)
    }

    /// Same recap, for one specific conversation — used when resuming an
    /// older one, so the tutor is primed with *that* conversation's thread
    /// rather than whatever happened most recently.
    func recap(of session: ConversationSession, turnLimit: Int = 6) -> String? {
        guard !session.turns.isEmpty else { return nil }
        let recentTurns = session.turns.sorted { $0.timestamp < $1.timestamp }.suffix(turnLimit)
        return recentTurns
            .map { "\($0.speaker == .user ? "Learner" : "Tutor"): \($0.japanese)" }
            .joined(separator: "\n")
    }

    /// Wipes all persisted sessions, turns, and struggle notes.
    func resetAll() {
        try? context.delete(model: ConversationSession.self)
        try? context.delete(model: PersistedTurn.self)
        try? context.delete(model: StruggleNote.self)
        try? context.save()
        currentSession = nil
        mostRecentSession = nil
    }

    private static func fetchMostRecentSession(context: ModelContext) -> ConversationSession? {
        var descriptor = FetchDescriptor<ConversationSession>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// Finds a session left with no `endedAt` from a prior run — `currentSession`
    /// only tracks one created by *this* `ConversationStore` instance, but a
    /// fresh app launch starts with a brand new instance, so a session
    /// orphaned by the previous process dying wouldn't otherwise be found.
    private static func fetchOpenSession(context: ModelContext) -> ConversationSession? {
        var descriptor = FetchDescriptor<ConversationSession>(
            predicate: #Predicate { $0.endedAt == nil },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}
