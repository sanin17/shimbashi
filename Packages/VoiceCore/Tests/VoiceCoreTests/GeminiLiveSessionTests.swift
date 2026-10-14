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

/// Hands out a fresh `FakeWebSocketChannel` per call and records every one
/// created, so a test can inspect what each successive reconnect actually
/// sent. Plain lock-protected class, not an actor: `GeminiLiveSession`'s
/// `channelFactory` is a synchronous closure (same reasoning as
/// `GeminiLiveConnection.send(_:)` being `nonisolated` — no actor hop on
/// this path in production either), so an async actor call can't sit inside
/// it.
private final class ChannelFactorySpy: @unchecked Sendable {
    private let lock = NSLock()
    private var _createdChannels: [FakeWebSocketChannel] = []

    var createdChannels: [FakeWebSocketChannel] {
        lock.lock()
        defer { lock.unlock() }
        return _createdChannels
    }

    func makeChannel(for url: URL) -> FakeWebSocketChannel {
        let channel = FakeWebSocketChannel()
        lock.lock()
        _createdChannels.append(channel)
        lock.unlock()
        return channel
    }
}

@Suite struct GeminiLiveSessionTests {
    @Test func startOpensAConnectionThroughTheFactory() async throws {
        let spy = ChannelFactorySpy()
        let session = GeminiLiveSession(config: .init(), apiKey: "key", channelFactory: spy.makeChannel)
        try await session.start()
        await waitUntil { spy.createdChannels.count == 1 }
        #expect(spy.createdChannels.count == 1)
    }

