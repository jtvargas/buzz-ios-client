import SwiftUI

/// The chip rail above the Activity list: which slice is being read, and what is waiting
/// under the ones that are not.
///
/// # Why a rail rather than a menu
///
/// Desktop puts these in a dropdown (`desktop/src/features/home/ui/InboxFilterMenu.tsx`)
/// because desktop has a mouse and a sidebar's worth of room. On a phone a dropdown costs a
/// tap to *see* the options, hides which one is active until you open it, and — the part
/// that matters most here — can never show that three mentions are waiting under a filter
/// you are not looking at. The rail is one tap per switch, always states the selection, and
/// carries the counts. That is the "easier to understand and control" JT asked for.
///
/// # The counts
///
/// A chip wears its unread conversation count, never its total. The total is not news: the
/// Mentions chip reading 47 on a workspace that has mentioned you 47 times all year tells
/// nobody anything, and it makes the number people *do* need — the two they have not read —
/// unreadable next to it. The selected chip drops its count entirely, because the list
/// directly below it is already the answer.
struct ActivityFilterRail: View {
    @Binding var selection: ActivityFilter
    /// Unread conversations under each chip. Asked per chip rather than handed a
    /// dictionary so the caller cannot half-fill one.
    let unreadCount: (ActivityFilter) -> Int

    var body: some View {
        ScrollView(.horizontal) {
            // One container for the whole rail, so the chips are sampled together and read
            // as one control — the same reason the emoji picker's field and its dismiss
            // button share one (``EmojiPickerView/bottomSearchBar``). Separately-glassed
            // capsules 8pt apart read as five unrelated lozenges.
            GlassEffectContainer {
                HStack(spacing: Self.spacing) {
                    ForEach(ActivityFilter.allCases) { filter in
                        chip(filter)
                    }
                }
                .padding(.horizontal, Self.insets)
            }
        }
        .scrollIndicators(.hidden)
        // The rail is a control strip, not content: it must not bounce away from the leading
        // edge on a narrow phone where the five chips nearly fit.
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .padding(.vertical, Self.verticalPadding)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Filter activity")
    }

    private func chip(_ filter: ActivityFilter) -> some View {
        let isSelected = filter == selection
        let count = isSelected ? 0 : unreadCount(filter)
        return Button {
            selection = filter
        } label: {
            HStack(spacing: 6) {
                Text(filter.title)
                    // Semibold when selected — the weight change is what makes the
                    // selection legible without colour, which is the only version of this
                    // that works for a reader who cannot see the tint.
                    .font(.hive(.subheadline, weight: isSelected ? .semibold : .medium))
                if count > 0 {
                    Text(count, format: .number)
                        .font(.hive(.caption2, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.accentColor, in: .capsule)
                }
            }
            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 14)
            .frame(height: Self.height)
            .contentShape(.capsule)
        }
        .buttonStyle(.hivePress(.control, in: .capsule))
        // Tinted glass for the selection rather than an opaque fill: the tint is what iOS 26
        // gives a selected segment, and it keeps the chip refracting the list scrolling under
        // it instead of becoming a solid pill sitting on top of the content.
        //
        // `.interactive()` on both, because every chip is tapped — including the selected one,
        // which has to answer the finger even though it changes nothing.
        .glassEffect(
            isSelected
                ? .regular.tint(.accentColor).interactive()
                : .regular.interactive(),
            in: .capsule
        )
        .animation(.snappy(duration: 0.22), value: isSelected)
        .accessibilityLabel(label(filter, count: unreadCount(filter)))
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    /// What VoiceOver reads. The count is spoken as words rather than as a bare number
    /// beside a name, which is how it reaches someone who cannot see that the digit is in a
    /// badge: "Mentions, 3 unread" rather than "Mentions 3".
    private func label(_ filter: ActivityFilter, count: Int) -> String {
        guard count > 0 else { return filter.title }
        return "\(filter.title), \(count) unread"
    }

    /// 34, not the 44 a standalone control would take: these sit in a strip with a list
    /// directly under them, the touch target is the full-width capsule rather than a
    /// glyph, and a 44pt rail eats a whole row of content off the top of the screen.
    private static let height: CGFloat = 34
    private static let spacing: CGFloat = 8
    /// Matched to ``ActivityView``'s row insets so a chip's leading edge lines up with the
    /// avatars below it rather than sitting a few points inside or outside them.
    private static let insets: CGFloat = 16
    private static let verticalPadding: CGFloat = 8
}

#Preview("Filter rail") {
    @Previewable @State var selection: ActivityFilter = .all
    let counts: [ActivityFilter: Int] = [.all: 7, .mentions: 3, .action: 1, .agents: 12]
    return VStack {
        ActivityFilterRail(selection: $selection) { counts[$0] ?? 0 }
        Spacer()
    }
    .background(Color(.systemGroupedBackground))
}
