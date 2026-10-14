import Foundation

/// One physical WebSocket connection to Gemini Live. Sends the setup frame,
/// then runs exactly one writer loop and one reader loop for the connection's
/// lifetime — `URLSessionWebSocketTask.receive()` must be called serially,
/// and a single writer loop guarantees outbound frame order without callers
/// ever awaiting into this actor on the hot path.
actor GeminiLiveConnection {
    enum ConnectionError: Error, Sendable {
        case encodingFailed
    }

    private let channel: any WebSocketChannel
    private let outboundStream: AsyncStream<String>
    private let outbound: AsyncStream<String>.Continuation
    private var writerTask: Task<Void, Never>?
    private var readerTask: Task<Void, Never>?
    private let eventContinuation: AsyncStream<LiveServerEvent>.Continuation

    /// Why the reader loop ended, set just before `events` finishes so a
    /// consumer that sees the stream end can ask what went wrong.
    private(set) var lastFailure: LiveFailure?

    /// Safe to iterate from outside the actor without `await` — `AsyncStream`
    /// itself is `Sendable` and its iteration doesn't touch actor-isolated state.
    nonisolated let events: AsyncStream<LiveServerEvent>

    init(channel: any WebSocketChannel) {
        self.channel = channel

        var outboundContinuation: AsyncStream<String>.Continuation!
        self.outboundStream = AsyncStream { outboundContinuation = $0 }
        self.outbound = outboundContinuation

        var eventContinuation: AsyncStream<LiveServerEvent>.Continuation!
        self.events = AsyncStream { eventContinuation = $0 }
        self.eventContinuation = eventContinuation
    }

    /// Encodes and sends the setup frame, then starts the steady-state
    /// reader/writer loops. Callers watch `events` for `.setupComplete` (or
    /// the stream finishing, on failure) rather than this blocking on the
    /// handshake — keeping this actor to exactly one reader and one writer,
    /// with no special-cased first message.
    func start(setup: LiveSetupFrame) throws {
        let setupData = try JSONEncoder().encode(setup)
        guard let setupJSON = String(data: setupData, encoding: .utf8) else {
            throw ConnectionError.encodingFailed
        }

        let channel = self.channel
        let outboundStream = self.outboundStream
        writerTask = Task {
            do {
                try await channel.send(setupJSON)
                for await frame in outboundStream {
                    try await channel.send(frame)
                }
            } catch {
                // TEMPORARY DEBUG
                debugLog("[DEBUG GeminiLiveConnection] writer loop failed: \(error)")
                // A send failure means the socket is dead; the reader loop's
                // receive() will throw too and finish the event stream.
            }
        }

        let eventContinuation = self.eventContinuation
        readerTask = Task {
            do {
                while true {
                    let message = try await channel.receive()
                    guard let data = Self.data(from: message) else { continue }
                    let decoded = try JSONDecoder().decode(LiveServerMessage.self, from: data)
                    let events = decoded.events()
                    for event in events {
                        eventContinuation.yield(event)
                    }
                }
            } catch {
                // TEMPORARY DEBUG
                debugLog("[DEBUG GeminiLiveConnection] reader loop failed: \(error)")
                // Recorded before finishing the stream, so whoever sees the
                // stream end can rely on it already being set.
                lastFailure = LiveFailure.classify(error: error, diagnostics: channel.diagnostics)
                eventContinuation.finish()
            }
        }
    }

    /// Queues a frame for the writer loop. No suspension, no actor hop — safe
    /// to call at 10Hz from the mic pump without ever awaiting into this actor.
    nonisolated func send(_ frame: String) {
        outbound.yield(frame)
    }

    func close() {
        writerTask?.cancel()
        readerTask?.cancel()
        outbound.finish()
        eventContinuation.finish()
        channel.close()
    }

    private static func data(from message: URLSessionWebSocketTask.Message) -> Data? {
        switch message {
        case .string(let text): return text.data(using: .utf8)
        case .data(let data): return data
        @unknown default: return nil
        }
    }
}
