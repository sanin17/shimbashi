import Foundation

/// Owns one Gemini Live conversation across however many physical
/// `GeminiLiveConnection`s it takes — the server closes each connection
/// after roughly ten minutes regardless of context length, so this
/// transparently reconnects using the last session-resumption handle rather
/// than surfacing that as a failure. Reconnection happens two ways: proactively,
/// a few seconds ahead of the deadline the server announces via `goAway`, and
/// reactively, if a connection drops with no warning (network blip). Callers
/// see `.reconnecting`/`.reconnected` on `events` and otherwise never need to
/// know a reconnect happened.
actor GeminiLiveSession {
    enum SessionError: Error, Sendable {
        case invalidURL
        case alreadyStarted
    }

    private static let endpoint = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
    /// Reconnect this long before the server's own `goAway` deadline, to
    /// leave time for a fresh handshake before the old socket actually closes.
    private static let reconnectLeadTime: TimeInterval = 3
    private static let maxReconnectAttempts = 3

    private let config: LiveSessionConfig
    private let apiKey: String
    private let channelFactory: @Sendable (URL) -> any WebSocketChannel
    private var connection: GeminiLiveConnection?
    private var resumptionHandle: String?
    private var forwardTask: Task<Void, Never>?
    /// Why the session ended for good, once it has — set only when retrying
    /// can't help (bad key, quota) or the retry budget ran out. `nil` for a
    /// deliberate stop. Read by `VoiceSession` when `events` finishes.
    private(set) var terminalFailure: LiveFailure?
    private var lastObservedFailure: LiveFailure?
    private var reconnectDeadlineTask: Task<Void, Never>?
    private var isStopped = false
    private var isReconnecting = false
    /// Consecutive reconnect cycles since the connection was last confirmed
    /// genuinely healthy (see `handleConnectionEvent`, which resets this to
    /// 0 the moment any real event arrives from the server). Persists
    /// *across* `beginReconnect()` calls — unlike a counter scoped to one
    /// cycle, this is what actually bounds a persistently broken connection:
    /// `connect()` itself essentially never throws for a real I/O failure
    /// (those surface later, asynchronously, as a `receive()` failure), so a
    /// counter that reset to 1 at the top of every `beginReconnect()` would
    /// report "attempt 1 succeeded" forever and never give up.
    private var reconnectAttempts = 0

    private var eventContinuation: AsyncStream<LiveServerEvent>.Continuation
    /// Spans one `start()`...`stop()` lifetime, not any one physical
    /// connection within it — a reconnect never finishes this stream, only
    /// `stop()` or exhausting the reconnect retry budget does. Recreated at
    /// the top of every `start()` (not just once in `init`): an
    /// `AsyncStream.Continuation`, once `finish()`d by a prior `stop()`, stays
    /// finished forever — reusing it would make every `for await` over
    /// `events` after the first `start()`/`stop()` cycle see zero events and
    /// immediately (and wrongly) look like the new connection failed.
    private(set) var events: AsyncStream<LiveServerEvent>

    public init(config: LiveSessionConfig, apiKey: String) {
        self.init(config: config, apiKey: apiKey, channelFactory: { URLSessionWebSocketChannel(url: $0) })
    }

    /// Test-only seam — lets `GeminiLiveSessionTests` script the transport
    /// layer with a fake channel instead of opening a real socket. Not
    /// `public`; the initializer above is the only production entry point.
    init(config: LiveSessionConfig, apiKey: String, channelFactory: @escaping @Sendable (URL) -> any WebSocketChannel) {
        self.config = config
        self.apiKey = apiKey
        self.channelFactory = channelFactory
        var continuation: AsyncStream<LiveServerEvent>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.eventContinuation = continuation
    }

    func start() async throws {
        guard connection == nil else { throw SessionError.alreadyStarted }
        isStopped = false
        isReconnecting = false
        reconnectAttempts = 0
        terminalFailure = nil
        lastObservedFailure = nil
        var continuation: AsyncStream<LiveServerEvent>.Continuation!
        events = AsyncStream { continuation = $0 }
        eventContinuation = continuation
        try await connect()
    }

    /// Opens one physical connection and wires its events into the
    /// session-spanning stream. Used for both the very first connection (via
    /// `start()`, which lets failure propagate to the caller) and each
    /// reconnect (via `attemptReconnect`, which retries instead).
    private func connect() async throws {
        var components = URLComponents(string: Self.endpoint)
        components?.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components?.url else { throw SessionError.invalidURL }

        // TEMPORARY DEBUG
        debugLog("[DEBUG GeminiLiveSession] connecting, model=\(config.model)")
        let channel = channelFactory(url)
        let newConnection = GeminiLiveConnection(channel: channel)

        var setup = LiveSetupFrame.Setup(
            model: config.model,
            generationConfig: .init(speechConfig: config.voiceName.map(LiveSetupFrame.SpeechConfig.init(voiceName:)))
        )
        setup.systemInstruction = config.systemInstruction.map(LiveSetupFrame.Content.init(text:))
        // Resending the last resumption handle is what makes this a
        // continuation of the same conversation server-side rather than a
        // blank connection — the model keeps its memory of the exchange so far.
        setup.sessionResumption = .init(handle: resumptionHandle)
        setup.realtimeInputConfig = Self.pushToTalkConfig
        try await newConnection.start(setup: LiveSetupFrame(setup: setup))

        connection = newConnection
        forwardTask = Task { [weak self] in
            for await event in newConnection.events {
                guard let self else { return }
                await self.handleConnectionEvent(event)
            }
            await self?.connectionDidEnd(of: newConnection)
        }
    }

    /// Push-to-talk: the server does no VAD of its own, and `VoiceSession`
    /// brackets each utterance with an explicit `activityStart`/`activityEnd`
    /// (sent via `sendActivityStart()`/`sendActivityEnd()` below) driven by
    /// the Start/Stop button rather than continuous always-listening capture.
    private static let pushToTalkConfig = LiveSetupFrame.RealtimeInputConfig(
        automaticActivityDetection: .init(disabled: true)
    )

    private func handleConnectionEvent(_ event: LiveServerEvent) {
        // Any real event means the server actually responded on this
        // connection — proof it's genuinely healthy, not just that a socket
        // was opened. Reset here, not on a bare successful `connect()`, so a
        // connection that opens but immediately dies again (the actual
        // failure mode this budget exists for) doesn't get a free pass.
        reconnectAttempts = 0
        if case .sessionResumptionUpdate(let handle, let resumable) = event, resumable {
            resumptionHandle = handle
        }
        if case .goAway(let timeLeft) = event {
            scheduleProactiveReconnect(timeLeft: timeLeft)
        }
        eventContinuation.yield(event)
    }

    private func scheduleProactiveReconnect(timeLeft: TimeInterval?) {
        guard let timeLeft else { return }
        reconnectDeadlineTask?.cancel()
        let delay = max(0, timeLeft - Self.reconnectLeadTime)
        reconnectDeadlineTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            await self.beginReconnect()
        }
    }

    /// Fires when a connection's event stream ends on its own — either the
    /// server closed the socket (the ~10 minute cap, possibly after a
    /// `goAway` this session missed reconnecting ahead of) or the network
    /// dropped it. `isStopped` distinguishes that from a deliberate `stop()`.
    private func connectionDidEnd(of ended: GeminiLiveConnection) async {
        // TEMPORARY DEBUG
        debugLog("[DEBUG GeminiLiveSession] connectionDidEnd, isStopped=\(isStopped)")
        guard !isStopped else { return }

        if let failure = await ended.lastFailure {
            lastObservedFailure = failure
            debugLog("[DEBUG GeminiLiveSession] connection ended: \(failure)")
            // A rejected key or exhausted quota won't be fixed by trying
            // again — stop now rather than spend three retries (and several
            // seconds of "Reconnecting…") arriving at the same answer.
            if failure.isTerminal {
                terminalFailure = failure
                reconnectDeadlineTask?.cancel()
                await connection?.close()
                connection = nil
                eventContinuation.finish()
                return
            }
        }
        await beginReconnect()
    }

    private func beginReconnect() async {
        // TEMPORARY DEBUG
        debugLog("[DEBUG GeminiLiveSession] beginReconnect, isStopped=\(isStopped), isReconnecting=\(isReconnecting), reconnectAttempts=\(reconnectAttempts)")
        guard !isStopped, !isReconnecting else { return }
        // Checked *before* attempting, not just inside attemptReconnect's
        // catch branch — connect() essentially never throws for a real I/O
        // failure (those surface later, asynchronously, as a receive()
        // failure that ends up back here via connectionDidEnd()), so a
        // budget check that only fires on a thrown error would never trip
        // for the actual failure mode this exists to bound.
        guard reconnectAttempts < Self.maxReconnectAttempts else {
            debugLog("[DEBUG GeminiLiveSession] reconnect budget exhausted, giving up")
            terminalFailure = lastObservedFailure ?? .other
            eventContinuation.finish()
            return
        }
        isReconnecting = true
        reconnectDeadlineTask?.cancel()
        await connection?.close()
        connection = nil
        eventContinuation.yield(.reconnecting)
        reconnectAttempts += 1
        await attemptReconnect()
    }

    private func attemptReconnect() async {
        guard !isStopped else { isReconnecting = false; return }
        do {
            try await connect()
            isReconnecting = false
            debugLog("[DEBUG GeminiLiveSession] reconnect succeeded (cycle \(reconnectAttempts))")
            eventContinuation.yield(.reconnected)
        } catch {
            // TEMPORARY DEBUG
            debugLog("[DEBUG GeminiLiveSession] reconnect attempt \(reconnectAttempts) FAILED: \(error)")
            guard reconnectAttempts < Self.maxReconnectAttempts else {
                debugLog("[DEBUG GeminiLiveSession] reconnect budget exhausted, giving up")
                isReconnecting = false
                terminalFailure = lastObservedFailure ?? .network
                eventContinuation.finish()
                return
            }
            try? await Task.sleep(for: .seconds(Double(reconnectAttempts) * 1.5))
            guard !isStopped else { isReconnecting = false; return }
            reconnectAttempts += 1
            await attemptReconnect()
        }
    }

    /// Queues one chunk of mic audio for the writer loop. Called from
    /// `VoiceSession`'s single sequential mic-pump loop, so sequential
    /// `await`s here preserve frame order without needing a nonisolated
    /// bypass — that optimization can be added later if profiling calls for it.
    func send(audio pcm16LE: Data) {
        connection?.send(LiveOutbound.realtimeAudio(base64: pcm16LE.base64EncodedString()))
    }

    func sendAudioStreamEnd() {
        connection?.send(LiveOutbound.audioStreamEnd)
    }

    /// Marks the start of the user's turn — required before sending any
    /// audio, since automatic detection is disabled (see `pushToTalkConfig`).
    func sendActivityStart() {
        connection?.send(LiveOutbound.activityStart)
    }

    /// Marks the end of the user's turn, telling the server to stop waiting
    /// for more audio and start responding.
    func sendActivityEnd() {
        connection?.send(LiveOutbound.activityEnd)
    }

    func sendText(_ text: String) {
        guard let data = LiveOutbound.text(text), let json = String(data: data, encoding: .utf8) else { return }
        connection?.send(json)
    }

    func stop() async {
        isStopped = true
        isReconnecting = false
        reconnectDeadlineTask?.cancel()
        reconnectDeadlineTask = nil
        forwardTask?.cancel()
        forwardTask = nil
        await connection?.close()
        connection = nil
        eventContinuation.finish()
    }
}
