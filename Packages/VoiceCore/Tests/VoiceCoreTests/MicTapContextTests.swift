import Testing
import AVFAudio
@testable import VoiceCore

@Suite struct MicTapContextTests {
    /// Same format for hardware and target — makes the converter a 1:1
    /// pass-through (ratio 1.0), so byte counts are exact and predictable
    /// rather than subject to resampling interpolation.
    private func makeContext(continuation: AsyncStream<AudioChunk>.Continuation) -> MicTapContext {
        let format = PCMFormats.captureTarget
        return MicTapContext(hardwareFormat: format, targetFormat: format, continuation: continuation)!
    }

    private func makeBuffer(sampleCount: Int) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: PCMFormats.captureTarget, frameCapacity: AVAudioFrameCount(sampleCount))!
        buffer.frameLength = AVAudioFrameCount(sampleCount)
        if let channel = buffer.int16ChannelData {
            for i in 0..<sampleCount { channel[0][i] = Int16(i % 1_000) }
        }
        return buffer
    }

    @Test func ingestEmitsExactlyOneChunkAtByteBoundary() async {
        let (stream, continuation) = AsyncStream<AudioChunk>.makeStream()
        let context = makeContext(continuation: continuation)
        // 1,600 Int16 samples * 2 bytes = 3,200 bytes = exactly bytesPerChunk.
        context.ingest(makeBuffer(sampleCount: 1_600), at: AVAudioTime(hostTime: 0))
        continuation.finish()

        var chunks: [AudioChunk] = []
        for await chunk in stream { chunks.append(chunk) }
        #expect(chunks.count == 1)
        #expect(chunks[0].pcm16LE.count == 3_200)
    }

    @Test func ingestDoesNotEmitBeforeByteBoundaryIsReached() async {
        let (stream, continuation) = AsyncStream<AudioChunk>.makeStream()
        let context = makeContext(continuation: continuation)
        // 800 samples = 1,600 bytes — half a chunk, should emit nothing yet.
        context.ingest(makeBuffer(sampleCount: 800), at: AVAudioTime(hostTime: 0))
        continuation.finish()

        var chunks: [AudioChunk] = []
        for await chunk in stream { chunks.append(chunk) }
        #expect(chunks.isEmpty)
    }

    @Test func ingestAccumulatesAcrossMultipleCallsBeforeEmitting() async {
        let (stream, continuation) = AsyncStream<AudioChunk>.makeStream()
        let context = makeContext(continuation: continuation)
        context.ingest(makeBuffer(sampleCount: 800), at: AVAudioTime(hostTime: 0)) // 1,600 bytes
        context.ingest(makeBuffer(sampleCount: 800), at: AVAudioTime(hostTime: 1)) // +1,600 = 3,200
        continuation.finish()

        var chunks: [AudioChunk] = []
        for await chunk in stream { chunks.append(chunk) }
        #expect(chunks.count == 1)
    }

    @Test func mutedDropsYieldsButStillConsumesAccumulatedBytes() async {
        let (stream, continuation) = AsyncStream<AudioChunk>.makeStream()
        let context = makeContext(continuation: continuation)

        context.setMuted(true)
        // A full chunk's worth while muted — should be silently dropped,
        // not left to blend into (or double up with) the next chunk.
        context.ingest(makeBuffer(sampleCount: 1_600), at: AVAudioTime(hostTime: 0))
        context.setMuted(false)
        context.ingest(makeBuffer(sampleCount: 1_600), at: AVAudioTime(hostTime: 1))
        continuation.finish()

        var chunks: [AudioChunk] = []
        for await chunk in stream { chunks.append(chunk) }
        // If the muted bytes hadn't been drained from `pending`, this would
        // report 2 chunks (both boundary crossings landing after mute was
        // lifted) instead of 1.
        #expect(chunks.count == 1)
    }

    @Test func rmsIsPopulatedOnEmittedChunks() async {
        let (stream, continuation) = AsyncStream<AudioChunk>.makeStream()
        let context = makeContext(continuation: continuation)
        context.ingest(makeBuffer(sampleCount: 1_600), at: AVAudioTime(hostTime: 0))
        continuation.finish()

        var chunks: [AudioChunk] = []
        for await chunk in stream { chunks.append(chunk) }
        #expect(chunks.first?.rms ?? 0 > 0)
    }
}
