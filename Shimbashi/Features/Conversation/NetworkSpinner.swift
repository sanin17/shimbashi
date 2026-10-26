import SwiftUI

/// A spinner with the same small cloud badge `PlayButton` uses for a live
/// Gemini call — for the handful of other spinners in the app (translation,
/// breakdown, session summary) that are *always* waiting on a network
/// response, never local work. Keeps the badge meaning consistent app-wide:
/// see it, it's an API call in flight; a plain spinner with no badge
/// anywhere in the app means the wait is purely local.
struct NetworkSpinner: View {
    var controlSize: ControlSize = .mini
    var badgeSize: CGFloat = 8

    var body: some View {
        ProgressView()
            .controlSize(controlSize)
            .overlay(alignment: .topTrailing) {
                Image(systemName: "icloud.and.arrow.down")
                    .font(.system(size: badgeSize, weight: .bold))
                    .foregroundStyle(Brand.sun)
                    .offset(x: badgeSize * 0.9, y: -badgeSize * 0.75)
            }
    }
}
