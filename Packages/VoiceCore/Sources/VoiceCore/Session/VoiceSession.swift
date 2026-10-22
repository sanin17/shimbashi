import Foundation

/// The single public entry point for a spoken conversation: owns the audio
/// engine and the Gemini Live connection, and turns their combined events
/// into observable state a SwiftUI view can bind to directly.
///
/// Push-to-talk, not always-listening: the connection stays open across a
/// whole visit, but the mic is only actually sent to the server between a
/// `beginTurn()` and the matching `endTurn()` — the server's own automatic
/// voice-activity detection is disabled (see `GeminiLiveSession`), so
/// nothing gets transcribed as speech unless the learner explicitly taps to
/// talk. `beginTurn()` doubles as barge-in: it always flushes whatever the
/// model was saying, whether or not anything actually was.
@MainActor
@Observable
public final class VoiceSession {
    public enum Phase: Sendable, Equatable {
        case idle
        case connecting
        case active
        /// Briefly set around an automatic reconnect (ahead of Gemini's
        /// ~10 minute connection cap, or after an unexpected drop) — audio
        /// capture keeps running underneath, this just tells the UI not to
        /// treat the gap as a failure.
        case reconnecting
        case failed(String)
    }

    private let engine = VoiceIOEngine()
    private let liveSession: GeminiLiveSession
    private var micPumpTask: Task<Void, Never>?
    private var eventPumpTask: Task<Void, Never>?

    /// Bumped on every `beginTurn()` that (re)connects. A rapid stop-then-start
    /// can leave the previous session's event-pump task still unwinding
    /// (cancellation doesn't stop a `for await` loop until the underlying
    /// stream actually finishes) — without this, that stale task's "stream
    /// finished" cleanup can fire after the new session is already `.active`
    /// and incorrectly stomp it back to `.failed`.
    private var generation = 0

    public private(set) var phase: Phase = .idle
    /// Whether the mic is currently being sent to the server — `false` most
    /// of the time even while connected, since capture only happens between
    /// `beginTurn()` and `endTurn()`.
    public private(set) var isRecording = false
    public private(set) var isMuted = false
    /// Only meaningful while `isRecording` — reads 0 the rest of the time,
    /// since nothing is being captured to meter.
    public private(set) var inputLevel: Float = 0
    public private(set) var partialUserText = ""
    public private(set) var partialModelText = ""
    public private(set) var turns: [Turn] = []
    /// Accumulates the model's own audio chunks alongside `partialModelText`,
    /// reset together with it in `finalizeModelTurnIfNeeded`.
    private var pendingModelAudio = Data()

    /// Kept only to scrub it out of error text — the key rides in the
    /// WebSocket URL's query string, and a URLError's description includes
    /// the failing URL, which would otherwise land on screen and in logs.
    private let apiKey: String

    public init(config: LiveSessionConfig, apiKey: String) {
        self.apiKey = apiKey
        self.liveSession = GeminiLiveSession(config: config, apiKey: apiKey)
    }

    private func redacted(_ error: Error) -> String {
        var text = "\(error)"
        if !apiKey.isEmpty {
            text = text.replacingOccurrences(of: apiKey, with: "<redacted>")
        }
        // Belt and braces: any `key=...` query value, in case the string
        // appears in a percent-encoded or otherwise altered form.
        return text.replacingOccurrences(
            of: #"key=[^&\s"')]+"#,
            with: "key=<redacted>",
            options: .regularExpression
        )
    }

