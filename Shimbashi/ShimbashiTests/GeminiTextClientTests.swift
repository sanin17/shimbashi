import Testing
import Foundation
@testable import Shimbashi

/// Own protocol class (not shared with the key-validator tests): static
/// stub state plus Swift Testing's parallel suites would otherwise let the
/// two suites overwrite each other's responses.
private final class TextClientStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responses: [Result<(Int, Data), any Error>] = []
    nonisolated(unsafe) static var requestCount = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
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

    private func client(retryDelays: [Duration] = [.milliseconds(1), .milliseconds(1)]) -> GeminiTextClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TextClientStubProtocol.self]
        var client = GeminiTextClient(apiKey: "test-key")
        client.session = URLSession(configuration: configuration)
        client.retryDelays = retryDelays
        return client
    }

    private func script(_ responses: [Result<(Int, Data), any Error>]) {
        TextClientStubProtocol.responses = responses
        TextClientStubProtocol.requestCount = 0
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
        script(Array(repeating: .success((503, Data())), count: 10))
        await #expect(throws: (any Error).self) {
            try await client().generate(system: "s", userMessage: "u")
        }
        // 1 attempt + 2 retries.
        #expect(TextClientStubProtocol.requestCount == 3)
    }

    @Test func noRetriesWhenBudgetIsEmpty() async {
        script([.success((503, Data())), .success((200, Self.okBody))])
        await #expect(throws: (any Error).self) {
            try await client(retryDelays: []).generate(system: "s", userMessage: "u")
        }
        #expect(TextClientStubProtocol.requestCount == 1)
    }
}
