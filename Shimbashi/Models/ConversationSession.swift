import Foundation
import SwiftData
import VoiceCore

/// One conversation from Start to Stop (or app close). Kept even after the
/// live connection ends so the next launch can show what was last discussed
/// and prime a new connection with a brief recap.
@Model
final class ConversationSession {
    var startedAt: Date
    var endedAt: Date?
    /// A short human-readable summary of what was discussed, generated once
    /// the session ends — what the resume screen actually shows, rather than
    /// a raw transcript excerpt.
    var summary: String?
    @Relationship(deleteRule: .cascade, inverse: \PersistedTurn.session)
    var turns: [PersistedTurn] = []

    init(startedAt: Date = Date()) {
        self.startedAt = startedAt
    }
}

extension ConversationSession {
    private static let labelFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        return formatter
    }()

    /// A human-readable label for this conversation (e.g. "Sep 4, 4:34 PM")
    /// — used as the list row's title and the detail view's navigation title.
    var displayLabel: String {
        Self.labelFormatter.string(from: startedAt)
    }
}

/// A `Turn` (from VoiceCore) as persisted to disk, with translation attached
/// once it arrives — mirrors `DisplayTurn` but durable across app launches.
@Model
final class PersistedTurn {
    /// Matches `Turn.id`/`DisplayTurn.id` — lets `ConversationStore` find this
    /// exact row again once translation/breakdown load in a moment after the
    /// bare turn is first persisted (see `ConversationStore.updateTranslation`).
    /// Defaulted (not just optional) so SwiftData's lightweight migration can
    /// backfill it on rows that predate this field without a migration plan.
    var id: UUID = UUID()
    var speakerRaw: String
    var japanese: String
    var romaji: String?
    var english: String?
    /// JSON-encoded `[PhraseGloss]` — see the `breakdown` computed property.
    var breakdownJSON: Data?
    var timestamp: Date
    var session: ConversationSession?

    init(id: UUID, speaker: Turn.Speaker, japanese: String, romaji: String? = nil, english: String? = nil, timestamp: Date = Date()) {
        self.id = id
        self.speakerRaw = speaker == .user ? "user" : "model"
        self.japanese = japanese
        self.romaji = romaji
        self.english = english
        self.timestamp = timestamp
    }

    var speaker: Turn.Speaker { speakerRaw == "user" ? .user : .model }

    var breakdown: [PhraseGloss]? {
        get {
            guard let breakdownJSON else { return nil }
            return try? JSONDecoder().decode([PhraseGloss].self, from: breakdownJSON)
        }
        set {
            breakdownJSON = newValue.flatMap { try? JSONEncoder().encode($0) }
        }
    }
}
