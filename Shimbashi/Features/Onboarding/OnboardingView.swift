import SwiftUI

/// The first thing a new learner sees, and reachable again from Settings.
/// Explains the four things that aren't obvious from the home screen alone:
/// what the app is, that talking is tap-to-talk, that replies can be studied
/// phrase by phrase, and that it runs on the learner's own Gemini key.
struct OnboardingView: View {
    var onFinish: () -> Void

    @State private var page = 0
    @State private var showingKeySetup = false
    @State private var hasKey = Keychain.load(.geminiAPIKey)?.isEmpty == false

    private struct Page {
        let symbol: String
        let title: String
        let message: String
    }

    private let pages: [Page] = [
        Page(
            symbol: "bubble.left.and.bubble.right.fill",
            title: "Speak Japanese out loud",
            message: "Shimbashi is a live voice partner for practicing spoken Japanese. You talk, the tutor answers in Japanese, and the screen shows the Japanese, the romaji, and the English."
        ),
        Page(
            symbol: "mic.fill",
            title: "Tap, talk, tap",
            message: "Tap Start, say something in English or Japanese, then tap Stop. The tutor replies out loud. The first time, iOS asks for microphone access — Shimbashi only listens between Start and Stop."
        ),
        Page(
            symbol: "text.magnifyingglass",
            title: "Tap a reply to study it",
            message: "Tap any reply to break it into phrases, each with its romaji and meaning. Tap the speaker icon on a phrase to hear it again."
        ),
        Page(
            symbol: "key.fill",
            title: "Bring your own Gemini key",
            message: "Shimbashi uses Google's Gemini through your own free API key, so there's no account or subscription with us. Your key stays in this phone's Keychain, and your voice and text go only to Google."
        ),
    ]

    private var isLastPage: Bool { page == pages.count - 1 }

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                ForEach(Array(pages.enumerated()), id: \.offset) { index, item in
                    pageView(item)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            VStack(spacing: 12) {
                if isLastPage {
                    if !hasKey {
                        Button("Add API Key") { showingKeySetup = true }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                    }
                    if hasKey {
                        Button("Get Started", action: onFinish)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                    } else {
                        Button("I'll Do This Later", action: onFinish)
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                    }
                } else {
                    Button("Next") { withAnimation { page += 1 } }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    Button("Skip", action: onFinish)
                        .font(.footnote)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .sheet(isPresented: $showingKeySetup, onDismiss: {
            hasKey = Keychain.load(.geminiAPIKey)?.isEmpty == false
        }) {
            APIKeySetupView()
        }
    }

    private func pageView(_ item: Page) -> some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: item.symbol)
                .font(.system(size: 64))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(item.title)
                .font(.title.bold())
                .multilineTextAlignment(.center)
            Text(item.message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 32)
    }
}

#Preview {
    OnboardingView(onFinish: {})
}
