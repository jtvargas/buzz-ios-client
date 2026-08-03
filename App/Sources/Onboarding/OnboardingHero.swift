import SwiftUI

/// The app mark at the top of onboarding: the app icon itself, lit from behind.
///
/// It draws `HiveMark` from the asset catalog rather than an SF Symbol hexagon. The symbol was
/// a stand-in and it read as one: a bare `hexagon.fill` sitting on a hexagonal lattice looks
/// like one more cell of the pattern, where the icon — bee inside the comb — is the thing a
/// reader already has on their home screen. The art is the same layer the icon is built from
/// (`hive-buzz-app.icon/Assets/Group 2678.png`), copied into the catalog because the `.icon`
/// wrapper is compiled by `actool` for the launcher and its layers are not addressable by name
/// at runtime.
///
/// The glow behind it stays, quietly. It is what the honeycomb's radial falloff is aimed at, so
/// the lattice appears to radiate out of the mark rather than merely sit behind it.
struct HiveMark: View {
    var size: CGFloat = 68

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [.hiveAccent.opacity(0.14), .clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: size * 1.2
                    )
                )
                .frame(width: size * 2.4, height: size * 2.4)
                .blur(radius: size * 0.22)

            // The icon carries its own transparent margin, so it is drawn larger than `size`
            // to land on the same optical width the symbol had.
            Image("HiveMark")
                .resizable()
                .scaledToFit()
                .frame(width: size * 1.5, height: size * 1.5)
        }
        // The glow is wider than the mark; without this it pushes everything below it down the
        // screen by a hundred points of empty air.
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
