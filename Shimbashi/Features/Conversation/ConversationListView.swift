import SwiftUI
import SwiftData

/// The home for browsing conversations — one row per past conversation,
/// each with its own preserved transcript, plus a way to start a new one.
/// Reached from `RootView`.
struct ConversationListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ConversationSession.startedAt, order: .reverse) private var sessions: [ConversationSession]
    @State private var showingResetConfirm = false

    var body: some View {
        List {
            Section {
                NavigationLink {
                    ConversationView()
                } label: {
                    Label("New Conversation", systemImage: "plus.bubble.fill")
                }
            }

            if !sessions.isEmpty {
                Section("Past Conversations") {
                    ForEach(sessions) { conversationSession in
                        NavigationLink {
                            // Opens live, not read-only — tapping Start picks
                            // this conversation back up rather than starting
                            // a separate one.
                            ConversationView(resuming: conversationSession)
                        } label: {
                            ConversationRow(conversationSession: conversationSession)
                        }
                    }
                }
            }
        }
        .navigationTitle("Conversations")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Reset", systemImage: "trash") {
                    showingResetConfirm = true
                }
            }
        }
        .confirmationDialog(
            "Reset all conversation history and progress?",
            isPresented: $showingResetConfirm,
            titleVisibility: .visible
        ) {
            Button("Reset Everything", role: .destructive) {
                ConversationStore(context: modelContext).resetAll()
            }
        } message: {
            Text("This deletes all saved conversations and everything tracked about what you've struggled with. This can't be undone.")
        }
    }
}

private struct ConversationRow: View {
    let conversationSession: ConversationSession

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(conversationSession.displayLabel)
                .font(.subheadline.weight(.medium))
            if let summary = conversationSession.summary, !summary.isEmpty {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else if conversationSession.endedAt == nil {
                Text("In progress…")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                let count = conversationSession.turns.count
                Text("\(count) turn\(count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}
