import Testing
@testable import VoiceCore

@Suite struct ConversationContextTests {
    private func lines(_ pairs: [(Turn.Speaker, String)]) -> [ConversationContext.Line] {
        pairs.map { .init(speaker: $0.0, text: $0.1) }
    }

    @Test func nothingSaidMeansNoContext() {
        #expect(ConversationContext.prompt(from: []) == nil)
        #expect(ConversationContext.prompt(from: lines([(.user, "   "), (.model, "\n")])) == nil)
    }

    @Test func turnsAppearOldestFirstWithSpeakerLabels() throws {
        let prompt = try #require(ConversationContext.prompt(from: lines([
            (.user, "What's the best coffee in Tokyo?"),
            (.model, "表参道に素敵なお店があります。"),
            (.user, "And after that?"),
        ])))
        let learner1 = try #require(prompt.range(of: "Learner: What's the best coffee in Tokyo?"))
        let tutor = try #require(prompt.range(of: "Tutor: 表参道に素敵なお店があります。"))
        let learner2 = try #require(prompt.range(of: "Learner: And after that?"))
        #expect(learner1.lowerBound < tutor.lowerBound)
        #expect(tutor.lowerBound < learner2.lowerBound)
    }

    @Test func tellsTheModelNotToGreetOrRestart() throws {
        let prompt = try #require(ConversationContext.prompt(from: lines([(.user, "hi")])))
        #expect(prompt.contains("already in progress"))
        #expect(prompt.contains("do not greet them again"))
    }

    @Test func onlyTheMostRecentTurnsAreKept() throws {
        let many = (0..<(ConversationContext.maxTurns + 10)).map { (Turn.Speaker.user, "line \($0)") }
        let prompt = try #require(ConversationContext.prompt(from: lines(many)))
        #expect(!prompt.contains("Learner: line 0\n"))
        #expect(prompt.contains("Learner: line \(ConversationContext.maxTurns + 9)"))
    }

    @Test func aLongTurnIsTrimmed() throws {
        let long = String(repeating: "あ", count: ConversationContext.maxCharactersPerTurn * 3)
        let prompt = try #require(ConversationContext.prompt(from: lines([(.model, long)])))
        #expect(prompt.contains("…"))
        #expect(!prompt.contains(long))
    }

    @Test func overBudgetDropsTheOldestFirstAndKeepsTheLatest() throws {
        // Each line near the per-turn cap so 24 of them exceed the total cap.
        let big = String(repeating: "x", count: ConversationContext.maxCharactersPerTurn)
        let pairs = (0..<ConversationContext.maxTurns).map { i in (Turn.Speaker.model, "\(i)-\(big)") }
        let prompt = try #require(ConversationContext.prompt(from: lines(pairs)))
        let body = prompt.components(separatedBy: "oldest first:\n").last ?? ""
        #expect(body.count <= ConversationContext.maxTotalCharacters + 100)
        #expect(!prompt.contains("Tutor: 0-"))
        #expect(prompt.contains("Tutor: \(ConversationContext.maxTurns - 1)-"))
    }
}
