import Foundation
import SwiftData

/// One thing the learner struggled with, extracted from a session transcript
/// after it ends. Surfaced back into the next session's system prompt so the
/// tutor can naturally work it back in — spaced repetition without flashcards.
@Model
final class StruggleNote {
    var phrase: String
    var note: String
    var createdAt: Date

    init(phrase: String, note: String, createdAt: Date = Date()) {
        self.phrase = phrase
        self.note = note
        self.createdAt = createdAt
    }
}
