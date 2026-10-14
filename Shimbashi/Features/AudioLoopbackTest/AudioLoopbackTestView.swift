import SwiftUI
import VoiceCore


@MainActor
@Observable
final class AudioLoopbackTestController {
    private let engine = VoiceIOEngine()
    // Gemini's real audio always arrives at 24kHz, so upsample the mic's
    // 16kHz capture to the same rate here — the loopback test exercises the
    // exact same `enqueuePlayback` path (24kHz in, resampled to hardware
    // rate internally) that the real conversation pipeline uses. A single
    // persistent instance, not one per chunk — resampling is stateful.
    private let resampler = PCMStreamResampler(sourceRate: 16_000, targetRate: 24_000)
    private var pumpTask: Task<Void, Never>?

    var isRunning = false
    var inputLevel: Float = 0
    var errorMessage: String?

    func start() async {
        errorMessage = nil
        do {
            let stream = try await engine.start()
            isRunning = true
            pumpTask = Task { @MainActor in
                for await chunk in stream {
                    self.inputLevel = chunk.rms
                    if let resampled = self.resampler?.resample(chunk.pcm16LE) {
                        self.engine.enqueuePlayback(resampled)
                    }
                }
            }
        } catch {
            errorMessage = "\(error)"
        }
    }

    func stop() {
        pumpTask?.cancel()
        pumpTask = nil
        engine.endPlaybackTurn()
        engine.stop()
        isRunning = false
        inputLevel = 0
    }
}

/// Talk into the mic, hear yourself back at the correct pitch and speed.
/// Exercises the capture path (48kHz→16kHz) and the playback path (→24kHz)
/// independently of any network code — see Phase 2 of the build plan.
struct AudioLoopbackTestView: View {
    @State private var controller = AudioLoopbackTestController()

    var body: some View {
        VStack(spacing: 24) {
            Text("Talk — you should hear yourself back at the right pitch and speed.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            // Reading `inputLevel` here would re-evaluate this whole body ~10x/sec
            // while talking — including the Button below — which can drop a tap
            // gesture if it lands mid-rebuild. Pushed into its own subview so only
            // that subview re-renders on each level update.
            LevelMeterRow(controller: controller)

            Button(controller.isRunning ? "Stop" : "Start") {
                if controller.isRunning {
                    controller.stop()
                } else {
                    Task { await controller.start() }
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(controller.isRunning ? .red : .accentColor)

            if let error = controller.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }
        }
        .padding()
        .navigationTitle("Loopback Test")
        .onDisappear { controller.stop() }
    }
}

/// Isolates the ~10Hz `inputLevel` read so it invalidates only this subview,
/// not the whole `AudioLoopbackTestView` body (and the Button in it).
private struct LevelMeterRow: View {
    let controller: AudioLoopbackTestController

    var body: some View {
        LevelMeter(level: controller.inputLevel)
            .frame(height: 12)
            .padding(.horizontal, 40)
    }
}

private struct LevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                RoundedRectangle(cornerRadius: 6)
                    .fill(.tint)
                    .frame(width: geo.size.width * CGFloat(level))
                    .animation(.linear(duration: 0.05), value: level)
            }
        }
    }
}

#Preview {
    NavigationStack { AudioLoopbackTestView() }
}
