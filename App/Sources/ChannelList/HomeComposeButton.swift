import SwiftUI

/// The home screen's floating `+`: one control, two ways to start something.
///
/// # Why a `Menu` and not a hand-drawn panel
///
/// The reference is the system's own overflow menu — the material, the morph out of the
/// button, the dismissal on a tap anywhere, the scroll if the rows outgrow the screen, and
/// the accessibility. A `Menu` is *given* all five; a hand-drawn popover owns all five, and
/// the app has already paid for that lesson twice (see ``RecentPlacesMenu``, the clock in
/// this screen's toolbar, for the long version).
///
/// Two costs come with the control and are paid here rather than discovered later:
/// a `Menu` label is accent-tinted unless told otherwise — hence the explicit
/// `.foregroundStyle(.primary)`, which is what keeps the `+` the same white as the search
/// button's magnifier — and a `ButtonStyle` never reaches a `Menu`, so the press response is
/// the glass's own `.interactive()` rather than ``HivePressButtonStyle``. That is the right
/// way round: `.regular.interactive()` is exactly what the system draws for the search tab's
/// button, so the two controls answer a finger identically.
///
/// # Why the rows carry a second line
///
/// A menu row's second `Text` is its subtitle, which is what the reference shows. The
/// actions are named as the owner named them — "New Message", "Channel" — and the subtitle
/// says what each one is *for*, because "Channel" alone does not distinguish creating one
/// from browsing for one.
///
/// # The geometry
///
/// This is a second floating button beside a system one, and nothing in `TabView` will place
/// it: the search tab's button is drawn by UIKit outside this view tree. So the constants
/// below put it there, measured off the owner's reference at @3x (an iPhone 16 Pro Max
/// screenshot, 1320px wide, so px÷3): the search circle reads 186px across — **62pt** — with
/// its right edge 64px from the screen edge, **21pt**. The `+` above it is on the same
/// centre line.
struct HomeComposeButton: View {
    /// Opens the new-direct-message sheet.
    let newMessage: () -> Void
    /// Opens the new-channel sheet.
    let newChannel: () -> Void

    var body: some View {
        Menu {
            Button(action: newMessage) {
                Label {
                    Text("New Message")
                    Text("Message someone directly")
                } icon: {
                    Image(systemName: "square.and.pencil")
                }
            }
            Button(action: newChannel) {
                Label {
                    Text("Channel")
                    Text("Organize teams and work")
                } icon: {
                    Image(systemName: "number")
                }
            }
        } label: {
            Image(systemName: "plus")
                // Fixed rather than relative, for the reason the system's own tab-bar glyphs
                // are: this drawing sits inside a circle whose diameter is matched to a
                // control UIKit draws, and type that grew past it would render as a `+`
                // clipped by its own glass.
                .font(.hiveSymbol(fixedSize: Self.glyphPointSize, weight: .semibold))
                // A `Menu`'s label goes accent-tinted by default. See this type's docs.
                .foregroundStyle(.primary)
                .frame(width: Self.diameter, height: Self.diameter)
                .contentShape(.circle)
                .glassEffect(.regular.interactive(), in: .circle)
        }
        // The owner's order, and not the platform's preference for putting the nearest row
        // closest to the finger: "New Message" is the common one and is named first.
        .menuOrder(.fixed)
        .accessibilityLabel("Create")
        .accessibilityHint("Starts a new message or a new channel")
    }

    /// The search tab button's own diameter — 186px at @3x on the owner's reference.
    static let diameter: CGFloat = 62
    /// How big the `+` is inside its glass.
    static let glyphPointSize: CGFloat = 22
    /// The search circle's distance from the trailing screen edge, so the two share a centre
    /// line: 64px at @3x.
    static let trailingInset: CGFloat = 21
    /// The gap above the bottom of the safe area — which the tab bar's own inset has already
    /// lifted clear of the bar — so the two circles read as a pair rather than as one control
    /// touching another.
    static let bottomGap: CGFloat = 8
}

#Preview {
    ZStack(alignment: .bottomTrailing) {
        Color.hiveNight.ignoresSafeArea()
        HomeComposeButton(newMessage: {}, newChannel: {})
            .padding(.trailing, HomeComposeButton.trailingInset)
            .padding(.bottom, HomeComposeButton.bottomGap)
    }
}
