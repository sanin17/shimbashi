import SwiftUI

struct RootView: View {
    @State private var hasKey = Keychain.load(.geminiAPIKey)?.isEmpty == false
    @State private var showingKeySetup = false
    /// Shown once, on first launch; reachable again from Settings.
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false

    var body: some View {
        NavigationStack {
            ZStack {
                background

                // Fills the screen on any normal iPhone; on a small one (or
                // with large text) the content scrolls instead of clipping.
                GeometryReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            Spacer(minLength: 16)
                            hero(compact: proxy.size.height < 700)
                            Spacer(minLength: 16)
                            actions
                        }
                        .padding(.horizontal, 24)
                        .padding(.bottom, 20)
                        .frame(minHeight: proxy.size.height)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }
            }
            // The bar stays (it carries the back button on pushed screens)
            // but is transparent here, with light status-bar text over the
            // dark gradient.
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
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

    // MARK: - Pieces

    private var background: some View {
        // The sunrise from the icon, glowing behind the logo.
        BrandBackground(glowCenter: UnitPoint(x: 0.5, y: 0.30), glowStrength: 0.42)
    }

    /// `compact` is for short screens (iPhone SE): a smaller logo and tighter
    /// spacing so the buttons still have room.
    private func hero(compact: Bool) -> some View {
        let logoSize: CGFloat = compact ? 96 : 136
        return VStack(spacing: compact ? 8 : 14) {
            Image("Logo")
                .resizable()
                .scaledToFit()
                .frame(width: logoSize, height: logoSize)
                .clipShape(RoundedRectangle(cornerRadius: logoSize * 0.2237, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: logoSize * 0.2237, style: .continuous)
                        .strokeBorder(.white.opacity(0.18), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.45), radius: 24, y: 12)
                .accessibilityHidden(true)
                .padding(.bottom, compact ? 2 : 8)

            Text("Shimbashi")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .foregroundStyle(.white)

            // The name in Japanese: 新橋 ("new bridge").
            Text("新橋")
                .font(.title3)
                .tracking(6)
                .foregroundStyle(Brand.sun.opacity(0.9))
                .accessibilityHidden(true)

            Text("Practice spoken Japanese with a live voice partner.")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.78))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
                .padding(.top, 2)
        }
    }

    private var actions: some View {
        VStack(spacing: 14) {
            if !hasKey {
                keyCallout
            }

            NavigationLink {
                ConversationListView()
            } label: {
                Label("Conversations", systemImage: "bubble.left.and.bubble.right.fill")
            }
            .buttonStyle(PrimaryActionStyle())

            NavigationLink {
                SettingsView()
            } label: {
                Label("Settings", systemImage: "gearshape.fill")
            }
            .buttonStyle(SecondaryActionStyle())
        }
    }

    private var keyCallout: some View {
        VStack(spacing: 10) {
            Label("One quick step", systemImage: "key.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Brand.sun)
            Text("Add a free Gemini API key to start. It stays on this device and is sent only to Google.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
            Button("Add API Key") { showingKeySetup = true }
                .buttonStyle(PillButtonStyle())
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .brandCard()
    }
}

#Preview {
    RootView()
}
