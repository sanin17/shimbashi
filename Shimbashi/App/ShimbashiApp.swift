import SwiftUI
import SwiftData

@main
struct ShimbashiApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(for: [ConversationSession.self, PersistedTurn.self, StruggleNote.self])
    }
}
