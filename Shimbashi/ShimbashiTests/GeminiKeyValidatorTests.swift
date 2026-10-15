import Testing
import Foundation
@testable import Shimbashi

/// Intercepts requests on a private `URLSession` so these tests never touch
/// the network. State is static because `URLProtocol` is instantiated by the
/// loading system, not by the test; the suite is `.serialized` for that
/// reason.
private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var respond: ((URLRequest) throws -> (Int, Data))?
    nonisolated(unsafe) static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        do {
            guard let respond = Self.respond else { throw URLError(.badServerResponse) }
            let (status, body) = try respond(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@Suite(.serialized) struct GeminiKeyValidatorTests {
    private func validator() -> GeminiKeyValidator {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return GeminiKeyValidator(session: URLSession(configuration: configuration))
    }

    private func outcome(status: Int) async -> GeminiKeyValidator.Outcome {
        StubURLProtocol.respond = { _ in (status, Data("{}".utf8)) }
        return await validator().validate("test-key")
    }

    @Test func acceptedKeyIsValid() async {
        #expect(await outcome(status: 200) == .valid)
    }

    @Test func googleRejectionIsRejected() async {
        // 400 is how Google answers API_KEY_INVALID.
        #expect(await outcome(status: 400) == .rejected)
        #expect(await outcome(status: 401) == .rejected)
        #expect(await outcome(status: 403) == .rejected)
    }

    @Test func throttledKeyIsStillACorrectKey() async {
        #expect(await outcome(status: 429) == .rateLimited)
    }

    @Test func unexpectedStatusIsReportedWithItsCode() async {
        #expect(await outcome(status: 503) == .unknown(status: 503))
    }

    @Test func networkFailureIsUnreachable() async {
        StubURLProtocol.respond = { _ in throw URLError(.notConnectedToInternet) }
        #expect(await validator().validate("test-key") == .unreachable)
    }

    @Test func keyTravelsInHeaderNeverInTheURL() async throws {
        StubURLProtocol.respond = { _ in (200, Data("{}".utf8)) }
        _ = await validator().validate("secret-key-123")

        let request = try #require(StubURLProtocol.lastRequest)
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "secret-key-123")
        #expect(request.url?.absoluteString.contains("secret-key-123") == false)
        #expect(request.url?.query?.contains("key=") != true)
    }
}
