import Testing
import Foundation
@testable import Shimbashi

@Suite struct StruggleExtractorTests {
    @Test func emptyTranscriptShortCircuitsWithoutCallingClient() async throws {
        let fake = FakeTextGenerator(.fixed("should never be returned"))
        let extractor = StruggleExtractor(client: fake)
        let analysis = try await extractor.analyze(transcript: "")
        #expect(analysis.summary == "")
        #expect(analysis.struggles.isEmpty)
        #expect(await fake.callCount == 0)
    }

    @Test func whitespaceOnlyTranscriptShortCircuits() async throws {
        let fake = FakeTextGenerator(.fixed("should never be returned"))
        let extractor = StruggleExtractor(client: fake)
        let analysis = try await extractor.analyze(transcript: "   \n\t  ")
        #expect(analysis.summary == "")
        #expect(await fake.callCount == 0)
    }

    @Test func happyPath() async throws {
        let fake = FakeTextGenerator(.fixed(#"""
        {"summary":"You practiced greetings.","struggles":[{"phrase":"こんにちは","note":"pronunciation"}]}
        """#))
        let extractor = StruggleExtractor(client: fake)
        let analysis = try await extractor.analyze(transcript: "Learner: こんにちは\nTutor: こんにちは")
        #expect(analysis.summary == "You practiced greetings.")
        #expect(analysis.struggles.count == 1)
        #expect(analysis.struggles[0].phrase == "こんにちは")
        #expect(await fake.callCount == 1)
    }

    @Test func robustToSurroundingProse() async throws {
        let fake = FakeTextGenerator(.fixed(
            "Sure, here's my analysis:\n{\"summary\":\"Good session.\",\"struggles\":[]}\nLet me know if you need more."
        ))
        let extractor = StruggleExtractor(client: fake)
        let analysis = try await extractor.analyze(transcript: "some transcript")
        #expect(analysis.summary == "Good session.")
    }

    @Test func throwsOnMalformedJSON() async {
        let fake = FakeTextGenerator(.fixed("{not json}"))
        let extractor = StruggleExtractor(client: fake)
        await #expect(throws: (any Error).self) {
            try await extractor.analyze(transcript: "some transcript")
        }
    }

    @Test func throwsNoJSONFoundWhenNoBraces() async {
        let fake = FakeTextGenerator(.fixed("no braces here at all"))
        let extractor = StruggleExtractor(client: fake)
        await #expect(throws: StruggleExtractor.ExtractorError.noJSONFound) {
            try await extractor.analyze(transcript: "some transcript")
        }
    }
}
