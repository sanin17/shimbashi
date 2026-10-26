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
        bubble
            .frame(maxWidth: .infinity, alignment: horizontalEdge)
            // Leave the far side open so replies and answers read as two
            // sides of a chat rather than full-width blocks.
            .padding(turn.speaker == .user ? .leading : .trailing, 28)
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelect)
    }

    private var bubble: some View {
        VStack(alignment: turn.speaker == .user ? .trailing : .leading, spacing: 4) {
            HStack(spacing: 6) {
                if turn.speaker != .user {
                    breakdownIndicator
                    PlayButton(text: turn.japanese, controller: speechPlayback, cachedPCM16: turn.audio)
                }
                Text(turn.japanese)
                    .font(.title3)
                    .foregroundStyle(.white)
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
                    .foregroundStyle(Brand.textSecondary)
                Text(result.english)
                    .font(.footnote)
                    .foregroundStyle(Brand.textTertiary)
            case .failed:
                Text("Translation unavailable")
                    .font(.caption)
                    .foregroundStyle(Brand.error)
            case .notApplicable:
                Text("Spoken in English")
                    .font(.caption)
                    .foregroundStyle(Brand.textTertiary)
            }
        }
        .multilineTextAlignment(turn.speaker == .user ? .trailing : .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(bubbleBackground)
    }

    @ViewBuilder
    private var bubbleBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        if turn.speaker == .user {
            // The learner's side carries the brand's orange.
            shape.fill(
                LinearGradient(
                    colors: [Brand.toriiLight.opacity(0.58), Brand.toriiDeep.opacity(0.50)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(shape.strokeBorder(Brand.toriiLight.opacity(0.55), lineWidth: 1))
        } else {
            shape.fill(Brand.surface)
                .overlay(shape.strokeBorder(Brand.hairline, lineWidth: 1))
        }
    }

    private var breakdownIndicator: some View {
        Image(systemName: "chevron.right")
            .font(.caption2)
            .foregroundStyle(Brand.textTertiary)
    }
}
