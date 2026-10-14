import SwiftUI

/// Entry point for managing the Gemini API key — powers both the live voice
/// conversation and, with a separate plain text call, the on-screen
/// romaji/English translation. Stored in the Keychain, never sent anywhere
/// but straight to Google. Shown on first run and from Settings, where the
/// key can be removed or replaced.
struct APIKeySetupView: View {
    private static let aiStudioURL = URL(string: "https://aistudio.google.com/apikey")!

    @State private var savedKey: String? = Keychain.load(.geminiAPIKey)
    @State private var newKey: String = ""
    @State private var confirmingRemoval = false
    @Environment(\.dismiss) private var dismiss
    var onSave: (() -> Void)?

    private var trimmedNewKey: String {
        newKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let savedKey, !savedKey.isEmpty {
                    Section("Saved Key") {
                        LabeledContent("Current key", value: Self.masked(savedKey))
                        Button("Remove Key", role: .destructive) {
                            confirmingRemoval = true
                        }
                    }
                }

                Section {
                    SecureField("Paste Gemini API key", text: $newKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text(savedKey == nil ? "Add a Key" : "Replace Key")
                } footer: {
                    Text("Stored in the iOS Keychain on this device only. It's sent only to Google, never to anyone else.")
                }

                Section {
                    step(1, "Open Google AI Studio and sign in with a Google account.")
                    step(2, "Tap “Create API key” and pick a project (or create a new one).")
                    step(3, "Copy the key, come back here, and paste it above.")
                    Link(destination: Self.aiStudioURL) {
                        Label("Open Google AI Studio", systemImage: "arrow.up.right.square")
                    }
                } header: {
                    Text("How to Get a Key")
                } footer: {
                    Text("A free key is enough to get started. The free tier has usage limits, and Google's free-tier data terms apply.")
                }
            }
            .navigationTitle("Gemini API Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard !trimmedNewKey.isEmpty else { return }
                        Keychain.save(trimmedNewKey, for: .geminiAPIKey)
                        onSave?()
                        dismiss()
                    }
                    .disabled(trimmedNewKey.isEmpty)
                }
            }
            .confirmationDialog(
                "Remove the saved API key?",
                isPresented: $confirmingRemoval,
                titleVisibility: .visible
            ) {
                Button("Remove Key", role: .destructive) {
                    Keychain.delete(.geminiAPIKey)
                    savedKey = nil
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Conversations won't work until you add a key again.")
            }
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.footnote.bold())
                .foregroundStyle(.tint)
                .frame(width: 20)
            Text(text)
        }
    }

    private static func masked(_ key: String) -> String {
        "••••" + key.suffix(4)
    }
}

#Preview {
    APIKeySetupView()
}