    /// Call when the learner taps Start. Connects first if this is the very
    /// first turn of the visit; otherwise reuses the already-open connection.
    /// Always flushes local playback first — every new turn is implicitly a
    /// barge-in on whatever the model was saying, and finalizes that partial
    /// reply as a real turn rather than silently dropping it.
    public func beginTurn() async {
        // TEMPORARY DEBUG
        debugLog("[DEBUG VoiceSession] beginTurn() called, phase=\(phase), isRecording=\(isRecording)")
        guard !isRecording else { return }
        if phase == .idle || isFailed {
            await connect()
            guard phase == .active else {
                debugLog("[DEBUG VoiceSession] beginTurn() aborted, connect() left phase=\(phase)")
                return
            }
        }
        guard phase == .active || phase == .reconnecting else {
            debugLog("[DEBUG VoiceSession] beginTurn() ignored, phase=\(phase)")
            return
        }

        // No-ops on the very first turn of the visit (connect() just
        // installed a fresh tap of its own); reinstalls the tap `endTurn()`
        // removed for every turn after that.
        do {
            try engine.resumeCapture()
        } catch {
            debugLog("[DEBUG VoiceSession] resumeCapture() failed: \(error)")
        }
        engine.flushForBargeIn()
        finalizeModelTurnIfNeeded()
        // Sent before flipping isRecording (which is what gates the mic pump
        // forwarding audio) so activityStart can never race a mic chunk to
        // the server — both go through the same actor-isolated connection,
        // but this ordering makes the guarantee explicit rather than relying
        // on scheduling luck.
        await liveSession.sendActivityStart()
        isRecording = true
        debugLog("[DEBUG VoiceSession] beginTurn() sent activityStart, isRecording=true")
    }

    /// Call when the learner taps Stop. Tells the server the utterance is
    /// complete (it starts responding) and stops sending mic audio — the
    /// connection itself stays open until `endConversation()`.
    public func endTurn() async {
        // TEMPORARY DEBUG
        debugLog("[DEBUG VoiceSession] endTurn() called, isRecording=\(isRecording)")
        guard isRecording else { return }
        isRecording = false
        inputLevel = 0
        engine.pauseCapture()
        await liveSession.sendActivityEnd()
        debugLog("[DEBUG VoiceSession] endTurn() sent activityEnd")
    }

