import AVFAudio
import Synchronization


/// ~100ms of captured audio, ready to send to Gemini as one `realtimeInput` frame.
public struct AudioChunk: Sendable {
    public let pcm16LE: Data
    public let rms: Float
    public let hostTime: UInt64
}

/// Owns all per-tap conversion state: the `AVAudioConverter`, the sub-chunk
/// accumulator, and the mute flag.
///
/// Every method except `setMuted` is called only from the `AVAudioEngine` tap
/// thread, which is serial for a given tap — `installTap`/`removeTap` only
/// happen with the engine stopped, so there is no concurrent access window on
/// that state despite the `@unchecked Sendable` conformance. `setMuted` is the
/// one property genuinely written from the main actor and read from the tap
/// thread, so it alone goes through `Atomic` rather than being trusted to the
/// "provably serial" argument.
final class MicTapContext: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let targetFormat: AVAudioFormat
    private let continuation: AsyncStream<AudioChunk>.Continuation
    private var pending = Data()
    private let muted = Atomic<Bool>(false)

    /// 16kHz * 0.1s * 2 bytes/sample (Int16).
    private static let bytesPerChunk = 3_200

    init?(
        hardwareFormat: AVAudioFormat,
        targetFormat: AVAudioFormat,
        continuation: AsyncStream<AudioChunk>.Continuation
    ) {
        guard let converter = AVAudioConverter(from: hardwareFormat, to: targetFormat) else { return nil }
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Normal
        self.converter = converter
        self.targetFormat = targetFormat
        self.continuation = continuation
    }

    func setMuted(_ value: Bool) {
        muted.store(value, ordering: .relaxed)
    }

    /// Converts one tap callback's buffer and yields any complete ~100ms chunks.
    /// Must not let `inputBuffer` escape this call — the engine reuses its backing
    /// memory once this function returns.
    func ingest(_ inputBuffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        let ratio = targetFormat.sampleRate / inputBuffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio) + 1_024
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return
        }

        // `convert(to:error:withInputFrom:)` calls this block synchronously,
        // only within this call — never concurrently — despite the compiler
        // treating it as a @Sendable closure under this toolchain's default
        // actor isolation.
        nonisolated(unsafe) var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if supplied {
                // .noDataNow, not .endOfStream — the latter flushes the resampler's
                // internal state and produces an audible click on the next callback.
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        // .inputRanDry is the normal steady-state result here, not an error.
        guard status == .haveData || status == .inputRanDry,
              outputBuffer.frameLength > 0,
              let channel = outputBuffer.int16ChannelData else {
            return
        }

        let byteCount = Int(outputBuffer.frameLength) * MemoryLayout<Int16>.size
        pending.append(Data(bytes: channel[0], count: byteCount))

        let isMuted = muted.load(ordering: .relaxed)
        while pending.count >= Self.bytesPerChunk {
            let frame = Data(pending.prefix(Self.bytesPerChunk))
            pending.removeFirst(Self.bytesPerChunk)
            guard !isMuted else { continue }
            continuation.yield(AudioChunk(pcm16LE: frame, rms: PCMFormats.rms(of: frame), hostTime: time.hostTime))
        }
    }
}
