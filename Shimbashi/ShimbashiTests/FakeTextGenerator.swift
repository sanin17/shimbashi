import Foundation
@testable import Shimbashi

/// Scripted `GeminiTextGenerating` fake shared across `TranslationServiceTests`,
/// `StruggleExtractorTests`, and `ConversationCoordinatorTests` — an actor
/// since production code calls `generate` from detached `Task`s.
actor FakeTextGenerator: GeminiTextGenerating {
    enum Behavior {
        case fixed(String)
        case sequence([String])
        case throwing(any Error)
        /// A scripted mix of successes and failures, popped one per call —
        /// e.g. fail once then succeed, to test a retry path.
        case results([Result<String, any Error>])
    }

    enum FakeError: Error {
        case exhausted
    }

    private var behavior: Behavior
    private(set) var callCount = 0
    private(set) var lastSystemPrompt: String?
    private(set) var lastUserMessage: String?

    init(_ behavior: Behavior) {
        self.behavior = behavior
    }

    func generate(system: String, userMessage: String) async throws -> String {
        callCount += 1
        lastSystemPrompt = system
        lastUserMessage = userMessage
        switch behavior {
        case .fixed(let text):
            return text
        case .sequence(let texts):
            guard let next = texts.first else { throw FakeError.exhausted }
            behavior = .sequence(Array(texts.dropFirst()))
            return next
        case .throwing(let error):
            throw error
        case .results(let results):
            guard let next = results.first else { throw FakeError.exhausted }
            behavior = .results(Array(results.dropFirst()))
            return try next.get()
        }
    }
}
