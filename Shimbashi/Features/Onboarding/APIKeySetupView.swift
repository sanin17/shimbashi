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
    @State private var isChecking = false
    @State private var problem: Problem?
    @Environment(\.dismiss) private var dismiss
    var onSave: (() -> Void)?
    var validator = GeminiKeyValidator()

    /// Why a key wasn't saved straight away. "Save Anyway" is offered only
    /// when Google couldn't be asked or answered unexpectedly — a flaky
    /// connection mustn't block a good key. A definite rejection never
    /// offers it: that key would just fail on the conversation screen.
    private struct Problem {
        let message: String
        let canSaveAnyway: Bool
    }

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
                    .brandRow()
                }

                Section {
                    SecureField("Paste Gemini API key", text: $newKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(isChecking)
                        .onChange(of: newKey) { _, _ in problem = nil }

                    if isChecking {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Checking with Google…")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let problem {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(problem.message)
                                .font(.footnote)
                                .foregroundStyle(Brand.error)
                            if problem.canSaveAnyway {
                                Button("Save Anyway") { commit(trimmedNewKey) }
                                    .font(.footnote)
                            }
                        }
                    }
                } header: {
                    Text(savedKey == nil ? "Add a Key" : "Replace Key")
                } footer: {
                    Text("Stored in the iOS Keychain on this device only. It's sent only to Google, never to anyone else.")
                }
                .brandRow()

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
                .brandRow()
            }
            .brandList()
            .navigationTitle("Gemini API Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { validateAndSave() }
                        .disabled(trimmedNewKey.isEmpty || isChecking)
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

    /// Checks the key with Google first and only stores it once accepted;
    /// a rejected or unverifiable key stays in the field with the reason
    /// shown beneath it.
    private func validateAndSave() {
        let candidate = trimmedNewKey
        guard !candidate.isEmpty, !isChecking else { return }
        isChecking = true
        problem = nil

        Task {
            let outcome = await validator.validate(candidate)
            isChecking = false
            switch outcome {
            case .valid, .rateLimited:
                // Rate-limited still means Google recognized the key.
                commit(candidate)
            case .rejected:
                problem = Problem(message: "Google didn't accept this key. Make sure you copied the whole key from AI Studio, with no extra characters.", canSaveAnyway: false)
            case .unreachable:
                problem = Problem(message: "Couldn't reach Google to check this key. Check your internet connection and try again, or save it anyway.", canSaveAnyway: true)
            case .unknown(let status):
                problem = Problem(message: "Google gave an unexpected response (\(status)) while checking this key. You can try again or save it anyway.", canSaveAnyway: true)
            }
        }
    }

    private func commit(_ key: String) {
        guard !key.isEmpty else { return }
        Keychain.save(key, for: .geminiAPIKey)
        onSave?()
        dismiss()
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.footnote.bold())
                .foregroundStyle(Brand.sun)
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
