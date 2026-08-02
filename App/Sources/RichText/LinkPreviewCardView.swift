import SwiftUI

/// One link card, drawn under the message that points at the link.
///
/// # Compact on purpose
///
/// Two lines and an icon, and never more: a caption saying where the link lives and a
/// title saying which thing it is. Both are held to one line, which is what makes the
/// card's height a constant — the same requirement a picture's box meets, met more
/// cheaply because nothing here has to wait for bytes to know its shape. Four of these
/// under a one-line message is already a third of a phone screen, which is why
/// ``RichTextLinkPreview/maximumCards`` is four.
///
/// The card deliberately does *not* carry a preview image, a description, or the page's
/// own headline. None of the three can be had without fetching the page from the reader's
/// device — see ``LinkPreview`` for why that is a different proposition on a phone than
/// on a server — and a card that shows a stale or invented one of them is worse than a
/// card that shows the URL's own words.
///
/// # Frame
///
/// The attachment frame, on purpose. A picture and a link card are the same object class
/// in a conversation — a bordered rectangle appended under a message — and drawing them
/// on two nearly-identical sets of constants is how the two drift apart. Same fill, same
/// hairline, same radius, same maximum width, so a message carrying both reads as one
/// stack rather than two.
struct LinkPreviewCardView: View {
    let preview: LinkPreview
    /// Opens the link. Supplied by ``RichTextView`` as the surface's own `openURL`, which
    /// in a message row is the action that claims the tap — so pressing a card never also
    /// opens the thread behind it, exactly as pressing a link in the text does not.
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(alignment: .center, spacing: 10) {
                LinkPreviewIconView(preview: preview)
                VStack(alignment: .leading, spacing: 1) {
                    if let caption = preview.caption {
                        Text(caption)
                            .font(.hive(.caption))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Text(preview.title)
                        // Semibold is resolved while Inter's variable face is built;
                        // applying a trait over an existing custom font is unreliable.
                        .font(.hive(.subheadline, weight: .semibold))
                        .lineLimit(1)
                        // The head, not the tail: a title that does not fit is nearly
                        // always a path, and the end of a path — the file, the number —
                        // is the half that says which one it is.
                        .truncationMode(preview.provider == nil ? .head : .tail)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(MessageMediaFrame.fill)
            .clipShape(MessageMediaFrame.shape)
            .overlay {
                MessageMediaFrame.shape.strokeBorder(MessageMediaFrame.border, lineWidth: 1)
            }
        }
        // A `ButtonStyle` and not a `DragGesture(minimumDistance: 0)` on the card, which is
        // the construction that reads press-down state directly and is exactly what this app
        // has already measured as unaffordable inside a message list — a zero-distance drag
        // on a row stops the list scrolling. A button cancels itself on a drag, so the same
        // list still scrolls off a card. The card's own frame is named as the wash's shape
        // rather than left on the shared corner radius, because ``MessageMediaFrame/fill`` is
        // translucent: a wash in a shape this card does not have would show through it.
        .buttonStyle(.hivePress(.control, in: MessageMediaFrame.shape))
        // The card owns a hold on itself, exactly as it already owns a tap on itself.
        //
        // A message row is holdable everywhere — that is how its actions sheet opens — so this
        // press and the row's are the same physical gesture landing on two things at once, and
        // one of them has to win. The card wins, on the rule the tap already follows: pressing a
        // card opens the link and does *not* open the thread behind it, so holding a card copies
        // the link and does not open the message's sheet behind it. Innermost thing under the
        // finger owns the touch, for both durations. The reader aims at a card and gets the
        // card's answer; every other point on the message still gets the sheet.
        //
        // `highPriorityGesture` and not `gesture`, because two recognisers have to be beaten and
        // only one of them is the row's: the card is a `Button`, and its own tap must not also
        // fire on the release of a hold — a hold that copied the link *and* opened it in Safari
        // is the whole feature reading as broken.
        //
        // A bare `LongPressGesture` with `onEnded` alone, and nothing that observes the press
        // going down — no `onPressingChanged`, no `@GestureState`. That is not stylistic: a
        // gesture that tracks from touch-down takes the touch away from the scroll view it is
        // inside, and this app has already shipped a conversation that could not be scrolled at
        // all that way. See ``PressFeedbackButtonStyle`` and `TimelineRowView.pressGesture`,
        // which both carry the same prohibition.
        .highPriorityGesture(
            LongPressGesture(minimumDuration: LinkCopy.longPressDuration)
                .onEnded { _ in LinkCopy.copy(preview) }
        )
        .frame(maxWidth: MessageMediaLayout.maximumWidth, alignment: .leading)
        // A message row folds its children into one utterance with
        // `.accessibilityElement(children: .combine)`, which keeps this label and drops
        // the button. The custom action below is what survives that, for the reason
        // ``MessageMediaView`` has one.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isLink)
        // A hold is not reachable by VoiceOver, so the copy needs a named action or it does not
        // exist for anybody navigating by rotor — the same reason "Open link" is spelled out
        // here rather than left to the combined row's tap.
        .accessibilityActions {
            Button("Open link", action: open)
            Button("Copy link") { LinkCopy.copy(preview) }
        }
    }

    /// What VoiceOver reads: the thing, then where it lives. The words on the card, in
    /// the order they would be read aloud rather than the order they are stacked — "Pull
    /// request, jtvargas/buzz-ios-client #61, on GitHub" says what it is before it says
    /// where, which is how somebody scanning a message by ear needs it.
    private var accessibilityLabel: String {
        [preview.typeLabel.map { "\($0.prefix(1).uppercased())\($0.dropFirst())" }, preview.title, preview.caption]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}
