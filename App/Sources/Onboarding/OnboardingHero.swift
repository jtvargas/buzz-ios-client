import SwiftUI

/// The app mark at the top of onboarding: a filled hexagon inside a wider stroked one, lit from
/// behind.
///
/// Three layers rather than one glyph because a single flat `hexagon.fill` sitting on the
/// animated lattice reads as one more cell of it. The ring separates the mark from the pattern,
/// and the glow behind it is what the honeycomb's radial falloff is aimed at — the lattice
/// appears to be radiating out of the mark rather than merely being behind it.
struct HiveMark: View {
    var size: CGFloat = 68

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [.hiveAccent.opacity(0.34), .hiveAccent.opacity(0.06), .clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: size * 1.5
                    )
                )
                .frame(width: size * 3, height: size * 3)
                .blur(radius: size * 0.18)

            Image(systemName: "hexagon")
                .font(.hiveSymbol(fixedSize: size * 1.62, weight: .light))
                .foregroundStyle(.hiveAccent.opacity(0.22))

            Image(systemName: "hexagon.fill")
                .font(.hiveSymbol(fixedSize: size))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.hiveHoneyGlow, .hiveAccent],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .shadow(color: .hiveAccent.opacity(0.55), radius: size * 0.32)
        }
        // The glow is three times the mark; without this it pushes everything below it down
        // the screen by a hundred points of empty air.
        .frame(width: size * 1.7, height: size * 1.7)
        .accessibilityHidden(true)
    }
}

/// Mark, title and one line of explanation — the top of the onboarding screen.
///
/// The title is split so `for Buzz` can carry the accent: it says which network this client
/// speaks to, which is the one thing a reader arriving from the desktop app needs to recognise,
/// and it says it without spending a second line of body copy on it.
struct OnboardingHero: View {
    let title: String
    /// The accent line under the title, or `nil` to leave it off — the add-a-community sheet
    /// is already inside Buzz, so the badge there would be telling the reader something they
    /// have known since they installed the app.
    let accentLine: String?
    let blurb: String
    var markSize: CGFloat = 68

    var body: some View {
        VStack(spacing: 0) {
            HiveMark(size: markSize)

            VStack(spacing: 4) {
                Text(title)
                    .font(.hive(.largeTitle, weight: .bold))
                    .foregroundStyle(.white)
                if let accentLine {
                    Text(accentLine)
                        .font(.hive(.headline, weight: .semibold))
                        .foregroundStyle(.hiveAccent)
                }
            }
            .multilineTextAlignment(.center)
            .padding(.top, 18)

            Text(blurb)
                .font(.hive(.subheadline))
                .foregroundStyle(.white.opacity(0.74))
                .multilineTextAlignment(.center)
                .padding(.top, 10)
                .padding(.horizontal, 12)
        }
        // The lattice is brightest exactly when a wave crest is passing behind the type, which
        // is a different moment on every launch — so legibility cannot be tuned into the
        // shader's average frame. A shadow costs nothing on a near-black ground and holds the
        // text off the pattern in the frames that would otherwise be the worst ones.
        .shadow(color: .hiveNight.opacity(0.75), radius: 9)
        .accessibilityElement(children: .combine)
        .accessibilityLabel([title, accentLine, blurb].compactMap(\.self).joined(separator: ". "))
    }
}

#Preview("Hero") {
    ZStack {
        HoneycombBackground()
        OnboardingHero(
            title: "Welcome to Hive",
            accentLine: "for Buzz",
            blurb: OnboardingView.welcomeBlurb
        )
    }
}
