import SwiftUI

/// The parts the three join steps are built out of.
///
/// The join used to be a `Form`, and a `Form` is the right answer to "several unrelated
/// settings on one screen" — which is not what this is. This is a walk with three stops on it,
/// over the same honeycomb the welcome screen draws, and a grouped table on top of that
/// background is an opaque grey slab covering the artwork with rows the reader is not choosing
/// between. So the steps are laid out by hand out of the pieces here, which are the same glass
/// cards ``CommunityCard`` and ``OnboardingRelayField`` already use on the screen this flow is
/// entered from.
///
/// Nothing in this file knows what a join is. It is chrome.

// MARK: - Focus

/// The fields across all three steps.
///
/// One type for the whole walk, rather than one per step, because the control that hands the
/// keyboard back lives on the navigation stack above them and does not care which step raised
/// it. It is here rather than nested in ``JoinCommunityView`` so the profile step — which is its
/// own file — can bind to the same focus state.
enum JoinField: Hashable {
    case link
    case name
    case nsec
}

// MARK: - Cards

/// One glass panel. The unit every step is built from, matching the two cards the onboarding
/// hero already stacks.
struct JoinCard<Content: View>: View {
    var spacing: CGFloat = 10
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}

/// The small caps line naming what a card is for, and the accent glyph beside it.
///
/// The `Form` this replaces got these for free as section headers. They are worth keeping: with
/// three cards on a step and no table rules between them, the heading is what says where one
/// question ends and the next begins.
struct JoinCardLabel: View {
    let text: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.hiveAccent)
            Text(text)
                .foregroundStyle(.white.opacity(0.85))
        }
        .font(.hive(.footnote, weight: .medium))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The explanatory line under a card's controls — a `Form` footer, without the table.
struct JoinCardNote: View {
    let text: String
    var isRefusal = false

    var body: some View {
        Text(text)
            .font(.hive(.caption2))
            .foregroundStyle(isRefusal ? Color.red : .white.opacity(0.5))
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Fields

/// A text field drawn to sit inside a glass card.
///
/// The platform's own field styles are drawn for a table cell or a bordered box on an opaque
/// background; on glass over a lit lattice both disappear. This is the same inset well
/// ``OnboardingRelayField`` uses, so a reader moving from the welcome screen into the join is
/// typing into the same-looking control.
struct JoinFieldBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.hive(.subheadline))
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(.white.opacity(0.07), in: .rect(cornerRadius: 11))
    }
}

extension View {
    /// See ``JoinFieldBackground``.
    func joinFieldBackground() -> some View { modifier(JoinFieldBackground()) }
}

// MARK: - Progress

/// Where the reader is in the walk, as a row of bars.
///
/// Bars rather than `Step 2 of 3`, and rather than dots: three short rules read as a distance
/// with an amount of it behind you, which is the one thing a progress indicator is for. The
/// step's own heading says what the step *is*, so this does not have to.
///
/// The steps behind stay lit rather than dimming, because they are done — a row where only the
/// current bar is lit says "you are on the second of three" and a row where the first two are
/// lit also says "one to go", which is the question somebody halfway through a join is asking.
struct JoinStepBars: View {
    let index: Int
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0 ..< count, id: \.self) { position in
                Capsule()
                    .fill(position <= index ? Color.hiveAccent : .white.opacity(0.18))
                    .frame(width: position == index ? 26 : 16, height: 4)
            }
        }
        .animation(.snappy(duration: 0.25), value: index)
        .accessibilityElement()
        .accessibilityLabel("Step \(index + 1) of \(count)")
    }
}

/// The bars, the heading, and the line under it — the top of every step.
struct JoinStepHeader: View {
    let index: Int
    let count: Int
    let title: String
    let blurb: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            JoinStepBars(index: index, count: count)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.hive(.title2, weight: .bold))
                    .foregroundStyle(.white)
                Text(blurb)
                    .font(.hive(.subheadline))
                    .foregroundStyle(.white.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The same reason the hero carries one: the lattice is brightest exactly when a light
        // is passing behind the type, which is a different moment on every launch.
        .shadow(color: .hiveNight.opacity(0.75), radius: 9)
    }
}
