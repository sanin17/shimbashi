import SwiftUI

/// Colors lifted from the app icon, so the home screen reads as the same
/// brand: a night-indigo sky, a warm sunrise glow, and the torii's orange.
private enum Brand {
    static let night = Color(red: 0.07, green: 0.08, blue: 0.22)
    static let indigo = Color(red: 0.17, green: 0.18, blue: 0.43)
    static let dusk = Color(red: 0.30, green: 0.22, blue: 0.50)
    static let sun = Color(red: 1.00, green: 0.72, blue: 0.45)
    static let toriiLight = Color(red: 0.96, green: 0.38, blue: 0.20)
    static let toriiDeep = Color(red: 0.84, green: 0.23, blue: 0.17)
}

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
        ZStack {
            LinearGradient(
                colors: [Brand.night, Brand.indigo, Brand.dusk],
                startPoint: .top,
                endPoint: .bottom
            )
            // The sunrise from the icon, glowing behind the logo.
            RadialGradient(
                colors: [Brand.sun.opacity(0.42), Brand.sun.opacity(0.10), .clear],
                center: UnitPoint(x: 0.5, y: 0.30),
                startRadius: 10,
                endRadius: 340
            )
        }
        .ignoresSafeArea()
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
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Brand.night)
                .padding(.horizontal, 22)
                .padding(.vertical, 9)
                .background(.white, in: Capsule())
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 1)
        )
    }
}

// MARK: - Button styles

private struct PrimaryActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.title3.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 17)
            .background(
                LinearGradient(
                    colors: [Brand.toriiLight, Brand.toriiDeep],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .shadow(color: Brand.toriiDeep.opacity(0.45), radius: 14, y: 6)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

private struct SecondaryActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(.white.opacity(0.92))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(.white.opacity(configuration.isPressed ? 0.18 : 0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.white.opacity(0.14), lineWidth: 1)
            )
    }
}

#Preview {
    RootView()
}
