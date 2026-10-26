import SwiftUI

/// Settings: the Gemini key, a way back to the walkthrough, and what the
/// app does with your data.
struct SettingsView: View {
    @State private var hasKey = Keychain.load(.geminiAPIKey)?.isEmpty == false
    @State private var showingKeySetup = false
    @State private var showingHelp = false

    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }

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

            Section("Help") {
                Button("How Shimbashi Works") { showingHelp = true }
                    .foregroundStyle(.primary)
            }

            Section {
                LabeledContent("Version", value: versionString)
            } header: {
                Text("About")
            } footer: {
                Text("Your voice and the text of your conversations are sent to Google's Gemini using your own API key — never to Shimbashi's developers. Your key is stored only in this phone's Keychain. Conversation history stays on this device. Tutor replies and translations are AI-generated and can contain mistakes.")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingKeySetup, onDismiss: {
            hasKey = Keychain.load(.geminiAPIKey)?.isEmpty == false
        }) {
            APIKeySetupView()
        }
        .sheet(isPresented: $showingHelp, onDismiss: {
            hasKey = Keychain.load(.geminiAPIKey)?.isEmpty == false
        }) {
            OnboardingView(onFinish: { showingHelp = false })
        }
    }
}

#Preview {
    NavigationStack { SettingsView() }
}
