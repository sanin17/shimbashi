import Foundation
import AVFoundation

/// Synthesizes and plays a one-off audio clip for a specific string — the
/// "hear this again" feature on turns and breakdown phrases. Deliberately
/// separate from VoiceCore's live-conversation audio engine: that's a
/// full-duplex, echo-cancelled pipeline built around one WebSocket
/// connection, overkill (and risky to interfere with) for just playing a
/// short clip — a plain `AVAudioPlayer` is the right tool here.
@MainActor
@Observable
final class SpeechPlaybackController {
    enum PlaybackState: Equatable {
        case idle
        case loading
        case playing
        case failed
        /// Hit the TTS model's free-tier rate limit (its own preview quota,
        /// separate from the rest of the app's Gemini usage) — clears itself
        /// after a few seconds rather than needing a retry tap.
        case rateLimited
    }

    /// Whether the active clip came from a fresh network TTS call or from
    /// already-on-device audio — surfaced so `PlayButton` can show whether a
    /// given tap is hitting Gemini or is free/instant local processing.
    enum AudioSource: Equatable {
        case network
        case cached
    }

    /// The exact string currently loading/playing, so a `PlayButton` can
    /// tell whether it's the one active among however many are on screen —
    /// only one clip plays at a time.
    private(set) var activeText: String?
    private(set) var activeSource: AudioSource?
    private(set) var state: PlaybackState = .idle

    private let client: SpeechClient
    private var player: AVAudioPlayer?
    /// Guards against a slow synthesis call from an earlier tap resolving
    /// after a newer one has already taken over — same pattern as
    /// `VoiceSession`'s generation counter.
    private var generation = 0
    /// Every `synthesize()` result this controller has ever fetched, keyed
    /// by the exact text spoken — a repeat tap on the same phrase (a
    /// breakdown phrase re-played, or a main sentence with no `cachedPCM16`)
    /// reuses this instead of paying for another TTS call. Never evicted:
    /// one controller lives for the whole Conversation screen, and a
    /// session's worth of short phrase clips is a trivial amount of memory.
    private var synthesisCache: [String: Data] = [:]

    init(client: SpeechClient) {
        self.client = client
    }

    /// `cachedPCM16`, when non-nil, is the model's own already-streamed
    /// reply audio (`Turn.audio`/`DisplayTurn.audio`) — wrapped in a WAV
    /// header and played directly, skipping a fresh `synthesize()` call
    /// entirely. `nil` for user turns and for individual breakdown phrases
    /// (no per-phrase audio alignment exists), which still synthesize on tap
    /// as before.
    func play(_ text: String, cachedPCM16: Data? = nil) {
        guard !text.isEmpty else { return }
        generation += 1
        let myGeneration = generation
        player?.stop()
        player = nil
        activeText = text
        let hasCachedSynthesis = cachedPCM16 == nil && synthesisCache[text] != nil
        activeSource = (cachedPCM16 != nil || hasCachedSynthesis) ? .cached : .network
        state = .loading
        // TEMPORARY DEBUG
        debugLog("[DEBUG SpeechPlaybackController] play(\"\(text)\") starting, generation=\(myGeneration), cachedAudio=\(cachedPCM16 != nil), cachedSynthesis=\(hasCachedSynthesis)")

        Task {
            do {
                let data: Data
                if let cachedPCM16 {
                    data = SpeechClient.wavData(fromPCM16: cachedPCM16, sampleRate: 24_000, channels: 1)
                    debugLog("[DEBUG SpeechPlaybackController] using cached reply audio, \(cachedPCM16.count) PCM bytes -> \(data.count) WAV bytes")
                } else if let cached = synthesisCache[text] {
                    data = cached
                    debugLog("[DEBUG SpeechPlaybackController] using cached synthesis, \(data.count) bytes")
                } else {
                    data = try await client.synthesize(text)
                    synthesisCache[text] = data
                    debugLog("[DEBUG SpeechPlaybackController] synthesize returned \(data.count) bytes (myGen=\(myGeneration), currentGen=\(generation))")
                }
                guard myGeneration == generation else {
                    debugLog("[DEBUG SpeechPlaybackController] stale generation, discarding result")
                    return
                }
                try activatePlaybackSession()
                debugLog("[DEBUG SpeechPlaybackController] session category=\(AVAudioSession.sharedInstance().category.rawValue), outputVolume=\(AVAudioSession.sharedInstance().outputVolume)")
                let newPlayer = try AVAudioPlayer(data: data)
                let prepared = newPlayer.prepareToPlay()
                let started = newPlayer.play()
                debugLog("[DEBUG SpeechPlaybackController] AVAudioPlayer created: duration=\(newPlayer.format.sampleRate)Hz/\(newPlayer.format.channelCount)ch, prepareToPlay=\(prepared), play()=\(started), isPlaying=\(newPlayer.isPlaying), volume=\(newPlayer.volume)")
                player = newPlayer
                state = .playing

                let duration = newPlayer.duration
                try? await Task.sleep(for: .seconds(duration + 0.2))
                guard myGeneration == generation else { return }
                state = .idle
                activeText = nil
                activeSource = nil
                debugLog("[DEBUG SpeechPlaybackController] playback finished naturally")
            } catch {
                debugLog("[DEBUG SpeechPlaybackController] play(\"\(text)\") failed: \(error)")
                guard myGeneration == generation else { return }
                if Self.isRateLimited(error) {
                    // Keep activeText set so the specific button that was
                    // tapped can show the rate-limited state, not just any
                    // button — cleared only once this self-clears below.
                    state = .rateLimited
                    try? await Task.sleep(for: .seconds(3))
                    guard myGeneration == generation else { return }
                    state = .idle
                    activeText = nil
                    activeSource = nil
                } else {
                    state = .failed
                    activeText = nil
                    activeSource = nil
                }
            }
        }
    }

    private static func isRateLimited(_ error: Error) -> Bool {
        if case SpeechClient.SpeechError.requestFailed(let status, _) = error {
            return status == 429
        }
        return false
    }

    func stop() {
        generation += 1
        player?.stop()
        player = nil
        activeText = nil
        activeSource = nil
        state = .idle
    }

    /// Leaves an already-active `.playAndRecord` session (a live
    /// conversation in progress) alone — switching it to `.playback` would
    /// drop the mic. Otherwise activates `.playback` so this plays reliably
    /// regardless of the silent switch, matching how the live conversation
    /// already behaves.
    private func activatePlaybackSession() throws {
        let session = AVAudioSession.sharedInstance()
        if session.category != .playAndRecord {
            try session.setCategory(.playback, mode: .default)
        }
        try session.setActive(true)
    }
}
