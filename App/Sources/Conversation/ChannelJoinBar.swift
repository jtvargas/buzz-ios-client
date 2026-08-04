import SwiftUI

/// What stands where the composer stands, in an open channel this identity has not
/// joined: what they are looking at, and the one action that changes it.
///
/// Desktop's `ChannelPane.tsx:704-729` — the same words and the same shape, so a reader
/// who has seen one recognises the other.
///
/// # Why it replaces the composer rather than sitting above it
///
/// ``ConversationScaffold``'s bar height *is* the list's bottom inset. A banner stacked
/// above a composer re-insets the conversation and moves the reader's place — the same
/// reason the typing indicator became an accessory rather than a second row in the bar.
/// So this is the bar, for as long as it applies, and the composer returns in its place.
///
/// # Why it is one view used by two surfaces
///
/// A thread is reachable from a channel a reader has not joined — `allowsInteraction`
/// gates the reaction bar and the retry strip, not the replies button, deliberately, since
/// reading is exactly what a non-member may do. So the thread needs this too, and two
/// copies of a bar are two things to keep saying the same sentence.
struct ChannelJoinBar: View {
    /// The channel's display name, resolved by the surface that draws this — it already
    /// holds a ``ConversationIdentity`` and this must agree with the title above it.
    let name: String
    /// Whether a join is on the wire. Drives the words and the disabled state together, so
    /// there is no moment where the button says *Join* but does nothing.
    let isJoining: Bool
    /// `nil` on a surface with no way to join — the fixture host, and any future caller
    /// built without an engine. The line still explains why there is no composer; what it
    /// does not do is offer a button that cannot work.
    let join: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Text("Viewing #\(name)")
                .font(.hive(.subheadline))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                // The name yields first: the button is the point of this bar, and a long
                // channel name must not push it off the edge.
                .truncationMode(.tail)

            Spacer(minLength: 0)

            if let join {
                Button(action: join) {
                    // A fixed label rather than a spinner swap: the button keeps its width
                    // across the transition, so the bar does not reflow under a thumb that
                    // is still on it.
                    Text(isJoining ? "Joining…" : "Join to participate")
                        .font(.hive(.subheadline, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .disabled(isJoining)
                .accessibilityIdentifier("join-banner-action")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .accessibilityIdentifier("join-banner")
    }
}
