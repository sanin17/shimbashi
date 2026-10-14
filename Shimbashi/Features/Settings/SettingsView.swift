import SwiftUI

/// Persisted, adjustable session settings — currently just background-noise
/// resistance, but the natural home for anything else configurable that
/// applies to every conversation rather than a single one.
struct SettingsView: View {
    @AppStorage("noiseResistance") private var noiseResistance: Double = 0.4
    @State private var hasKey = Keychain.load(.geminiAPIKey)?.isEmpty == false
    @State private var showingKeySetup = false

    var body: some View {
        Form {
            Section {
                Button {
                    showingKeySetup = true
                } label: {
                    LabeledContent("Gemini API Key", value: hasKey ? "Saved" : "Not set")
                }
                .foregroundStyle(.primary)
            } header: {
                Text("Account")
            } footer: {
                Text("Add, replace, or remove your key, and see how to get one from Google.")
            }

            Section {
                Slider(value: $noiseResistance, in: 0...1, step: 0.05)
                HStack {
                    Text("Sensitive")
                    Spacer()
                    Text("Noise-resistant")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } header: {
                Text("Background Noise")
            } footer: {
                Text("Higher requires clearer, more sustained speech before the tutor starts listening — helps in noisy environments, but may miss quiet or hesitant speech. Takes effect the next time you open the Conversation screen.")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingKeySetup, onDismiss: {
            hasKey = Keychain.load(.geminiAPIKey)?.isEmpty == false
        }) {
            APIKeySetupView()
        }
    }
}

#Preview {
    NavigationStack { SettingsView() }
}
