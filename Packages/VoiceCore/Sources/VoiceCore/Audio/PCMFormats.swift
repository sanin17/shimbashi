import AVFAudio
import Accelerate

/// The two fixed PCM formats the Gemini Live wire protocol uses, plus the
/// conversions between them and the buffer types AVFoundation expects.
public enum PCMFormats {
    /// What we send to Gemini: 16-bit little-endian mono PCM at 16kHz.
    public static let captureTarget: AVAudioFormat = {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ) else { fatalError("Failed to construct 16kHz Int16 capture format") }
        return format
    }()

    /// What Gemini sends back: 16-bit little-endian mono PCM at 24kHz.
    /// `AVAudioPlayerNode` wants Float32, so this is the format we schedule
    /// buffers in after converting with `floatBuffer(from:format:)`.
    public static let playback: AVAudioFormat = {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1) else {
            fatalError("Failed to construct 24kHz playback format")
        }
        return format
    }()

    /// Converts little-endian 16-bit mono PCM `Data` into a Float32 buffer in
    /// `format`, duplicated across every channel `format` has. The source
    /// audio is always mono (captured or model-generated speech); `format`'s
    /// channel count is dictated by whatever the hardware/mixer actually
    /// negotiated, which need not be mono, so every channel needs real data —
    /// writing only channel 0 would leave the rest silent.
    /// `data` need not be 2-byte aligned — base64-decoded `Data` isn't guaranteed to be.
    public static func floatBuffer(from data: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let sampleCount = data.count / MemoryLayout<Int16>.size
        guard sampleCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleCount)),
              let channelData = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(sampleCount)

        var samples = [Int16](repeating: 0, count: sampleCount)
        samples.withUnsafeMutableBytes { raw in
            _ = data.copyBytes(to: raw)
        }
        var floats = [Float](repeating: 0, count: sampleCount)
        vDSP_vflt16(samples, 1, &floats, 1, vDSP_Length(sampleCount))
        var scale = Float(1.0 / 32_768.0)
        vDSP_vsmul(floats, 1, &scale, &floats, 1, vDSP_Length(sampleCount))

        floats.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            for channel in 0..<Int(format.channelCount) {
                channelData[channel].update(from: base, count: sampleCount)
            }
        }
        return buffer
    }

    /// Root-mean-square level of a little-endian 16-bit PCM chunk, normalized to roughly 0...1
    /// with headroom scaling suitable for driving a UI level meter.
    public static func rms(of pcm16LE: Data) -> Float {
        let sampleCount = pcm16LE.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return 0 }
        var samples = [Int16](repeating: 0, count: sampleCount)
        samples.withUnsafeMutableBytes { raw in
            _ = pcm16LE.copyBytes(to: raw)
        }
        var floats = [Float](repeating: 0, count: sampleCount)
        vDSP_vflt16(samples, 1, &floats, 1, vDSP_Length(sampleCount))
        var meanSquare: Float = 0
        vDSP_measqv(floats, 1, &meanSquare, vDSP_Length(sampleCount))
        return min(1, sqrt(meanSquare) / 32_768.0 * 4)
    }
}
