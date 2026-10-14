import Testing
import Foundation
@testable import VoiceCore

@Suite struct LiveFailureTests {
    private func classify(
        status: Int? = nil,
        code: Int? = nil,
        reason: String? = nil,
        error: Error? = nil
    ) -> LiveFailure {
        LiveFailure.classify(
            error: error,
            diagnostics: ChannelDiagnostics(httpStatus: status, closeCode: code, closeReason: reason)
        )
    }

    @Test func rejectedHandshakeIsInvalidKey() {
        #expect(classify(status: 400) == .invalidKey)
        #expect(classify(status: 401) == .invalidKey)
        #expect(classify(status: 403) == .invalidKey)
    }

    @Test func tooManyRequestsIsQuota() {
        #expect(classify(status: 429) == .quotaExceeded)
    }

    @Test func closeReasonTextClassifiesQuotaAndKey() {
        #expect(classify(code: 1011, reason: "You exceeded your current quota") == .quotaExceeded)
        #expect(classify(code: 1011, reason: "RESOURCE_EXHAUSTED") == .quotaExceeded)
        #expect(classify(code: 1007, reason: "API key not valid. Please pass a valid API key.") == .invalidKey)
    }

    @Test func quotaWinsOverPolicyViolationCode() {
        // 1008 alone reads as a key problem, but an explicit quota reason
        // on the same close must take precedence.
        #expect(classify(code: 1008, reason: "quota exceeded") == .quotaExceeded)
        #expect(classify(code: 1008) == .invalidKey)
    }

    @Test func offlineErrorsAreNetwork() {
        #expect(classify(error: URLError(.notConnectedToInternet)) == .network)
        #expect(classify(error: URLError(.networkConnectionLost)) == .network)
        #expect(classify(error: URLError(.timedOut)) == .network)
    }

    @Test func unknownAndCleanClosesAreOther() {
        #expect(classify() == .other)
        #expect(classify(status: 101, code: 1000) == .other)
        #expect(classify(error: URLError(.cancelled)) == .other)
    }

    @Test func onlyKeyAndQuotaStopRetrying() {
        #expect(LiveFailure.invalidKey.isTerminal)
        #expect(LiveFailure.quotaExceeded.isTerminal)
        #expect(!LiveFailure.network.isTerminal)
        #expect(!LiveFailure.other.isTerminal)
    }

    @Test func messagesNeverEchoServerText() {
        // Messages are fixed strings: nothing from the server (or a URL
        // carrying the key) can end up on screen through them.
        for failure in [LiveFailure.invalidKey, .quotaExceeded, .network, .other] {
            #expect(!failure.message.contains("key="))
            #expect(!failure.message.isEmpty)
        }
    }
}
