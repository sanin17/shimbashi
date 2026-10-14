import Foundation
@testable import VoiceCore

/// Scripted `WebSocketChannel` fake — lets `GeminiLiveConnectionTests` and
/// `GeminiLiveSessionTests` drive inbound messages/failures and inspect what
/// was sent, without a real socket. Built on `CheckedContinuation` rather
/// than an `AsyncStream` iterator stored on the actor — mutating an
/// `AsyncIterator` through actor-isolated optional state doesn't type-check
/// cleanly under Swift 6 strict concurrency; a one-shot continuation avoids
/// the problem entirely. `close()` is a protocol requirement declared
/// non-async, so it must be `nonisolated` to satisfy it from an actor — same
/// pattern as `GeminiLiveConnection.send(_:)`'s nonisolated yield into an
/// `AsyncStream.Continuation`.
actor FakeWebSocketChannel: WebSocketChannel {
    enum FakeChannelError: Error {
        case streamEnded
    }

    /// Lock-protected box so `diagnostics` (a synchronous protocol
    /// requirement) can be `nonisolated` on this actor.
    private final class DiagnosticsBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = ChannelDiagnostics()
        var value: ChannelDiagnostics {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); defer { lock.unlock() }; stored = newValue }
        }
    }
    private let diagnosticsBox = DiagnosticsBox()

    nonisolated var diagnostics: ChannelDiagnostics { diagnosticsBox.value }

    /// Sets what `diagnostics` reports — call before simulating a failure
    /// to script why the "server" ended the connection.
    nonisolated func setDiagnostics(_ value: ChannelDiagnostics) {
        diagnosticsBox.value = value
    }

    private(set) var sentMessages: [String] = []
    private var sendError: (any Error)?
    private var pendingMessages: [Result<URLSessionWebSocketTask.Message, any Error>] = []
    private var waitingContinuation: CheckedContinuation<Result<URLSessionWebSocketTask.Message, any Error>, Never>?
    private var isFinished = false

    func setSendError(_ error: (any Error)?) {
        sendError = error
    }

    func send(_ text: String) async throws {
        if let sendError { throw sendError }
        sentMessages.append(text)
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await nextResult().get()
    }

    private func nextResult() async -> Result<URLSessionWebSocketTask.Message, any Error> {
        if !pendingMessages.isEmpty {
            return pendingMessages.removeFirst()
        }
        if isFinished {
            return .failure(FakeChannelError.streamEnded)
        }
        return await withCheckedContinuation { continuation in
            waitingContinuation = continuation
        }
    }

    nonisolated func close() {
        Task { await self.finish() }
    }

    private func finish() {
        isFinished = true
        waitingContinuation?.resume(returning: .failure(FakeChannelError.streamEnded))
        waitingContinuation = nil
    }

    func enqueue(json: String) {
        deliver(.success(.string(json)))
    }

    func simulateReceiveFailure(_ error: any Error) {
        deliver(.failure(error))
    }

    private func deliver(_ result: Result<URLSessionWebSocketTask.Message, any Error>) {
        if let continuation = waitingContinuation {
            waitingContinuation = nil
            continuation.resume(returning: result)
        } else {
            pendingMessages.append(result)
        }
    }
}
