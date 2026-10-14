import Testing
import Foundation
@testable import VoiceCore

private struct StubError: Error {}

private func waitUntil(timeout: Duration = .seconds(2), _ condition: () async -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while await !condition(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
}

private func minimalSetup() -> LiveSetupFrame {
    LiveSetupFrame(setup: .init(model: "models/gemini-live", generationConfig: .init()))
}

@Suite struct GeminiLiveConnectionTests {
    @Test func setupFrameIsSentBeforeQueuedFrames() async throws {
        let channel = FakeWebSocketChannel()
        let connection = GeminiLiveConnection(channel: channel)
        connection.send("queued-before-start")

        try await connection.start(setup: minimalSetup())
        await waitUntil { await channel.sentMessages.count == 2 }

        let sent = await channel.sentMessages
        #expect(sent.count == 2)
        #expect(sent[0].contains("\"model\":\"models\\/gemini-live\"") || sent[0].contains("\"model\":\"models/gemini-live\""))
        #expect(sent[1] == "queued-before-start")
    }

    @Test func inboundJSONProducesEvents() async throws {
        let channel = FakeWebSocketChannel()
        let connection = GeminiLiveConnection(channel: channel)
        await channel.enqueue(json: #"{"setupComplete":{}}"#)

        try await connection.start(setup: minimalSetup())

        var iterator = connection.events.makeAsyncIterator()
        let event = await iterator.next()
        #expect(event == .setupComplete)
    }

    @Test func receiveFailureFinishesEventStream() async throws {
        let channel = FakeWebSocketChannel()
        let connection = GeminiLiveConnection(channel: channel)
        try await connection.start(setup: minimalSetup())

        await channel.simulateReceiveFailure(StubError())

        var iterator = connection.events.makeAsyncIterator()
        let event = await iterator.next()
        #expect(event == nil)
    }

    @Test func sendFailureDoesNotFinishEventStream() async throws {
        // Documents current behavior: the writer loop swallows a send
        // failure internally (see GeminiLiveConnection's writer Task catch
        // block) — only a *receive* failure ends the event stream. The
        // reader loop keeps working even though every send (including the
        // setup frame itself) is failing.
        let channel = FakeWebSocketChannel()
        await channel.setSendError(StubError())
        let connection = GeminiLiveConnection(channel: channel)
        try await connection.start(setup: minimalSetup())

        await channel.enqueue(json: #"{"setupComplete":{}}"#)

        var iterator = connection.events.makeAsyncIterator()
        let event = await iterator.next()
        #expect(event == .setupComplete)
    }
}
