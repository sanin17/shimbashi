import Testing
import Foundation
@testable import Shimbashi

@Suite struct TranslationServiceTests {
    @Test func translateHappyPath() async throws {
        let fake = FakeTextGenerator(.fixed(#"{"romaji":"Konnichiwa","english":"Hello"}"#))
        let service = TranslationService(client: fake)
        let result = try await service.translate("こんにちは")
        #expect(result.romaji == "Konnichiwa")
        #expect(result.english == "Hello")
    }

    @Test func translateIsRobustToSurroundingProseAndCodeFences() async throws {
        let fake = FakeTextGenerator(.fixed(
            "Here you go:\n```json\n{\"romaji\":\"Arigatou\",\"english\":\"Thank you\"}\n```\nHope that helps!"
        ))
        let service = TranslationService(client: fake)
        let result = try await service.translate("ありがとう")
        #expect(result.romaji == "Arigatou")
        #expect(result.english == "Thank you")
    }

    @Test func translateThrowsNoJSONFoundWhenNoBraces() async {
        let fake = FakeTextGenerator(.fixed("I'm not sure how to translate that."))
        let service = TranslationService(client: fake)
        await #expect(throws: TranslationService.TranslationError.noJSONFound) {
            try await service.translate("???")
        }
    }

    @Test func translateThrowsOnMalformedJSON() async {
        let fake = FakeTextGenerator(.fixed("{this is not valid json}"))
        let service = TranslationService(client: fake)
        await #expect(throws: (any Error).self) {
            try await service.translate("test")
        }
    }

    @Test func breakdownHappyPath() async throws {
        let fake = FakeTextGenerator(.fixed(#"[{"japanese":"こんにちは","romaji":"konnichiwa","english":"hello"}]"#))
        let service = TranslationService(client: fake)
        let phrases = try await service.breakdown("こんにちは")
        #expect(phrases.count == 1)
        #expect(phrases[0].japanese == "こんにちは")
    }

    @Test func breakdownThrowsNoJSONFoundWhenNoBrackets() async {
        let fake = FakeTextGenerator(.fixed("no array here"))
        let service = TranslationService(client: fake)
        await #expect(throws: TranslationService.TranslationError.noJSONFound) {
            try await service.breakdown("test")
        }
    }

    @Test func analyzeReplyHappyPath() async throws {
        let fake = FakeTextGenerator(.fixed(#"""
        {"romaji":"Ohayou","english":"Good morning","phrases":[{"japanese":"おはよう","romaji":"ohayou","english":"good morning"}]}
        """#))
        let service = TranslationService(client: fake)
        let analysis = try await service.analyzeReply("おはよう")
        #expect(analysis.romaji == "Ohayou")
        #expect(analysis.english == "Good morning")
        #expect(analysis.phrases.count == 1)
    }

    @Test func analyzeReplyThrowsOnMalformedJSON() async {
        let fake = FakeTextGenerator(.fixed("{\"romaji\":\"x\""))
        let service = TranslationService(client: fake)
        await #expect(throws: (any Error).self) {
            try await service.analyzeReply("test")
        }
    }
}
