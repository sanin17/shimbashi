import SwiftUI

/// The app's look, in one place. Everything is drawn from the icon: a
/// night-indigo sky, a warm sunrise glow, and the torii's orange. The whole
/// app runs in dark appearance (see `ShimbashiApp`), so these colors are
/// fixed rather than adaptive.
enum Brand {
    static let night = Color(red: 0.07, green: 0.08, blue: 0.22)
    static let indigo = Color(red: 0.17, green: 0.18, blue: 0.43)
    static let dusk = Color(red: 0.30, green: 0.22, blue: 0.50)
    static let sun = Color(red: 1.00, green: 0.72, blue: 0.45)
    static let toriiLight = Color(red: 0.96, green: 0.38, blue: 0.20)
    static let toriiDeep = Color(red: 0.84, green: 0.23, blue: 0.17)

    /// A frosted card or row sitting on the gradient.
    static let surface = Color.white.opacity(0.09)
    static let surfaceStrong = Color.white.opacity(0.15)
    static let hairline = Color.white.opacity(0.14)

    static let textSecondary = Color.white.opacity(0.72)
    static let textTertiary = Color.white.opacity(0.58)
    /// Errors, lightened so they stay legible on the dark gradient.
    static let error = Color(red: 1.00, green: 0.50, blue: 0.48)

    static var torii: LinearGradient {
        LinearGradient(
            colors: [toriiLight, toriiDeep],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

/// The night-sky gradient with a soft sunrise glow. `glowCenter` and
/// `glowStrength` let the home screen put the sun behind its logo while
/// working screens keep a faint glow at the top.
struct BrandBackground: View {
    var glowCenter = UnitPoint(x: 0.5, y: 0.0)
    var glowStrength = 0.20

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Brand.night, Brand.indigo, Brand.dusk],
                startPoint: .top,
                endPoint: .bottom
            )
            RadialGradient(
                colors: [Brand.sun.opacity(glowStrength), Brand.sun.opacity(glowStrength * 0.25), .clear],
                center: glowCenter,
                startRadius: 10,
                endRadius: 340
            )
        }
        .ignoresSafeArea()
    }
}

extension View {
    /// The standard look for a screen pushed onto, or presented over, the
    /// home screen: the gradient behind it, and a navigation bar that
    /// matches it.
    func brandScreen() -> some View {
        self
            .background(BrandBackground())
            .toolbarBackground(Brand.night.opacity(0.94), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
    }

    /// `brandScreen()` for a `Form` or `List`, whose own opaque background
    /// has to be hidden for the gradient to show.
    func brandList() -> some View {
        self
            .scrollContentBackground(.hidden)
            .brandScreen()
    }

    /// A frosted row on the gradient — for rows inside a `Form`/`List`.
    func brandRow() -> some View {
        self
            .listRowBackground(Brand.surface)
            .listRowSeparatorTint(Brand.hairline)
    }

    /// A rounded frosted card, for content that isn't in a list.
    func brandCard(cornerRadius: CGFloat = 18) -> some View {
        self
            .background(Brand.surface, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Brand.hairline, lineWidth: 1)
            )
    }
}

// MARK: - Button styles

/// The one big call to action on a screen: torii orange.
struct PrimaryActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.title3.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 17)
            .background(Brand.torii, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: Brand.toriiDeep.opacity(0.45), radius: 14, y: 6)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

/// A quieter, frosted action beside or below the primary one.
struct SecondaryActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(.white.opacity(0.92))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                Color.white.opacity(configuration.isPressed ? 0.18 : 0.10),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Brand.hairline, lineWidth: 1)
            )
    }
}

/// A small white pill — for an inline action on a frosted card.
struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Brand.night)
            .padding(.horizontal, 22)
            .padding(.vertical, 9)
            .background(.white, in: Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// The push-to-talk button. Start is the brand's orange; Stop flips to white
/// so the two states can't be mistaken for each other at a glance.
struct RecordButtonStyle: ButtonStyle {
    let isRecording: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.title3.weight(.semibold))
            .foregroundStyle(isRecording ? Brand.night : .white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 17)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isRecording ? AnyShapeStyle(Color.white) : AnyShapeStyle(Brand.torii))
            )
            .shadow(
                color: (isRecording ? Color.white : Brand.toriiDeep).opacity(0.35),
                radius: 14,
                y: 6
            )
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}
