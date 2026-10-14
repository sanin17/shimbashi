import Testing
import Foundation
@testable import VoiceCore

@Suite struct PCMStreamResamplerTests {
    private func toneData(sampleCount: Int) -> Data {
        var data = Data()
        for i in 0..<sampleCount {
            let sample = Int16(sin(Double(i) * 0.1) * 10_000)
            var little = sample.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        return data
    }

    @Test func initSucceedsForRealisticRates() {
        #expect(PCMStreamResampler(sourceRate: 24_000, targetRate: 44_100) != nil)
        #expect(PCMStreamResampler(sourceRate: 16_000, targetRate: 16_000) != nil)
    }

    @Test func resampleProducesRoughlyExpectedFrameCount() throws {
        let resampler = try #require(PCMStreamResampler(sourceRate: 24_000, targetRate: 48_000))
        let input = toneData(sampleCount: 480)
        let output = try #require(resampler.resample(input))
        let outputFrames = output.count / MemoryLayout<Int16>.size
        // Upsampling 2x — allow slack for resampler group delay/edge effects.
        #expect(outputFrames > 800 && outputFrames < 1_100)
    }

    @Test func resampleOfEmptyDataReturnsNil() {
        let resampler = PCMStreamResampler(sourceRate: 24_000, targetRate: 16_000)
        #expect(resampler?.resample(Data()) == nil)
    }

    @Test func resetDoesNotCrashAndAllowsContinuedUse() throws {
        let resampler = try #require(PCMStreamResampler(sourceRate: 24_000, targetRate: 16_000))
        _ = resampler.resample(toneData(sampleCount: 240))
        resampler.reset()
        let output = resampler.resample(toneData(sampleCount: 240))
        #expect(output != nil)
    }

    @Test func sameRateStillProducesOutput() throws {
        let resampler = try #require(PCMStreamResampler(sourceRate: 16_000, targetRate: 16_000))
        let input = toneData(sampleCount: 320)
        let output = try #require(resampler.resample(input))
        #expect(!output.isEmpty)
    }
}
