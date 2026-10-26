import SwiftUI
import SwiftData

@main
struct ShimbashiApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                // The whole app is a night-sky design drawn from the icon, so
                // it always runs in dark appearance (system controls included).
                .preferredColorScheme(.dark)
        }
        .modelContainer(for: [ConversationSession.self, PersistedTurn.self, StruggleNote.self])
    }
}
