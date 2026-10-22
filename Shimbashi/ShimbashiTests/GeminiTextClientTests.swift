import Testing
import Foundation
@testable import Shimbashi

/// Own protocol class (not shared with the key-validator tests): static
/// stub state plus Swift Testing's parallel suites would otherwise let the
/// two suites overwrite each other's responses.
private final class TextClientStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responses: [Result<(Int, Data), any Error>] = []
    nonisolated(unsafe) static var requestCount = 0
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
        Self.requests.append(request)
        let next = Self.responses.isEmpty ? .failure(URLError(.badServerResponse)) : Self.responses.removeFirst()
        switch next {
        case .success(let (status, body)):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@Suite(.serialized) struct GeminiTextClientTests {
    private static let okBody = Data(#"{"candidates":[{"content":{"parts":[{"text":"hello"}]}}]}"#.utf8)

    private func client(
        retryDelays: [Duration] = [.milliseconds(1), .milliseconds(1)],
        models: [String]? = nil
    ) -> GeminiTextClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TextClientStubProtocol.self]
        var client = GeminiTextClient(apiKey: "test-key")
        client.session = URLSession(configuration: configuration)
        client.retryDelays = retryDelays
        if let models { client.models = models }
        return client
    }

    private func script(_ responses: [Result<(Int, Data), any Error>]) {
        TextClientStubProtocol.responses = responses
        TextClientStubProtocol.requestCount = 0
        TextClientStubProtocol.requests = []
    }

    private func modelRequested(at index: Int) -> String {
        let path = TextClientStubProtocol.requests[index].url?.path ?? ""
        // .../models/<model>:generateContent
        return path.components(separatedBy: "/models/").last?.components(separatedBy: ":").first ?? ""
    }

    @Test func transientServerErrorIsRetriedAndSucceeds() async throws {
        script([.success((503, Data())), .success((200, Self.okBody))])
        let text = try await client().generate(system: "s", userMessage: "u")
        #expect(text == "hello")
        #expect(TextClientStubProtocol.requestCount == 2)
    }

    @Test func throttlingIsRetriedAndSucceeds() async throws {
        script([.success((429, Data())), .success((429, Data())), .success((200, Self.okBody))])
        let text = try await client().generate(system: "s", userMessage: "u")
        #expect(text == "hello")
        #expect(TextClientStubProtocol.requestCount == 3)
    }

    @Test func droppedConnectionIsRetried() async throws {
        script([.failure(URLError(.networkConnectionLost)), .success((200, Self.okBody))])
        let text = try await client().generate(system: "s", userMessage: "u")
        #expect(text == "hello")
        #expect(TextClientStubProtocol.requestCount == 2)
    }

    @Test func rejectedKeyIsNotRetried() async {
        script([.success((403, Data())), .success((200, Self.okBody))])
        await #expect(throws: (any Error).self) {
            try await client().generate(system: "s", userMessage: "u")
        }
        #expect(TextClientStubProtocol.requestCount == 1)
    }

    @Test func retryBudgetIsBounded() async {
        script(Array(repeating: .success((503, Data())), count: 20))
        await #expect(throws: (any Error).self) {
            try await client().generate(system: "s", userMessage: "u")
        }
        // 3 rounds (1 + 2 retries) x 2 models.
        #expect(TextClientStubProtocol.requestCount == 6)
    }

    @Test func noRetriesWhenBudgetIsEmpty() async {
        script([.success((503, Data())), .success((200, Self.okBody))])
        await #expect(throws: (any Error).self) {
            try await client(retryDelays: [], models: ["only-model"]).generate(system: "s", userMessage: "u")
        }
        #expect(TextClientStubProtocol.requestCount == 1)
    }

    @Test func overloadedPrimaryFailsOverToTheSecondModelAtOnce() async throws {
        script([.success((503, Data())), .success((200, Self.okBody))])
        // No retry budget at all: the second model must be tried anyway.
        let text = try await client(retryDelays: []).generate(system: "s", userMessage: "u")
        #expect(text == "hello")
        #expect(TextClientStubProtocol.requestCount == 2)
        #expect(modelRequested(at: 0) == "gemini-3.5-flash-lite")
        #expect(modelRequested(at: 1) == "gemini-3.6-flash")
    }

    @Test func unavailableModelIsSkippedWithoutWaiting() async throws {
        script([.success((404, Data())), .success((200, Self.okBody))])
        let text = try await client(retryDelays: []).generate(system: "s", userMessage: "u")
        #expect(text == "hello")
        #expect(TextClientStubProtocol.requestCount == 2)
    }

    @Test func allModelsUnavailableFailsWithoutRetryingTheRound() async {
        script(Array(repeating: .success((404, Data())), count: 10))
        await #expect(throws: (any Error).self) {
            try await client().generate(system: "s", userMessage: "u")
        }
        // One pass over both models; nothing transient, so no further rounds.
        #expect(TextClientStubProtocol.requestCount == 2)
    }

    @Test func keyTravelsInHeaderNeverInTheURL() async throws {
        script([.success((200, Self.okBody))])
        _ = try await client().generate(system: "s", userMessage: "u")
        let request = try #require(TextClientStubProtocol.requests.first)
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "test-key")
        #expect(request.url?.absoluteString.contains("test-key") == false)
    }
}