    @Test func startThrowsAlreadyStartedOnDoubleStart() async throws {
        let spy = ChannelFactorySpy()
        let session = GeminiLiveSession(config: .init(), apiKey: "key", channelFactory: spy.makeChannel)
        try await session.start()
        await #expect(throws: GeminiLiveSession.SessionError.alreadyStarted) {
            try await session.start()
        }
    }

    @Test func resumptionHandleIsCarriedIntoNextConnectSetupFrame() async throws {
        let spy = ChannelFactorySpy()
        let session = GeminiLiveSession(config: .init(), apiKey: "key", channelFactory: spy.makeChannel)
        try await session.start()
        await waitUntil { spy.createdChannels.count == 1 }

        let eventsStream = await session.events
        var iterator = eventsStream.makeAsyncIterator()

        let firstChannel = spy.createdChannels[0]
        await firstChannel.enqueue(json: #"{"sessionResumptionUpdate":{"newHandle":"resume-token","resumable":true}}"#)
        let firstEvent = await iterator.next()
        #expect(firstEvent == .sessionResumptionUpdate(handle: "resume-token", resumable: true))

        // Drop the connection — should trigger a reactive reconnect that
        // resends the last resumption handle in its setup frame.
        await firstChannel.simulateReceiveFailure(StubError())
        await waitUntil { spy.createdChannels.count == 2 }

        let secondChannelSent = await spy.createdChannels[1].sentMessages
        #expect(secondChannelSent.first?.contains("\"handle\":\"resume-token\"") == true)
    }

    @Test func nonResumableHandleIsNotPersisted() async throws {
        let spy = ChannelFactorySpy()
        let session = GeminiLiveSession(config: .init(), apiKey: "key", channelFactory: spy.makeChannel)
        try await session.start()
        await waitUntil { spy.createdChannels.count == 1 }

        let eventsStream = await session.events
        var iterator = eventsStream.makeAsyncIterator()

        let firstChannel = spy.createdChannels[0]
        await firstChannel.enqueue(json: #"{"sessionResumptionUpdate":{"newHandle":"should-not-be-used","resumable":false}}"#)
        _ = await iterator.next()

        await firstChannel.simulateReceiveFailure(StubError())
        await waitUntil { spy.createdChannels.count == 2 }

        let secondChannelSent = await spy.createdChannels[1].sentMessages
        #expect(secondChannelSent.first?.contains("should-not-be-used") == false)
    }

    @Test func stopPreventsFurtherReconnects() async throws {
        let spy = ChannelFactorySpy()
        let session = GeminiLiveSession(config: .init(), apiKey: "key", channelFactory: spy.makeChannel)
        try await session.start()
        await waitUntil { spy.createdChannels.count == 1 }

        await session.stop()
        let firstChannel = spy.createdChannels[0]
        await firstChannel.simulateReceiveFailure(StubError())

        // Give any (incorrect) reconnect attempt a moment to happen, then
        // confirm it didn't.
        try? await Task.sleep(for: .milliseconds(100))
        #expect(spy.createdChannels.count == 1)
    }

    /// Regression test for a real bug found while writing this suite:
    /// `attemptReconnect`'s retry counter used to reset to 1 at the top of
    /// every `beginReconnect()` cycle, so a persistently broken connection
    /// (where `connect()` itself never throws — real I/O failures surface
    /// later, asynchronously, as a `receive()` failure) retried forever,
    /// logging "attempt 1 succeeded" every time, never giving up. Fixed by
    /// making `reconnectAttempts` persist across cycles, only resetting once
    /// `handleConnectionEvent` sees a real event proving the connection is
    /// actually healthy — this test drives repeated failures with no real
    /// event ever arriving, so the budget should now be exhausted after
    /// exactly `maxReconnectAttempts` (3) reconnects.
    @Test func repeatedConnectionFailuresAreBoundedByTheRetryBudget() async throws {
        let spy = ChannelFactorySpy()
        let session = GeminiLiveSession(config: .init(), apiKey: "key", channelFactory: spy.makeChannel)
        try await session.start()
        await waitUntil { spy.createdChannels.count == 1 }

        let eventsStream = await session.events
        var iterator = eventsStream.makeAsyncIterator()

        for _ in 0..<5 {
            let countBefore = spy.createdChannels.count
            guard let last = spy.createdChannels.last else { break }
            await last.simulateReceiveFailure(StubError())
            await waitUntil(timeout: .seconds(1)) { spy.createdChannels.count > countBefore }
        }

        // 1 initial connection + 3 retries (maxReconnectAttempts) = 4 total,
        // then no more, no matter how many further failures are simulated.
        #expect(spy.createdChannels.count == 4)

        // Budget exhaustion should finish the event stream — draining it
        // should terminate (bounded, so a regression here hangs instead of
        // silently passing) rather than waiting forever for more events.
        var drainedToNil = false
        for _ in 0..<50 {
            guard await iterator.next() != nil else {
                drainedToNil = true
                break
            }
        }
        #expect(drainedToNil)
    }

    /// A rejected key can't be fixed by reconnecting, so the session must
    /// give up on the first failure rather than spend the retry budget — and
    /// say why, so the app can tell the learner to check their key.
    @Test func rejectedKeyStopsImmediatelyAndReportsWhy() async throws {
        let spy = ChannelFactorySpy()
        let session = GeminiLiveSession(config: .init(), apiKey: "key", channelFactory: spy.makeChannel)
        try await session.start()
        await waitUntil { spy.createdChannels.count == 1 }

        let eventsStream = await session.events
        var iterator = eventsStream.makeAsyncIterator()

        let channel = try #require(spy.createdChannels.first)
        channel.setDiagnostics(ChannelDiagnostics(httpStatus: 400))
        await channel.simulateReceiveFailure(StubError())

        var drainedToNil = false
        for _ in 0..<50 {
            guard await iterator.next() != nil else {
                drainedToNil = true
                break
            }
        }
        #expect(drainedToNil)
        #expect(spy.createdChannels.count == 1)
        #expect(await session.terminalFailure == .invalidKey)
    }

    @Test func exhaustedBudgetReportsTheLastObservedFailure() async throws {
        let spy = ChannelFactorySpy()
        let session = GeminiLiveSession(config: .init(), apiKey: "key", channelFactory: spy.makeChannel)
        try await session.start()
        await waitUntil { spy.createdChannels.count == 1 }

        for _ in 0..<5 {
            let countBefore = spy.createdChannels.count
            guard let last = spy.createdChannels.last else { break }
            last.setDiagnostics(ChannelDiagnostics())
            await last.simulateReceiveFailure(URLError(.notConnectedToInternet))
            await waitUntil(timeout: .seconds(1)) { spy.createdChannels.count > countBefore }
        }
        await waitUntil(timeout: .seconds(2)) { await session.terminalFailure != nil }
        #expect(await session.terminalFailure == .network)
    }
}
