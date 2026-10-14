import AVFAudio

/// Schedules streamed 24kHz model audio onto an `AVAudioPlayerNode`, holding a
/// short jitter buffer per turn so small/irregular network chunks don't produce
/// audible micro-dropouts.
@MainActor
final class AudioPlaybackQueue {
    private let player: AVAudioPlayerNode
    private let format: AVAudioFormat
    private let resampler: PCMStreamResampler?
    private var pending: [AVAudioPCMBuffer] = []
    private var isPrimed = false

    /// ~150ms, held before the first buffer of a turn is scheduled.
    private let primeThresholdFrames: Double

    /// `format` must match the format `player` was connected with — buffers
    /// built in any other format silently fail to schedule.
    init(player: AVAudioPlayerNode, format: AVAudioFormat) {
        self.player = player
        self.format = format
        self.primeThresholdFrames = format.sampleRate * 0.15
        self.resampler = PCMStreamResampler(sourceRate: 24_000, targetRate: format.sampleRate)
    }

    /// Feed one chunk of model audio — always 16-bit mono PCM at Gemini's
    /// fixed 24kHz output rate, resampled here to whatever the hardware
    /// actually negotiated. Buffers until the jitter-buffer threshold is
    /// met, then schedules directly for the rest of the turn.
    func enqueue(pcm16LE: Data) {
        guard let resampled = resampler?.resample(pcm16LE),
              let buffer = PCMFormats.floatBuffer(from: resampled, format: format) else {
            return
        }

        if isPrimed {
            schedule(buffer)
            return
        }

        pending.append(buffer)
        let bufferedFrames = pending.reduce(0) { $0 + Int($1.frameLength) }
        if Double(bufferedFrames) >= primeThresholdFrames {
            isPrimed = true
            pending.forEach(schedule)
            pending.removeAll()
        }
    }

    /// Call when the model's turn completes: flush whatever didn't reach the
    /// priming threshold rather than holding it forever, and reset priming
    /// for the next turn.
    func endTurn() {
        pending.forEach(schedule)
        pending.removeAll()
        isPrimed = false
        resampler?.reset()
    }

    /// Barge-in: drop everything not yet at the speaker and re-arm immediately.
    /// Deliberately does not touch the engine — that would tear down AEC.
    func flushForBargeIn() {
        pending.removeAll()
        isPrimed = false
        player.stop()
        player.play()
        resampler?.reset()
    }

    private func schedule(_ buffer: AVAudioPCMBuffer) {
        player.scheduleBuffer(buffer, at: nil)
    }
}
