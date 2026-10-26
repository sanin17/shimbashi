import SwiftUI

/// The phrase-by-phrase breakdown, in its own screen at a much larger type
/// scale than the inline chat view — a legible breakdown needs more room
/// than a chat bubble can spare, so tapping a turn opens this rather than
/// expanding in place.
struct PhraseBreakdownView: View {
    let turn: DisplayTurn
    let speechPlayback: SpeechPlaybackController
    let onRetryBreakdown: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    mainSentence
                    Rectangle().fill(Brand.hairline).frame(height: 1)
                    phraseList
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .brandScreen()
            .navigationTitle("Breakdown")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var mainSentence: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Text(turn.japanese)
                    .font(.largeTitle.weight(.semibold))
                    .foregroundStyle(.white)
                PlayButton(text: turn.japanese, controller: speechPlayback, iconFont: .title2, cachedPCM16: turn.audio)
            }

            switch turn.translation {
            case .pending:
                NetworkSpinner(controlSize: .regular, badgeSize: 11)
            case .loaded(let result):
                Text(result.romaji)
                    .font(.title3)
                    .foregroundStyle(Brand.textSecondary)
                Text(result.english)
                    .font(.title3)
                    .foregroundStyle(Brand.textTertiary)
            case .failed:
                Text("Translation unavailable")
                    .font(.body)
                    .foregroundStyle(Brand.error)
            case .notApplicable:
                Text("Spoken in English")
                    .font(.body)
                    .foregroundStyle(Brand.textTertiary)
            }
        }
    }

    @ViewBuilder
    private var phraseList: some View {
        switch turn.breakdown {
        case .notRequested, .pending:
            HStack(spacing: 10) {
                NetworkSpinner(controlSize: .regular, badgeSize: 11)
                Text("Breaking down phrases…")
                    .font(.title3)
                    .foregroundStyle(Brand.textSecondary)
            }
        case .loaded(let phrases):
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(phrases.enumerated()), id: \.offset) { _, phrase in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .top, spacing: 10) {
                            Text(phrase.japanese)
                                .font(.title2.weight(.semibold))
                                .foregroundStyle(.white)
                            PlayButton(text: phrase.japanese, controller: speechPlayback, iconFont: .title3)
                        }
                        Text(phrase.romaji)
                            .font(.headline)
                            .foregroundStyle(Brand.textSecondary)
                        Text(phrase.english)
                            .font(.subheadline)
                            .foregroundStyle(Brand.textTertiary)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .brandCard()
                }
            }
        case .failed:
            Button("Couldn't break this down — tap to retry", action: onRetryBreakdown)
                .font(.title3)
                .foregroundStyle(Brand.error)
        case .notApplicable:
            Text("This wasn't Japanese, so there's nothing to break down.")
                .font(.title3)
                .foregroundStyle(Brand.textSecondary)
        }
    }
}
