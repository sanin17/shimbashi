import Foundation

/// Builds the "here's what's been said so far" block that seeds a brand-new
/// Live connection partway through a conversation.
///
/// Gemini Live remembers nothing across connections, and a new connection is
/// exactly what happens when the learner locks their phone, switches apps,
/// or recovers from a failure and taps Start again. Without this the tutor
/// greets them as a stranger. With it, the model is told the conversation is
/// already underway and shown the recent turns verbatim.
enum ConversationContext {
    struct Line: Sendable, Equatable {
        var speaker: Turn.Speaker
        var text: String
    }

    /// The most recent turns that fit: few enough to stay cheap on every
    /// reconnect, each trimmed so one long reply can't crowd out the rest.
    static let maxTurns = 24
    static let maxCharactersPerTurn = 500
    static let maxTotalCharacters = 6_000

    static func prompt(from lines: [Line]) -> String? {
        let spoken = lines
            .map { Line(speaker: $0.speaker, text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.text.isEmpty }
            .suffix(maxTurns)
        guard !spoken.isEmpty else { return nil }

        var rendered = spoken.map { line -> String in
            let label = line.speaker == .user ? "Learner" : "Tutor"
            let text = line.text.count > maxCharactersPerTurn
                ? String(line.text.prefix(maxCharactersPerTurn)) + "…"
                : line.text
            return "\(label): \(text)"
        }

        // Over budget: drop the oldest turns first — the latest exchange is
        // what the next reply most needs to follow.
        while rendered.count > 1, rendered.joined(separator: "\n").count > maxTotalCharacters {
            rendered.removeFirst()
        }

        return """
        This conversation is already in progress. The learner stepped away briefly and has now \
        returned. Pick up naturally where you left off — do not greet them again or start over. \
        What has been said so far, oldest first:
        \(rendered.joined(separator: "\n"))
        """
    }
}