    /// Call when the learner is done for this visit — tears the connection
    /// down entirely (as opposed to `endTurn()`, which just closes out one
    /// utterance).
    public func endConversation() async {
        // TEMPORARY DEBUG
        debugLog("[DEBUG VoiceSession] endConversation() called, phase=\(phase)")
        // A deliberate end must never be mistaken for a dropped connection.
        // Tearing down finishes the event stream, and the pump that watches
        // it would otherwise run its "stream ended unexpectedly" branch
        // *after* this method sets `.idle` below, leaving the session
        // `.failed("Connection closed")` — shown as a red error when the
        // learner just locked their phone. Bumping the generation retires
        // that pump first.
        generation += 1
        if isRecording {
            await endTurn()
        }
        await teardownConnection()
        phase = .idle
        partialUserText = ""
        partialModelText = ""
        // turns is deliberately left as-is — a subsequent beginTurn() clears
        // it, so the transcript from a just-ended conversation (and its
        // cached breakdowns/translations) stays visible until a genuinely
        // new one begins.
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    private func connect() async {
        generation += 1
        let myGeneration = generation
        phase = .connecting
        turns = []
        do {
            let micStream = try await engine.start()
            try await liveSession.start()
            // Captured once, right after start() creates this run's fresh
            // stream — reading `liveSession.events` again later (e.g. inside
            // the Task closure) would risk picking up whatever a subsequent
            // start() has since replaced it with.
            let eventStream = await liveSession.events
            phase = .active

            micPumpTask = Task { @MainActor in
                for await chunk in micStream {
                    guard myGeneration == self.generation else { return }
                    guard self.isRecording else { continue }
                    self.inputLevel = chunk.rms
                    await self.liveSession.send(audio: chunk.pcm16LE)
                }
            }

            eventPumpTask = Task { @MainActor in
                for await event in eventStream {
                    guard myGeneration == self.generation else { return }
                    self.handle(event)
                }
                guard myGeneration == self.generation else { return }
                // The event stream only finishes when the connection is gone
                // for good — either explicitly stopped (phase already .idle
                // by then) or the reconnect retry budget was exhausted. Tear
                // the engine down too — otherwise it's left running (mic tap
                // installed, player active) with nothing consuming it, and a
                // later beginTurn() would try to rebuild an already-running
                // engine on top of itself.
                if self.phase == .active || self.phase == .reconnecting {
                    // TEMPORARY DEBUG
                    debugLog("[DEBUG VoiceSession] event stream ended from phase \(self.phase), tearing down")
                    await self.teardownConnection()
                    let failure = await self.liveSession.terminalFailure
                    self.phase = .failed(failure?.message ?? "Connection closed")
                }
            }
        } catch {
            guard myGeneration == self.generation else { return }
            // TEMPORARY DEBUG
            debugLog("[DEBUG VoiceSession] connect() threw: \(redacted(error))")
            // engine.start() may have already succeeded before
            // liveSession.start() threw — tear it back down rather than
            // leaving it running under a `.failed` phase.
            await teardownConnection()
            phase = .failed(redacted(error))
        }
    }

    /// Cancels the mic/event pumps and shuts down both the live connection
    /// and the audio engine. Leaves `phase` untouched — callers set it
    /// afterward, since what the transition means differs: `.idle` for a
    /// deliberate `endConversation()`, `.failed` for an unexpected drop.
    private func teardownConnection() async {
        micPumpTask?.cancel()
        eventPumpTask?.cancel()
        micPumpTask = nil
        eventPumpTask = nil
        isRecording = false
        inputLevel = 0
        await liveSession.stop()
        engine.stop()
    }

    public func setMuted(_ muted: Bool) {
        isMuted = muted
        engine.setMuted(muted)
    }

    public func sendText(_ text: String) async {
        await liveSession.sendText(text)
    }

    private func handle(_ event: LiveServerEvent) {
        switch event {
        case .setupComplete:
            // TEMPORARY DEBUG
            debugLog("[DEBUG VoiceSession] setupComplete — server accepted the session setup")

        case .inputTranscriptionDelta(let text):
            // TEMPORARY DEBUG
            debugLog("[DEBUG VoiceSession] inputTranscriptionDelta: \"\(text)\" (partialUserText was: \"\(partialUserText)\")")
            partialUserText = (partialUserText + text).removingSpacesBetweenJapanese

        case .outputTranscriptionDelta(let text):
            // The model starting to talk is the signal the user's turn ended
            // — Gemini doesn't send an explicit "user turn complete" marker.
            finalizeUserTurnIfNeeded()
            // TEMPORARY DEBUG
            debugLog("[DEBUG VoiceSession] outputTranscriptionDelta: \"\(text)\" (partialModelText was: \"\(partialModelText)\")")
            partialModelText = (partialModelText + text).removingSpacesBetweenJapanese

        case .modelAudio(let data):
            engine.enqueuePlayback(data)
            pendingModelAudio.append(data)

        case .interrupted:
            // Automatic activity detection is disabled (see
            // GeminiLiveSession.pushToTalkConfig), so the server has no VAD
            // of its own to trigger this — barge-in now happens entirely
            // client-side, in beginTurn(). Handled defensively in case it
            // ever still fires.
            engine.flushForBargeIn()
            finalizeModelTurnIfNeeded()

        case .turnComplete:
            engine.endPlaybackTurn()
            finalizeModelTurnIfNeeded()

        case .goAway, .sessionResumptionUpdate:
            // Purely informational at this layer — GeminiLiveSession already
            // acts on both internally to drive the reconnect below.
            break

        case .reconnecting:
            // Finalize whatever was mid-flight so it isn't silently dropped
            // across the connection swap — audio capture and playback keep
            // running underneath; only the transport blips.
            finalizeUserTurnIfNeeded()
            finalizeModelTurnIfNeeded()
            phase = .reconnecting

        case .reconnected:
            phase = .active
        }
    }

    private func finalizeUserTurnIfNeeded() {
        guard !partialUserText.isEmpty else { return }
        let turn = Turn(speaker: .user, text: partialUserText)
        // TEMPORARY DEBUG
        debugLog("[DEBUG VoiceSession] finalizeUserTurnIfNeeded() id=\(turn.id): \"\(partialUserText)\", turns.count will be \(turns.count + 1)")
        turns.append(turn)
        partialUserText = ""
    }

    private func finalizeModelTurnIfNeeded() {
        guard !partialModelText.isEmpty else { return }
        let turn = Turn(speaker: .model, text: partialModelText, audio: pendingModelAudio.isEmpty ? nil : pendingModelAudio)
        // TEMPORARY DEBUG
        debugLog("[DEBUG VoiceSession] finalizeModelTurnIfNeeded() id=\(turn.id): \"\(partialModelText)\", turns.count will be \(turns.count + 1), audioBytes=\(pendingModelAudio.count)")
        turns.append(turn)
        partialModelText = ""
        pendingModelAudio = Data()
    }
}
