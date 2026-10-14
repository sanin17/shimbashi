import AVFAudio


public enum AudioEngineError: Error, Sendable {
    case microphonePermissionDenied
    case noInputAvailable
    case converterUnavailable
}

/// The single `AVAudioEngine` for the app. Capture and playback share it
/// deliberately: echo cancellation needs the far-end (playback) signal as its
/// reference, so routing playback through a separate engine or `AVAudioPlayer`
/// would leave AEC with nothing to cancel against, and the model would hear
/// and interrupt itself.
@MainActor
public final class VoiceIOEngine {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let session = AudioSessionController.shared

    private var micContinuation: AsyncStream<AudioChunk>.Continuation?
    private var micContext: MicTapContext?
    private var playbackQueue: AudioPlaybackQueue?
    private var sessionEventTask: Task<Void, Never>?
    private var configChangeObserver: NSObjectProtocol?
    /// Whether the mic tap is deliberately removed between utterances (see
    /// `pauseCapture`/`resumeCapture`) — distinct from `isRunning`, which
    /// tracks the whole engine. Checked by `rebuildTapAfterConfigurationChange`
    /// so a route change (e.g. headphones) during a paused gap doesn't
    /// silently resume capture the learner didn't ask for.
    private var isCapturePaused = false

    public private(set) var isRunning = false
    /// The format buffers passed to `enqueuePlayback` must be built in —
    /// whatever the hardware/mixer actually negotiated, known only once
    /// `start()` has run.
    public private(set) var playbackFormat: AVAudioFormat?

    public init() {}

    /// Requests mic permission, configures and activates the session, builds
    /// the capture→convert→chunk graph, and starts the engine. The returned
    /// stream yields ~100ms chunks until `stop()` is called or the stream is
    /// cancelled.
    public func start() async throws -> AsyncStream<AudioChunk> {
        guard await session.requestMicrophonePermission() else {
            throw AudioEngineError.microphonePermissionDenied
        }
        try session.activate()

        var continuationBox: AsyncStream<AudioChunk>.Continuation?
        let stream = AsyncStream<AudioChunk>(bufferingPolicy: .bufferingNewest(20)) { continuation in
            continuationBox = continuation
        }
        guard let continuation = continuationBox else {
            throw AudioEngineError.converterUnavailable
        }
        micContinuation = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }

        // Order matters: attach/connect the playback graph BEFORE enabling
        // voice processing. Doing it the other way around is a documented
        // trap — VoiceProcessingIO can activate with no output bus connected
        // yet, producing buffers that schedule successfully but never
        // actually reach the speaker.
        try buildPlaybackGraph()
        try enableVoiceProcessing()
        try buildCaptureGraph(continuation: continuation)
        engine.prepare()
        try engine.start()
        player.play()
        isRunning = true
        isCapturePaused = false
        observeSessionEvents()

