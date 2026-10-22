import Testing
import Foundation
@testable import Shimbashi

/// Own protocol class: static stub state is shared across a suite's tests,
/// and Swift Testing runs suites in parallel.
private final class SpeechStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responses: [(Int, Data)] = []
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        let (status, body) = Self.responses.isEmpty ? (500, Data()) : Self.responses.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized) struct SpeechClientTests {
    // MARK: helpers

    private static func responseJSON(audio: Data, extraSteps: String = "") -> Data {
        let step = #"{"type":"model_output","content":[{"type":"audio","data":"\#(audio.base64EncodedString())","sample_rate":24000,"channels":1}]}"#
        let steps = extraSteps.isEmpty ? step : "\(extraSteps),\(step)"
        return Data(#"{"steps":[\#(steps)]}"#.utf8)
    }

    private func client(models: [String]? = nil) -> SpeechClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SpeechStubProtocol.self]
        var client = SpeechClient(apiKey: "test-key")
        client.session = URLSession(configuration: configuration)
        if let models { client.models = models }
        return client
    }

    private func script(_ responses: [(Int, Data)]) {
        SpeechStubProtocol.responses = responses
        SpeechStubProtocol.requests = []
    }

    private func requestedModel(at index: Int) throws -> String {
        let body = try #require(SpeechStubProtocol.requests[index].httpBodyStreamData())
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        return try #require(json["model"] as? String)
    }

    // MARK: request shape

    @Test func requestUsesTheTypedInputShapeAndVerbatimText() throws {
        let body = SpeechClient.requestBody(text: "こんにちは", model: "gemini-3.8-flash-tts")
        #expect(body["model"] as? String == "gemini-3.8-flash-tts")

        let input = try #require(body["input"] as? [[String: Any]])
        #expect(input.count == 1)
        #expect(input[0]["type"] as? String == "user_input")
        let content = try #require(input[0]["content"] as? [[String: Any]])
        #expect(content.first?["type"] as? String == "text")
        #expect(content.first?["text"] as? String == "こんにちは")

        #expect((body["response_format"] as? [String: Any])?["type"] as? String == "audio")
        let config = try #require((body["generation_config"] as? [String: Any])?["speech_config"] as? [[String: Any]])
        #expect(config.first?["voice"] as? String == "Kore")
    }

    // MARK: response handling

    @Test func wavResponseIsPlayedAsIsNotWrappedAgain() throws {
        let pcm = Data(repeating: 0x7F, count: 100)
        let wav = SpeechClient.wavData(fromPCM16: pcm, sampleRate: 24_000, channels: 1)
        let result = try SpeechClient.playableAudio(fromResponse: Self.responseJSON(audio: wav))
        #expect(result == wav)
        #expect(result.count == pcm.count + 44)
    }

    @Test func rawPCMResponseGetsExactlyOneHeader() throws {
        let pcm = Data(repeating: 0x01, count: 64)
        let result = try SpeechClient.playableAudio(fromResponse: Self.responseJSON(audio: pcm))
        #expect(result.starts(with: Data("RIFF".utf8)))
        #expect(result.count == pcm.count + 44)
    }

    @Test func stepsWithoutContentAreIgnored() throws {
        let pcm = Data(repeating: 0x02, count: 32)
        let extra = #"{"type":"user_input"},{"type":"thought"}"#
        let result = try SpeechClient.playableAudio(fromResponse: Self.responseJSON(audio: pcm, extraSteps: extra))
        #expect(result.count == pcm.count + 44)
    }

    @Test func responseWithNoAudioThrows() {
        #expect(throws: SpeechClient.SpeechError.self) {
            try SpeechClient.playableAudio(fromResponse: Data(#"{"steps":[{"type":"model_output","content":[{"type":"text"}]}]}"#.utf8))
        }
        #expect(throws: SpeechClient.SpeechError.self) {
            try SpeechClient.playableAudio(fromResponse: Data(#"{}"#.utf8))
        }
    }

    // MARK: model failover

    @Test func throttledFirstModelFailsOverToTheSecond() async throws {
        let pcm = Data(repeating: 0x03, count: 16)
        script([(429, Data()), (200, Self.responseJSON(audio: pcm))])
        let audio = try await client().synthesize("はい")
        #expect(audio.count == pcm.count + 44)
        #expect(SpeechStubProtocol.requests.count == 2)
        #expect(try requestedModel(at: 0) == "gemini-3.8-flash-tts")
        #expect(try requestedModel(at: 1) == "gemini-3.8-flash-lite-tts")
    }

    @Test func unavailableFirstModelFailsOverToTheSecond() async throws {
        script([(404, Data()), (200, Self.responseJSON(audio: Data(repeating: 1, count: 8)))])
        _ = try await client().synthesize("はい")
        #expect(SpeechStubProtocol.requests.count == 2)
    }

    @Test func rejectedKeyDoesNotTryTheSecondModel() async {
        script([(403, Data()), (200, Self.responseJSON(audio: Data(repeating: 1, count: 8)))])
        await #expect(throws: SpeechClient.SpeechError.self) {
            try await client().synthesize("はい")
        }
        #expect(SpeechStubProtocol.requests.count == 1)
    }

    @Test func bothThrottledSurfacesTheRateLimitForTheUI() async {
        script([(429, Data()), (429, Data())])
        do {
            _ = try await client().synthesize("はい")
            Issue.record("expected a throw")
        } catch SpeechClient.SpeechError.requestFailed(let status, _) {
            // SpeechPlaybackController maps a 429 to its transient
            // "rate limited" state, so the last error must stay a 429.
            #expect(status == 429)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func keyTravelsInHeaderNeverInTheURL() async throws {
        script([(200, Self.responseJSON(audio: Data(repeating: 1, count: 8)))])
        _ = try await client().synthesize("はい")
        let request = try #require(SpeechStubProtocol.requests.first)
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "test-key")
        #expect(request.url?.absoluteString.contains("test-key") == false)
    }
}

private extension URLRequest {
    /// `URLProtocol` receives the body as a stream, not `httpBody`.
    func httpBodyStreamData() -> Data? {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: 4096)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
