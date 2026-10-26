import SwiftUI

struct RootView: View {
    @State private var hasKey = Keychain.load(.geminiAPIKey)?.isEmpty == false
    @State private var showingKeySetup = false
    /// Shown once, on first launch; reachable again from Settings.
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.tint)
                Text("Shimbashi")
                    .font(.title2.bold())
                Text("Practice spoken Japanese with a live voice partner.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                if !hasKey {
                    VStack(spacing: 8) {
                        Text("First, add a free Gemini API key. It stays on this device and is sent only to Google.")
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                        Button("Add API Key") { showingKeySetup = true }
                            .buttonStyle(.bordered)
                    }
                    .padding()
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 24)
                }

                NavigationLink("Conversations") {
                    ConversationListView()
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)

                NavigationLink("Settings") {
                    SettingsView()
                }
                .font(.footnote)
            }
            .navigationTitle("Shimbashi")
            // The key can change from Settings or a conversation's failure
            // screen, so re-read it whenever this screen comes back.
            .onAppear { hasKey = Keychain.load(.geminiAPIKey)?.isEmpty == false }
            .onChange(of: hasSeenOnboarding) { _, _ in
                // The walkthrough can end with a key saved.
                hasKey = Keychain.load(.geminiAPIKey)?.isEmpty == false
            }
            .fullScreenCover(isPresented: Binding(
                get: { !hasSeenOnboarding },
                set: { if !$0 { hasSeenOnboarding = true } }
            )) {
                OnboardingView(onFinish: { hasSeenOnboarding = true })
            }
            .sheet(isPresented: $showingKeySetup, onDismiss: {
                hasKey = Keychain.load(.geminiAPIKey)?.isEmpty == false
            }) {
                APIKeySetupView()
            }
        }
    }
}

#Preview {
    RootView()
}
