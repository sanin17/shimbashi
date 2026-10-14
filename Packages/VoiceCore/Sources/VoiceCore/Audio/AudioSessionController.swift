import AVFAudio


/// Session-level events a caller needs to react to. Deliberately separate from
/// `.AVAudioEngineConfigurationChange`, which is posted on the `AVAudioEngine`
/// instance itself and is `VoiceIOEngine`'s concern, not the session's.
public enum AudioSystemEvent: Sendable {
    case interruptionBegan
    case interruptionEnded(shouldResume: Bool)
    case routeChanged(deviceUnavailable: Bool)
    case mediaServicesReset
}

/// Owns `AVAudioSession` configuration and mic permission, and turns its
/// notification-based interruption/route/reset events into an `AsyncStream`.
@MainActor
public final class AudioSessionController {
    public static let shared = AudioSessionController()

    private var continuation: AsyncStream<AudioSystemEvent>.Continuation?
    private var observers: [NSObjectProtocol] = []

    private init() {}

    public func requestMicrophonePermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    /// Configures the session for two-way voice with echo cancellation and
    /// activates it. Call before touching `AVAudioEngine.inputNode`.
    public func activate() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker]
        )
        try session.setPreferredSampleRate(48_000)
        try session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true)
        if session.currentRoute.outputs.first?.portType != .builtInSpeaker {
            try? session.overrideOutputAudioPort(.speaker)
        }
    }

    public func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// One stream per subscriber; observers are installed on first subscription
    /// and torn down when that stream terminates.
    public func events() -> AsyncStream<AudioSystemEvent> {
        AsyncStream { continuation in
            self.continuation = continuation
            self.installObservers(continuation: continuation)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.removeObservers() }
            }
        }
    }

    /// `NotificationCenter.addObserver(forName:object:queue:using:)` requires an
    /// `@Sendable` block, which is not implicitly `@MainActor`-isolated even
    /// though this class is — so these closures parse the notification and yield
    /// directly through the captured (Sendable) continuation, rather than
    /// reaching back into `self` and crossing an actor boundary with a
    /// non-Sendable `Notification`.
    private func installObservers(continuation: AsyncStream<AudioSystemEvent>.Continuation) {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { note in
            guard let event = Self.parseInterruption(note) else { return }
            continuation.yield(event)
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { note in
            guard let event = Self.parseRouteChange(note) else { return }
            continuation.yield(event)
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { _ in
            continuation.yield(.mediaServicesReset)
        })
    }

    private func removeObservers() {
        let center = NotificationCenter.default
        observers.forEach { center.removeObserver($0) }
        observers.removeAll()
        continuation = nil
    }

    nonisolated private static func parseInterruption(_ note: Notification) -> AudioSystemEvent? {
        guard let info = note.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return nil }
        switch type {
        case .began:
            return .interruptionBegan
        case .ended:
            var shouldResume = false
            if let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt {
                shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsValue).contains(.shouldResume)
            }
            return .interruptionEnded(shouldResume: shouldResume)
        @unknown default:
            return nil
        }
    }

    nonisolated private static func parseRouteChange(_ note: Notification) -> AudioSystemEvent? {
        guard let info = note.userInfo,
              let reasonValue = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return nil }
        return .routeChanged(deviceUnavailable: reason == .oldDeviceUnavailable)
    }
}
