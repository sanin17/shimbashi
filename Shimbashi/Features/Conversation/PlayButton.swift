import SwiftUI

/// Tap to hear a piece of Japanese text spoken aloud via `SpeechPlaybackController`
/// — used both inline on a turn's main sentence and, at a larger size, on
/// each phrase in `PhraseBreakdownView`. Only one clip plays at a time
/// across the whole app, so this reflects whether *this* button's text is
/// the one currently loading/playing, not just whether something is.
struct PlayButton: View {
    let text: String
    let controller: SpeechPlaybackController
    var iconFont: Font = .caption
    /// The model's own already-streamed reply audio, if this button is for a
    /// turn's main sentence (not an individual breakdown phrase) — see
    /// `SpeechPlaybackController.play(_:cachedPCM16:)`.
    var cachedPCM16: Data? = nil

    private var isActive: Bool { controller.activeText == text }
    private var isPlaying: Bool { isActive && controller.state == .playing }
    private var isLoading: Bool { isActive && controller.state == .loading }
    private var isRateLimited: Bool { isActive && controller.state == .rateLimited }
    /// Shown as a small badge while this button is the active one and its
    /// audio is coming from a live Gemini TTS call — absent when playing
    /// already-on-device audio (cached reply audio, or once loading/playing
    /// has finished), so a glance at the button says whether a tap is
    /// costing an API call or is free/instant.
    private var isCallingProvider: Bool { isActive && controller.activeSource == .network }

    var body: some View {
        Button {
            if isPlaying {
                controller.stop()
            } else if !isRateLimited {
                controller.play(text, cachedPCM16: cachedPCM16)
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                if isLoading {
                    ProgressView().controlSize(.mini)
                } else if isRateLimited {
                    Image(systemName: "clock.badge.exclamationmark")
                        .font(iconFont)
                        .foregroundStyle(.orange)
                } else {
                    Image(systemName: isPlaying ? "speaker.wave.2.fill" : "speaker.wave.2")
                        .font(iconFont)
                        .foregroundStyle(isPlaying ? Brand.sun : Brand.textSecondary)
                }
                if isCallingProvider {
                    Image(systemName: "icloud.and.arrow.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Brand.sun)
                        .offset(x: 8, y: -6)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(isLoading || isRateLimited)
    }
}
