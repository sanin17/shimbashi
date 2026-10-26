import Testing
import Foundation
import SwiftData
import VoiceCore
@testable import Shimbashi

@MainActor
private func waitUntil(timeout: Duration = .seconds(2), _ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while !condition(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor
private func makeInMemoryContext() throws -> ModelContext {
    let schema = Schema([ConversationSession.self, PersistedTurn.self, StruggleNote.self])
    let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: schema, configurations: [configuration])
    return ModelContext(container)
}

@Suite @MainActor struct ConversationStoreTests {
    @Test func persistSavesTurnUnderCurrentSession() throws {
        let context = try makeInMemoryContext()
        let store = ConversationStore(context: context)
        store.beginSession(closingDanglingSessionWith: nil)

        store.persist(Turn(speaker: .user, text: "こんにちは"), romaji: nil, english: nil)

        let sessions = try context.fetch(FetchDescriptor<ConversationSession>())
        #expect(sessions.count == 1)
        #expect(sessions.first?.turns.count == 1)
        #expect(sessions.first?.turns.first?.japanese == "こんにちは")
    }

    @Test func updateTranslationRoundTrips() throws {
        let context = try makeInMemoryContext()
        let store = ConversationStore(context: context)
        store.beginSession(closingDanglingSessionWith: nil)
        let turn = Turn(speaker: .model, text: "こんにちは")
        store.persist(turn, romaji: nil, english: nil)

        let turnID = turn.id
        store.updateTranslation(id: turnID, romaji: "Konnichiwa", english: "Hello")

        let descriptor = FetchDescriptor<PersistedTurn>(predicate: #Predicate { $0.id == turnID })
        let persisted = try #require(try context.fetch(descriptor).first)
        #expect(persisted.romaji == "Konnichiwa")
        #expect(persisted.english == "Hello")
    }

    @Test func updateBreakdownCacheRoundTrips() throws {
        let context = try makeInMemoryContext()
        let store = ConversationStore(context: context)
        store.beginSession(closingDanglingSessionWith: nil)
        let turn = Turn(speaker: .model, text: "こんにちは")
        store.persist(turn, romaji: nil, english: nil)

        let phrases = [PhraseGloss(japanese: "こんにちは", romaji: "konnichiwa", english: "hello")]
        let turnID = turn.id
        store.updateBreakdownCache(id: turnID, phrases: phrases)

        let descriptor = FetchDescriptor<PersistedTurn>(predicate: #Predicate { $0.id == turnID })
        let persisted = try #require(try context.fetch(descriptor).first)
        #expect(persisted.breakdown?.count == 1)
        #expect(persisted.breakdown?.first?.japanese == "こんにちは")
    }

    @Test func endSessionFinalizesAndResetAllCascadeDeletes() async throws {
        let context = try makeInMemoryContext()
        let store = ConversationStore(context: context)
        store.beginSession(closingDanglingSessionWith: nil)
        store.persist(Turn(speaker: .user, text: "こんにちは"), romaji: nil, english: nil)

        let fake = FakeTextGenerator(.fixed(#"{"summary":"Practiced greetings.","struggles":[]}"#))
        store.endSession(extractingStrugglesWith: fake)
        await waitUntil { store.mostRecentSession?.summary != nil }
        #expect(store.mostRecentSession?.summary == "Practiced greetings.")

        store.resetAll()

        let sessions = try context.fetch(FetchDescriptor<ConversationSession>())
        let turns = try context.fetch(FetchDescriptor<PersistedTurn>())
        #expect(sessions.isEmpty)
        #expect(turns.isEmpty)
        #expect(store.mostRecentSession == nil)
    }

    @Test func recapOfMostRecentSessionTruncatesToTurnLimit() async throws {
        let context = try makeInMemoryContext()
        let store = ConversationStore(context: context)
        store.beginSession(closingDanglingSessionWith: nil)
        for i in 0..<8 {
            store.persist(Turn(speaker: .user, text: "turn \(i)"), romaji: nil, english: nil)
        }
        let fake = FakeTextGenerator(.fixed(#"{"summary":"ok","struggles":[]}"#))
        store.endSession(extractingStrugglesWith: fake)
        await waitUntil { store.mostRecentSession?.summary != nil }

        let recap = try #require(store.recapOfMostRecentSession(turnLimit: 3))
        #expect(recap.components(separatedBy: "\n").count == 3)
    }

    @Test func recentStruggleNotesRespectsLimitAndOrdering() throws {
        let context = try makeInMemoryContext()
        let store = ConversationStore(context: context)
        let now = Date()
        for i in 0..<7 {
            context.insert(StruggleNote(phrase: "phrase\(i)", note: "note\(i)", createdAt: now.addingTimeInterval(Double(i))))
        }
        try context.save()

        let notes = store.recentStruggleNotes(limit: 3)
        #expect(notes.count == 3)
        // Newest first.
        #expect(notes[0].phrase == "phrase6")
        #expect(notes[1].phrase == "phrase5")
        #expect(notes[2].phrase == "phrase4")
    }

    @Test func resumeSessionReopensAndAppendsToTheSameConversation() async throws {
        let context = try makeInMemoryContext()
        let store = ConversationStore(context: context)
        store.beginSession(closingDanglingSessionWith: nil)
        store.persist(Turn(speaker: .user, text: "こんにちは"), romaji: nil, english: nil)
        store.endSession(extractingStrugglesWith: FakeTextGenerator(.fixed(#"{"summary":"ok","struggles":[]}"#)))
        await waitUntil { store.mostRecentSession?.summary != nil }

        let original = try #require(store.mostRecentSession)
        #expect(original.endedAt != nil)

        store.resumeSession(original)
        #expect(original.endedAt == nil) // reads as in-progress again
        store.persist(Turn(speaker: .user, text: "ありがとう"), romaji: nil, english: nil)

        // Appended to the same conversation, not stranded in a new one.
        let sessions = try context.fetch(FetchDescriptor<ConversationSession>())
        #expect(sessions.count == 1)
        #expect(sessions.first?.turns.count == 2)
    }

    @Test func aFollowUpAfterTheConversationEndedStaysOneConversation() async throws {
        let context = try makeInMemoryContext()
        let store = ConversationStore(context: context)

        // First Start on a new conversation screen: the screen keeps what
        // beginSession returns.
        let screensConversation = store.beginSession(closingDanglingSessionWith: nil)
        store.persist(Turn(speaker: .user, text: "I want to try sushi in Tokyo"), romaji: nil, english: nil)

        // The phone locks: the conversation is ended and closed out...
        store.endSession(extractingStrugglesWith: FakeTextGenerator(.fixed(#"{"summary":"sushi","struggles":[]}"#)))
        await waitUntil { screensConversation.summary != nil }
        #expect(screensConversation.endedAt != nil)

        // ...then the learner comes back and taps Start. The screen reopens
        // its own conversation, so the follow-up lands in the same one.
        store.resumeSession(screensConversation)
        store.persist(Turn(speaker: .user, text: "Where should I go for that?"), romaji: nil, english: nil)

        let sessions = try context.fetch(FetchDescriptor<ConversationSession>())
        #expect(sessions.count == 1)
        #expect(sessions.first?.turns.count == 2)
        #expect(screensConversation.endedAt == nil)
    }

    @Test func beginSessionReturnsTheSessionNewTurnsAreSavedUnder() throws {
        let context = try makeInMemoryContext()
        let store = ConversationStore(context: context)
        let started = store.beginSession(closingDanglingSessionWith: nil)
        store.persist(Turn(speaker: .user, text: "こんにちは"), romaji: nil, english: nil)
        #expect(started.turns.count == 1)
    }

    @Test func recapOfSpecificSessionUsesThatConversationNotTheMostRecent() async throws {
        let context = try makeInMemoryContext()
        let store = ConversationStore(context: context)

        store.beginSession(closingDanglingSessionWith: nil)
        store.persist(Turn(speaker: .user, text: "older conversation"), romaji: nil, english: nil)
        store.endSession(extractingStrugglesWith: FakeTextGenerator(.fixed(#"{"summary":"ok","struggles":[]}"#)))
        let older = try #require(store.mostRecentSession)

        store.beginSession(closingDanglingSessionWith: nil)
        store.persist(Turn(speaker: .user, text: "newer conversation"), romaji: nil, english: nil)

        let olderRecap = try #require(store.recap(of: older))
        #expect(olderRecap.contains("older conversation"))
        #expect(!olderRecap.contains("newer conversation"))
    }

    /// Regression shape for the sync()-wipes-history-adjacent class of bug
    /// found this session: a second `ConversationStore` instance against the
    /// same context (mirroring a fresh app launch) must never touch rows
    /// created by an earlier instance.
    @Test func beginSessionOnAFreshStoreInstanceDoesNotDisturbExistingRows() throws {
        let context = try makeInMemoryContext()
        let firstStore = ConversationStore(context: context)
        firstStore.beginSession(closingDanglingSessionWith: nil)
        firstStore.persist(Turn(speaker: .user, text: "old turn"), romaji: nil, english: nil)
        firstStore.endSession(extractingStrugglesWith: FakeTextGenerator(.fixed(#"{"summary":"","struggles":[]}"#)))

        let secondStore = ConversationStore(context: context)
        secondStore.beginSession(closingDanglingSessionWith: nil)
        secondStore.persist(Turn(speaker: .user, text: "new turn"), romaji: nil, english: nil)

        let allSessions = try context.fetch(FetchDescriptor<ConversationSession>())
        #expect(allSessions.count == 2)
        let allTurns = try context.fetch(FetchDescriptor<PersistedTurn>())
        #expect(allTurns.count == 2)
        #expect(allTurns.contains { $0.japanese == "old turn" })
        #expect(allTurns.contains { $0.japanese == "new turn" })
    }

    /// A session left with no `endedAt` (app killed mid-conversation) must
    /// get finalized by the next `ConversationStore` instance's
    /// `beginSession`, even though `currentSession` (in-memory, per-instance)
    /// has no idea it exists — this is exactly what `fetchOpenSession` is for.
    @Test func beginSessionFinalizesADanglingSessionFromAPriorProcess() async throws {
        let context = try makeInMemoryContext()
        let dangling = ConversationSession()
        context.insert(dangling)
        let danglingTurn = PersistedTurn(id: UUID(), speaker: .user, japanese: "orphaned turn")
        danglingTurn.session = dangling
        dangling.turns.append(danglingTurn)
        try context.save()
        #expect(dangling.endedAt == nil)

        let freshStore = ConversationStore(context: context)
        let fake = FakeTextGenerator(.fixed(#"{"summary":"Recovered.","struggles":[]}"#))
        freshStore.beginSession(closingDanglingSessionWith: fake)

        await waitUntil { dangling.endedAt != nil }
        #expect(dangling.endedAt != nil)
        await waitUntil { dangling.summary != nil }
        #expect(dangling.summary == "Recovered.")

        let allSessions = try context.fetch(FetchDescriptor<ConversationSession>())
        #expect(allSessions.count == 2) // the dangling one, plus the new one just begun
    }
}
