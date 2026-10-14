import SwiftUI

/// One turn's row — used both by the live `ConversationView` transcript and
/// the read-only `ConversationHistoryView`. Tap any turn to open its
/// phrase-by-phrase breakdown in its own screen (see `PhraseBreakdownView`),
/// fetched lazily on first tap if not already cached (see
/// `ConversationCoordinator.requestBreakdown`).
struct TurnCell: View {
    let turn: DisplayTurn
    let speechPlayback: SpeechPlaybackController
    let onSelect: () -> Void

    private var horizontalEdge: Alignment { turn.speaker == .user ? .trailing : .leading }

    var body: some View {
        VStack(alignment: turn.speaker == .user ? .trailing : .leading, spacing: 3) {
            HStack(spacing: 4) {
                if turn.speaker != .user {
                    breakdownIndicator
                    PlayButton(text: turn.japanese, controller: speechPlayback, cachedPCM16: turn.audio)
                }
                Text(turn.japanese)
                    .font(.title3)
                if turn.speaker == .user {
                    PlayButton(text: turn.japanese, controller: speechPlayback)
                    breakdownIndicator
                }
            }

            switch turn.translation {
            case .pending:
                NetworkSpinner()
            case .loaded(let result):
                Text(result.romaji)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(result.english)
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            case .failed:
                Text("Translation unavailable")
                    .font(.caption)
                    .foregroundStyle(.red)
            case .notApplicable:
                Text("Spoken in English")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: horizontalEdge)
        .multilineTextAlignment(turn.speaker == .user ? .trailing : .leading)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }

    private var breakdownIndicator: some View {
        Image(systemName: "chevron.right")
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }
}