        return stream
    }

    /// Removes the mic tap without touching anything else — playback and
    /// the engine itself keep running (rebuilding the whole graph per
    /// utterance would risk the voice-processing ordering bug already hit
    /// once this session). Used between push-to-talk utterances so iOS's
    /// microphone-in-use indicator can actually turn off while nothing is
    /// listening, rather than staying lit for the whole visit.
    public func pauseCapture() {
        guard isRunning, !isCapturePaused else { return }
        engine.inputNode.removeTap(onBus: 0)
        micContext = nil
        isCapturePaused = true
    }

    /// Reinstalls the mic tap after `pauseCapture()`, reusing the same
    /// `AsyncStream` continuation handed back from `start()` so the caller
    /// never sees a new stream. A no-op if capture isn't currently paused
    /// (e.g. called right after a fresh `start()`, which already installed
    /// a tap of its own).
    public func resumeCapture() throws {
        guard isRunning, isCapturePaused, let continuation = micContinuation else { return }
        let hardwareFormat = engine.inputNode.outputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            throw AudioEngineError.noInputAvailable
        }
        guard let context = MicTapContext(
            hardwareFormat: hardwareFormat,
            targetFormat: PCMFormats.captureTarget,
            continuation: continuation
        ) else {
            throw AudioEngineError.converterUnavailable
        }
        micContext = context
        installCaptureTap(context: context, format: hardwareFormat)
        isCapturePaused = false
    }

    /// Shared by `buildCaptureGraph`, `rebuildTapAfterConfigurationChange`,
    /// and `resumeCapture`. Explicitly `@Sendable`: `AVAudioNodeTapBlock`
    /// predates Swift concurrency and isn't marked `Sendable` in the
    /// overlay, so under this toolchain's default `MainActor` isolation, a
    /// closure written inline here would otherwise be inferred as
    /// `MainActor`-isolated — and crash the instant CoreAudio invokes it
    /// from the realtime audio thread (Swift's own isolation check traps
    /// via `dispatch_assert_queue`). This annotation forces it to be
    /// genuinely nonisolated, which is what it needs to be.
    private func installCaptureTap(context: MicTapContext, format: AVAudioFormat) {
        engine.inputNode.installTap(onBus: 0, bufferSize: 4_096, format: format) { @Sendable [context] buffer, time in
            context.ingest(buffer, at: time)
        }
    }

    public func stop() {
        guard isRunning else {
            return
        }
        sessionEventTask?.cancel()
        sessionEventTask = nil
        if let configChangeObserver {
            NotificationCenter.default.removeObserver(configChangeObserver)
        }
        configChangeObserver = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        session.deactivate()
        micContinuation?.finish()
        micContinuation = nil
        micContext = nil
        playbackQueue = nil
        isRunning = false
    }

    public func setMuted(_ muted: Bool) {
        micContext?.setMuted(muted)
    }

    public func enqueuePlayback(_ pcm16LE: Data) {
        playbackQueue?.enqueue(pcm16LE: pcm16LE)
    }

    public func endPlaybackTurn() {
        playbackQueue?.endTurn()
    }

    public func flushForBargeIn() {
        playbackQueue?.flushForBargeIn()
    }

    // MARK: - Graph construction

    /// Attach and connect the player before voice processing is enabled —
    /// see the comment in `start()`. Connect using whatever the hardware
    /// naturally reports at this point (commonly 44.1kHz or 48kHz stereo),
    /// not a fixed format — the mixer handles arbitrary sample-rate
    /// conversion fine, so it only needs to be a real, valid format, not
    /// necessarily the exact one voice processing later settles on.
    private func buildPlaybackGraph() throws {
        if player.engine == nil {
            engine.attach(player)
        }
        let playerFormat = engine.outputNode.outputFormat(forBus: 0)
        engine.connect(player, to: engine.mainMixerNode, format: playerFormat)
        playbackFormat = playerFormat
        playbackQueue = AudioPlaybackQueue(player: player, format: playerFormat)
    }

    /// Must happen with the engine stopped and after the playback graph is
    /// already attached (see `start()`). Enabling on the input node
    /// auto-enables it on the paired output node too.
    private func enableVoiceProcessing() throws {
        try engine.inputNode.setVoiceProcessingEnabled(true)
    }

    private func buildCaptureGraph(continuation: AsyncStream<AudioChunk>.Continuation) throws {
        let input = engine.inputNode

        // Only valid to read after voice processing is enabled and the
        // session is active — before that it reports a bogus zero format.
        let hardwareFormat = input.outputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            throw AudioEngineError.noInputAvailable
        }

        guard let context = MicTapContext(
            hardwareFormat: hardwareFormat,
            targetFormat: PCMFormats.captureTarget,
            continuation: continuation
        ) else {
            throw AudioEngineError.converterUnavailable
        }
        micContext = context
        installCaptureTap(context: context, format: hardwareFormat)

        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.rebuildTapAfterConfigurationChange() }
        }
    }

    /// The hardware format (and therefore the converter) can go stale after a
    /// route change — Bluetooth connect/disconnect, headphones, etc. Rebuild
    /// just the tap and converter against the current format; the mixer
    /// handles arbitrary output rates on its own, so playback needs no
    /// rebuilding, and reusing the existing continuation means the caller
    /// never needs to know this happened.
    private func rebuildTapAfterConfigurationChange() {
        // Deliberately paused between push-to-talk utterances — a route
        // change (headphones, Bluetooth) shouldn't silently resume capture
        // the learner didn't ask for.
        guard isRunning, !isCapturePaused, let continuation = micContinuation else { return }
        engine.inputNode.removeTap(onBus: 0)

        let hardwareFormat = engine.inputNode.outputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0,
              let context = MicTapContext(
                hardwareFormat: hardwareFormat,
                targetFormat: PCMFormats.captureTarget,
                continuation: continuation
              ) else { return }
        micContext = context
        installCaptureTap(context: context, format: hardwareFormat)

        if !engine.isRunning {
            try? engine.start()
            player.play()
        }
    }

    // MARK: - Session events

    private func observeSessionEvents() {
        sessionEventTask = Task { [weak self] in
            guard let self else { return }
            for await event in await self.session.events() {
                await self.handle(event)
            }
        }
    }

    private func handle(_ event: AudioSystemEvent) {
        // TEMPORARY DEBUG
        debugLog("[DEBUG VoiceIOEngine] audio system event: \(event), isRunning=\(isRunning)")
        switch event {
        case .interruptionBegan:
            engine.pause()

        case .interruptionEnded(let shouldResume):
            guard shouldResume, isRunning else {
                debugLog("[DEBUG VoiceIOEngine] NOT resuming after interruption — shouldResume=\(shouldResume), isRunning=\(isRunning)")
                return
            }
            do {
                try session.activate()
                try engine.start()
                player.play()
                debugLog("[DEBUG VoiceIOEngine] resumed after interruption")
            } catch {
                debugLog("[DEBUG VoiceIOEngine] FAILED to resume after interruption: \(error)")
            }

        case .routeChanged(let deviceUnavailable):
            guard deviceUnavailable, isRunning else { return }
            engine.pause()
            do {
                try session.activate()
                try engine.start()
                player.play()
                debugLog("[DEBUG VoiceIOEngine] resumed after route change")
            } catch {
                debugLog("[DEBUG VoiceIOEngine] FAILED to resume after route change: \(error)")
            }

        case .mediaServicesReset:
            // Rare, and both the session and the engine need rebuilding from
            // scratch. Rather than silently reconstructing a graph the caller
            // doesn't know changed, finish the stream — the caller's
            // `for await` loop ends, `stop()` runs via `onTermination`, and
            // it's the caller's decision (Phase 3's session supervisor)
            // whether to call `start()` again.
            stop()
        }
    }
}
