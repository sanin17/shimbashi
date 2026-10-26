import Testing
@testable import Shimbashi

@Suite struct PromptsTests {
    private let prompt = Prompts.systemPrompt(recap: nil, struggles: [])

    @Test func tutorMustAlwaysSpeakJapanese() {
        #expect(prompt.contains("Always speak Japanese"))
        #expect(prompt.contains("even when the learner speaks English"))
        #expect(prompt.contains("Never answer in English"))
    }

    @Test func theOldEscapeHatchesForEnglishAreGone() {
        // These phrasings let the tutor answer "how do I say X?" in English
        // (a reply of "Check-in, onegaishimasu. This means …").
        #expect(!prompt.contains("mostly in Japanese"))
        #expect(!prompt.contains("in English is fine"))
    }

    @Test func japaneseIsSaidAsJapaneseNotRomaji() {
        #expect(prompt.contains("Never spell it out in romaji"))
    }

    @Test func aHowDoISayQuestionIsAnsweredInJapaneseOnly() {
        #expect(prompt.contains("in Japanese only"))
        #expect(prompt.contains("Don't give the English meaning out loud"))
    }

    @Test func theLanguageRuleComesBeforeAnyRecapOrStruggles() throws {
        let full = Prompts.systemPrompt(recap: "Learner: こんにちは", struggles: ["の vs が — mixed up"])
        let rule = try #require(full.range(of: "Always speak Japanese"))
        let recap = try #require(full.range(of: "Context from the learner's last session"))
        let struggles = try #require(full.range(of: "Things this learner has struggled with"))
        #expect(rule.lowerBound < recap.lowerBound)
        #expect(rule.lowerBound < struggles.lowerBound)
    }
}
