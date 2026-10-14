import Testing
import Foundation
import VoiceCore
@testable import Shimbashi

private func isLoaded(_ state: DisplayTurn.TranslationState?) -> Bool {
    if case .loaded = state { return true }
    return false
}

private func isBreakdownLoaded(_ state: DisplayTurn.BreakdownState?) -> Bool {
    if case .loaded = state { return true }
    return false
}

private func isFailed(_ state: DisplayTurn.BreakdownState?) -> Bool {
    if case .failed = state { return true }
    return false
}

private struct StubError: Error {}

@MainActor
private func waitUntil(timeout: Duration = .seconds(2), _ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while !condition(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
}

@Suite @MainActor struct ConversationCoordinatorTests {
    @Test func syncDedupSkipsAlreadyKnownTurns() async {
        let fake = FakeTextGenerator(.fixed(#"{"romaji":"a","english":"b","phrases":[]}"#))
        let coordinator = ConversationCoordinator(translationService: TranslationService(client: fake))
        let turn = Turn(speaker: .model, text: "こんにちは")

        coordinator.sync(with: [turn])
        await waitUntil { isLoaded(coordinator.displayTurns.first?.translation) }
        coordinator.sync(with: [turn]) // same turn again, same array

        #expect(coordinator.displayTurns.count == 1)
        #expect(await fake.callCount == 1)
    }

    @Test func nonJapaneseTurnShortCircuitsWithoutNetworkCall() async {
        let fake = FakeTextGenerator(.fixed("should never be used"))
        let coordinator = ConversationCoordinator(translationService: TranslationService(client: fake))

        coordinator.sync(with: [Turn(speaker: .user, text: "How do I say restroom?")])

        #expect(coordinator.displayTurns.count == 1)
        guard case .notApplicable = coordinator.displayTurns[0].translation else {
            Issue.record("expected .notApplicable translation")
            return
        }
        guard case .notApplicable = coordinator.displayTurns[0].breakdown else {
            Issue.record("expected .notApplicable breakdown")
            return
        }
        #expect(await fake.callCount == 0)
    }

    @Test func userTurnRoutesToPlainTranslateOnly() async {
        let fake = FakeTextGenerator(.fixed(#"{"romaji":"Konnichiwa","english":"Hello"}"#))
        let coordinator = ConversationCoordinator(translationService: TranslationService(client: fake))

        coordinator.sync(with: [Turn(speaker: .user, text: "こんにちは")])
        await waitUntil { isLoaded(coordinator.displayTurns.first?.translation) }

        #expect(await fake.callCount == 1)
        guard case .notRequested = coordinator.displayTurns[0].breakdown else {
            Issue.record("expected breakdown to remain lazy (.notRequested) for a user turn")
            return
        }
    }

    @Test func modelTurnRoutesToCombinedAnalysisInOneCall() async {
        let fake = FakeTextGenerator(.fixed(#"""
        {"romaji":"Konnichiwa","english":"Hello","phrases":[{"japanese":"こんにちは","romaji":"konnichiwa","english":"hello"}]}
        """#))
        let coordinator = ConversationCoordinator(translationService: TranslationService(client: fake))

        coordinator.sync(with: [Turn(speaker: .model, text: "こんにちは")])
        await waitUntil {
            isLoaded(coordinator.displayTurns.first?.translation) && isBreakdownLoaded(coordinator.displayTurns.first?.breakdown)
        }

        #expect(await fake.callCount == 1)
    }

    @Test func requestBreakdownIsNoOpWhilePending() async {
        let fake = FakeTextGenerator(.fixed(#"[{"japanese":"こんにちは","romaji":"konnichiwa","english":"hello"}]"#))
        let coordinator = ConversationCoordinator(translationService: TranslationService(client: fake))
        coordinator.sync(with: [Turn(speaker: .user, text: "こんにちは")])
        await waitUntil { isLoaded(coordinator.displayTurns.first?.translation) }
        let turnID = coordinator.displayTurns[0].id

        coordinator.requestBreakdown(for: turnID) // fires the fetch, flips to .pending synchronously
        coordinator.requestBreakdown(for: turnID) // should no-op — still .pending at this point

        await waitUntil { isBreakdownLoaded(coordinator.displayTurns.first?.breakdown) }
        // 1 translate() call + exactly 1 breakdown() call, not 2, despite the second tap.
        #expect(await fake.callCount == 2)
    }

    @Test func requestBreakdownRetriesAfterFailure() async {
        // Slot 1 is consumed by sync()'s own translate() call; slots 2/3 are
        // the two requestBreakdown() attempts below.
        let fake = FakeTextGenerator(.results([
            .success(#"{"romaji":"a","english":"b"}"#),
            .failure(StubError()),
            .success(#"[{"japanese":"こんにちは","romaji":"konnichiwa","english":"hello"}]"#),
        ]))
        let coordinator = ConversationCoordinator(translationService: TranslationService(client: fake))
        coordinator.sync(with: [Turn(speaker: .user, text: "こんにちは")])
        await waitUntil { isLoaded(coordinator.displayTurns.first?.translation) }
        let turnID = coordinator.displayTurns[0].id

        coordinator.requestBreakdown(for: turnID)
        await waitUntil { isFailed(coordinator.displayTurns.first?.breakdown) }
        guard case .failed = coordinator.displayTurns[0].breakdown else {
            Issue.record("expected breakdown to have failed on first attempt")
            return
        }

        coordinator.requestBreakdown(for: turnID) // retry
        await waitUntil { isBreakdownLoaded(coordinator.displayTurns.first?.breakdown) }
        guard case .loaded(let phrases) = coordinator.displayTurns[0].breakdown else {
            Issue.record("expected breakdown to succeed on retry")
            return
        }
        #expect(phrases.count == 1)
    }

    @Test func onTranslationLoadedAndOnBreakdownLoadedCallbacksFire() async {
        let fake = FakeTextGenerator(.fixed(#"""
        {"romaji":"Konnichiwa","english":"Hello","phrases":[{"japanese":"こんにちは","romaji":"konnichiwa","english":"hello"}]}
        """#))
        let coordinator = ConversationCoordinator(translationService: TranslationService(client: fake))
        var loadedTranslation: TranslationResult?
        var loadedPhrases: [PhraseGloss]?
        coordinator.onTranslationLoaded = { _, result in loadedTranslation = result }
        coordinator.onBreakdownLoaded = { _, phrases in loadedPhrases = phrases }

        coordinator.sync(with: [Turn(speaker: .model, text: "こんにちは")])
        await waitUntil { loadedTranslation != nil && loadedPhrases != nil }

        #expect(loadedTranslation?.romaji == "Konnichiwa")
        #expect(loadedPhrases?.count == 1)
    }

    @Test func onPhraseMismatchFiresWhenJoinedPhrasesDontReconstructSource() async {
        let fake = FakeTextGenerator(.fixed(#"""
        {"romaji":"a","english":"b","phrases":[{"japanese":"something else entirely","romaji":"x","english":"y"}]}
        """#))
        let coordinator = ConversationCoordinator(translationService: TranslationService(client: fake))
        var mismatchFired = false
        coordinator.onPhraseMismatch = { _, _, _ in mismatchFired = true }

        coordinator.sync(with: [Turn(speaker: .model, text: "こんにちは")])
        await waitUntil { isBreakdownLoaded(coordinator.displayTurns.first?.breakdown) }

        #expect(mismatchFired)
    }

    @Test func fullwidthPunctuationDoesNotFalselyTriggerMismatch() async {
        // Same content, differing only in fullwidth vs halfwidth question mark
        // — the exact false-positive found live-debugging this session.
        let fake = FakeTextGenerator(.fixed(#"""
        {"romaji":"a","english":"b","phrases":[{"japanese":"元気ですか？","romaji":"x","english":"y"}]}
        """#))
        let coordinator = ConversationCoordinator(translationService: TranslationService(client: fake))
        var mismatchFired = false
        coordinator.onPhraseMismatch = { _, _, _ in mismatchFired = true }

        coordinator.sync(with: [Turn(speaker: .model, text: "元気ですか?")]) // halfwidth "?"
        await waitUntil { isBreakdownLoaded(coordinator.displayTurns.first?.breakdown) }

        #expect(!mismatchFired)
    }

    @Test func updateLivePreviewCoalescesRapidUpdatesToAtMostOneInFlight() async {
        let fake = FakeTextGenerator(.sequence([
            #"{"romaji":"first","english":"first"}"#,
            #"{"romaji":"second","english":"second"}"#,
        ]))
        let coordinator = ConversationCoordinator(translationService: TranslationService(client: fake))

        // Fired synchronously back-to-back with no `await` in between — by the
        // time the 2nd/3rd calls run, isLiveTranslateInFlight is already true
        // (set synchronously in fireLiveTranslate before its Task is created),
        // so both should coalesce into pendingLiveText rather than firing.
        coordinator.updateLivePreview(partialModelText: "あ")
        coordinator.updateLivePreview(partialModelText: "あい")
        coordinator.updateLivePreview(partialModelText: "あいう")

        await waitUntil(timeout: .seconds(3)) { coordinator.livePartialTranslation?.romaji == "second" }

        #expect(coordinator.livePartialTranslation?.romaji == "second")
        // Exactly 2 calls: the first ("あ") fired immediately, the coalesced
        // pending update fired once more with the latest text ("あいう") —
        // never 3, since "あい" was overwritten before it ever fired.
        #expect(await fake.callCount == 2)
    }
}
