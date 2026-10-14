import Testing
import AVFAudio
@testable import VoiceCore

@MainActor
@Suite struct AudioPlaybackQueueTests {
    /// `AudioPlaybackQueue.schedule(_:)` calls `AVAudioPlayerNode.scheduleBuffer`
    /// directly, which — confirmed by an earlier version of this test suite —
    /// raises an uncaught `NSException` and crashes the whole test process
    /// when the node was never attached to a real `AVAudioEngine`. Same for
    /// anything that reaches `schedule(_:)` (`endTurn()` flushing pending
    /// buffers) or touches `player.stop()/play()` directly
    /// (`flushForBargeIn()`) — none of those are safe to call here. Only
    /// `enqueue(pcm16LE:)` while staying under the ~150ms priming threshold
    /// is testable in isolation, since that path never touches the player at
    /// all. Exercising the rest of this class requires a real device/audio
    /// session — left to manual testing, same as `VoiceIOEngine`.
    @Test func enqueueBelowPrimeThresholdOnlyBuffersWithoutTouchingThePlayer() {
        let player = AVAudioPlayerNode()
        let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
        let queue = AudioPlaybackQueue(player: player, format: format)
        // 24kHz * 0.15s threshold = 3,600 frames; 1,000 bytes = 500 frames,
        // well under it — schedule() should never run.
        queue.enqueue(pcm16LE: Data(repeating: 0, count: 1_000))
    }
}
