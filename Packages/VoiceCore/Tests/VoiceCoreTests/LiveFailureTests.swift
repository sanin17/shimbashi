import Testing
import Foundation
@testable import VoiceCore

@Suite struct LiveFailureTests {
    private func classify(
        status: Int? = nil,
        code: Int? = nil,
        reason: String? = nil,
        error: Error? = nil,
        healthy: Bool = false
    ) -> LiveFailure {
        LiveFailure.classify(
            error: error,
            diagnostics: ChannelDiagnostics(httpStatus: status, closeCode: code, closeReason: reason),
            connectionWasHealthy: healthy
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

    @Test func policyViolationCodeAloneIsNotAKeyProblem() {
        // 1008 covers many unrelated server complaints; without wording
        // that actually says "key", it must not be reported as one.
        #expect(classify(code: 1008) == .other)
        #expect(classify(code: 1008, reason: "quota exceeded") == .quotaExceeded)
    }

    @Test func genericNotValidWordingIsNotAKeyProblem() {
        // e.g. a stale session-resumption handle on reconnect.
        #expect(classify(code: 1007, reason: "Session resumption handle is not valid") == .other)
    }

    @Test func aWorkingConnectionIsNeverBlamedOnTheKey() {
        // Same signals that read as a bad key on a fresh connection...
        #expect(classify(status: 403, healthy: false) == .invalidKey)
        #expect(classify(reason: "API key not valid", healthy: false) == .invalidKey)
        // ...mean something else once the connection has been talking.
        #expect(classify(status: 403, healthy: true) == .other)
        #expect(classify(reason: "API key not valid", healthy: true) == .other)
        #expect(classify(code: 1008, reason: "permission denied", healthy: true) == .other)
    }

    @Test func quotaCanStillRunOutMidConversation() {
        #expect(classify(code: 1011, reason: "You exceeded your current quota", healthy: true) == .quotaExceeded)
        #expect(classify(status: 429, healthy: true) == .quotaExceeded)
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
