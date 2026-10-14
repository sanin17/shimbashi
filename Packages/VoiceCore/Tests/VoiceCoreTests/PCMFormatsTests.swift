import Testing
import AVFAudio
@testable import VoiceCore

@Suite struct PCMFormatsTests {
    private func pcm16LEData(_ samples: [Int16]) -> Data {
        var data = Data()
        for sample in samples {
            var little = sample.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        return data
    }

    // MARK: - floatBuffer

    @Test func floatBufferConvertsKnownAmplitudes() throws {
        let data = pcm16LEData([0, Int16.max, Int16.min])
        let buffer = try #require(PCMFormats.floatBuffer(from: data, format: PCMFormats.playback))
        let channel = try #require(buffer.floatChannelData)
        #expect(buffer.frameLength == 3)
        #expect(channel[0][0] == 0)
        #expect(abs(channel[0][1] - 1.0) < 0.001)
        #expect(abs(channel[0][2] - (-1.0)) < 0.001)
    }

    @Test func floatBufferDuplicatesAcrossAllChannels() throws {
        let stereoFormat = try #require(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 2))
        let data = pcm16LEData([16_384])
        let buffer = try #require(PCMFormats.floatBuffer(from: data, format: stereoFormat))
        let channel = try #require(buffer.floatChannelData)
        #expect(channel[0][0] == channel[1][0])
    }

    @Test func floatBufferReturnsNilForEmptyData() {
        #expect(PCMFormats.floatBuffer(from: Data(), format: PCMFormats.playback) == nil)
    }

    @Test func floatBufferTruncatesOddByteCountCleanly() throws {
        // 5 bytes = 2 whole Int16 samples plus a dangling byte the function
        // should just ignore (floor division), not crash on.
        var data = pcm16LEData([1, 2])
        data.append(0xFF)
        let buffer = try #require(PCMFormats.floatBuffer(from: data, format: PCMFormats.playback))
        #expect(buffer.frameLength == 2)
    }

    // MARK: - rms

    @Test func rmsOfSilenceIsZero() {
        let data = pcm16LEData([0, 0, 0, 0])
        #expect(PCMFormats.rms(of: data) == 0)
    }

    @Test func rmsOfKnownAmplitudeMatchesExpectedValue() {
        let data = pcm16LEData([Int16](repeating: 4_096, count: 8))
        let rms = PCMFormats.rms(of: data)
        #expect(abs(rms - 0.5) < 0.01)
    }

    @Test func rmsOfFullScaleAmplitudeClampsToOne() {
        let data = pcm16LEData([Int16](repeating: Int16.max, count: 8))
        #expect(PCMFormats.rms(of: data) == 1)
    }

    @Test func rmsOfEmptyDataIsZero() {
        #expect(PCMFormats.rms(of: Data()) == 0)
    }
}
