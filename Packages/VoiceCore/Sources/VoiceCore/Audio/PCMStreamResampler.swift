import AVFAudio

/// Resamples a continuous stream of little-endian 16-bit mono PCM chunks from
/// one sample rate to another, reusing a single `AVAudioConverter` across
/// calls. Sample-rate conversion is stateful — the converter maintains an
/// interpolation filter across calls — so constructing a fresh converter per
/// chunk (as a naive one-shot helper would) resets that filter at every chunk
/// boundary and produces audible clicks/glitches at each boundary. This is
/// what actually causes "choppy" playback, not a genuine speed/pitch bug.
public final class PCMStreamResampler {
    private let converter: AVAudioConverter
    private let sourceFormat: AVAudioFormat
    private let targetFormat: AVAudioFormat

    public init?(sourceRate: Double, targetRate: Double) {
        guard let sourceFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: sourceRate, channels: 1, interleaved: true
              ),
              let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: targetRate, channels: 1, interleaved: true
              ),
              let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else { return nil }
        self.sourceFormat = sourceFormat
        self.targetFormat = targetFormat
        self.converter = converter
    }

    /// Resets the converter's internal filter state. Call at a genuine
    /// discontinuity in the stream — a new turn, a barge-in flush — so state
    /// from unrelated audio doesn't bleed into what comes next.
    public func reset() {
        converter.reset()
    }

    public func resample(_ pcm16LE: Data) -> Data? {
        let sampleCount = pcm16LE.count / MemoryLayout<Int16>.size
        guard sampleCount > 0,
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(sampleCount)),
              let source = inputBuffer.int16ChannelData?[0] else { return nil }
        inputBuffer.frameLength = AVAudioFrameCount(sampleCount)

        var samples = [Int16](repeating: 0, count: sampleCount)
        samples.withUnsafeMutableBytes { raw in
            _ = pcm16LE.copyBytes(to: raw)
        }
        samples.withUnsafeBufferPointer { buffer in
            source.update(from: buffer.baseAddress!, count: sampleCount)
        }

        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(sampleCount) * ratio) + 1_024
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }

        // `convert(to:error:withInputFrom:)` calls this block synchronously,
        // only within this call — never concurrently — despite the compiler
        // treating it as a @Sendable closure under this toolchain's default
        // actor isolation.
        nonisolated(unsafe) var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return inputBuffer
        }
        guard status == .haveData || status == .inputRanDry,
              outputBuffer.frameLength > 0,
              let channel = outputBuffer.int16ChannelData else { return nil }
        return Data(bytes: channel[0], count: Int(outputBuffer.frameLength) * MemoryLayout<Int16>.size)
    }
}
