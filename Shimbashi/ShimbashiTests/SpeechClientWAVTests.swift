import Testing
import Foundation
@testable import Shimbashi

@Suite struct SpeechClientWAVTests {
    private func littleEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
        let bytes = data[data.startIndex + offset..<data.startIndex + offset + 4]
        return bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
    }

    private func littleEndianUInt16(_ data: Data, at offset: Int) -> UInt16 {
        let bytes = data[data.startIndex + offset..<data.startIndex + offset + 2]
        return bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }
    }

    private func ascii(_ data: Data, _ range: Range<Int>) -> String {
        String(decoding: data[data.startIndex + range.lowerBound..<data.startIndex + range.upperBound], as: UTF8.self)
    }

    @Test func headerLayoutForMonoPCM() {
        let pcm = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06])
        let wav = SpeechClient.wavData(fromPCM16: pcm, sampleRate: 24_000, channels: 1)

        #expect(ascii(wav, 0..<4) == "RIFF")
        #expect(littleEndianUInt32(wav, at: 4) == 36 + UInt32(pcm.count))
        #expect(ascii(wav, 8..<12) == "WAVE")
        #expect(ascii(wav, 12..<16) == "fmt ")
        #expect(littleEndianUInt32(wav, at: 16) == 16)
        #expect(littleEndianUInt16(wav, at: 20) == 1) // PCM format tag
        #expect(littleEndianUInt16(wav, at: 22) == 1) // channels
        #expect(littleEndianUInt32(wav, at: 24) == 24_000) // sample rate
        #expect(littleEndianUInt32(wav, at: 28) == 24_000 * 1 * 2) // byte rate
        #expect(littleEndianUInt16(wav, at: 32) == 1 * 2) // block align
        #expect(littleEndianUInt16(wav, at: 34) == 16) // bits per sample
        #expect(ascii(wav, 36..<40) == "data")
        #expect(littleEndianUInt32(wav, at: 40) == UInt32(pcm.count))
        #expect(wav.count == 44 + pcm.count)
        #expect(wav.suffix(pcm.count) == pcm)
    }

    @Test func headerLayoutForStereoDifferentSampleRate() {
        let pcm = Data(repeating: 0xAB, count: 400)
        let wav = SpeechClient.wavData(fromPCM16: pcm, sampleRate: 16_000, channels: 2)

        #expect(littleEndianUInt16(wav, at: 22) == 2)
        #expect(littleEndianUInt32(wav, at: 24) == 16_000)
        #expect(littleEndianUInt32(wav, at: 28) == 16_000 * 2 * 2)
        #expect(littleEndianUInt16(wav, at: 32) == 2 * 2)
        #expect(littleEndianUInt32(wav, at: 40) == UInt32(pcm.count))
        #expect(wav.count == 44 + pcm.count)
    }

    @Test func emptyPCMStillProducesValidHeader() {
        let wav = SpeechClient.wavData(fromPCM16: Data(), sampleRate: 24_000, channels: 1)
        #expect(wav.count == 44)
        #expect(littleEndianUInt32(wav, at: 40) == 0)
        #expect(littleEndianUInt32(wav, at: 4) == 36)
    }
}
