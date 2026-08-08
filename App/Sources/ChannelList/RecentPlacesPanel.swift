import SwiftUI

/// One line of the history, already resolved: the place, and what the app calls it *now*.
///
/// A value rather than an id the panel looks up, and that is the whole reason this type
/// exists — see ``RecentPlacesHistory`` for what a live lookup inside a presented popover
/// costs. Resolution still happens through the shared ``EntityNames``, at the moment the
/// panel opens, so a channel renamed since the visit is listed under its new name and a
/// peer whose picture has landed since is drawn with it.
struct RecentPlaceRow: Identifiable, Hashable {
    let place: RecentPlace
    let conversation: ConversationIdentity

    var id: String { place.id }
}

/// Everything the history popover needs, in one object whose *identity* never changes.
///
/// # Why a box and not two `@State` fields on the button
///
/// A `.popover`'s content rides to UIKit as a **preference**: when the content value
/// changes, SwiftUI dismisses the presentation and re-presents it — and a dismissal landing
/// in the same update as a navigation traps inside UIKit's transition machinery. That is
/// the crash the owner hit four times, and the version before this one still had two ways
/// to cause it: the panel resolved every row through ``EntityNames`` while it was on screen
/// (so an arriving name or picture rewrote the content), and it carried a closure back to
/// the sidebar (so a rebuild of the *toolbar* handed the popover a fresh function value).
///
/// Passing this box instead settles both. It is a class, so the content the popover holds
/// is one unchanging reference no matter how often the toolbar around it is rebuilt, and
/// the only observable thing the panel reads — ``rows`` — is written once, before the
/// popover is presented, and never again while it is up.
///
/// ``chosen`` is written by a row and read only from an action, so writing it invalidates
/// nothing: the tap records what to open and lets the popover close itself, and the button
/// acts on it once the popover has actually gone.
@MainActor
@Observable
final class RecentPlacesHistory {
    /// The list on screen. Filled by the button's action; never touched while presented.
    var rows: [RecentPlaceRow] = []
    /// Where the reader asked to go, held until the popover dismissing them has gone.
    var chosen: RecentPlace?
}

/// The history: the last places this reader was, newest first, each one a way back.
///
/// Drawn as the content of a native `.popover` — the system's own dropdown, anchored to the
/// clock in the toolbar, with the system's glass and the system's dismissal. It draws no
/// background of its own: glass inside glass is a second refraction of the same backdrop,
/// and the popover has already supplied the shape.
struct RecentPlacesPanel: View {
    let history: RecentPlacesHistory

    /// The popover's own dismissal. Used rather than reaching back to the button's flag,
    /// because a row must not carry a closure to the sidebar — see ``RecentPlacesHistory``.
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("History")
                .font(.hive(.subheadline, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, Self.horizontalPadding)
                .padding(.top, 14)
                .padding(.bottom, 6)
                .accessibilityAddTraits(.isHeader)
            if history.rows.isEmpty {
                empty
            } else {
                list
            }
        }
        .frame(width: Self.width)
        // Sizes to the rows until there are enough of them to need scrolling, so a history
        // of three is a popover the size of three rows rather than a tall box with a gap
        // under it.
        .frame(maxHeight: Self.maxHeight)
        .presentationCompactAdaptation(.popover)
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(history.rows) { row in
                    self.row(row)
                }
            }
            .padding(.bottom, 6)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var empty: some View {
        Text("Nowhere yet")
            .font(.hive(.subheadline))
            .foregroundStyle(.secondary)
            .padding(.horizontal, Self.horizontalPadding)
            .padding(.bottom, 14)
    }

    private func row(_ row: RecentPlaceRow) -> some View {
        Button {
            // Recorded, not acted on. Navigating from inside a presentation that is
            // dismissing races the modal transition — the same rule ``ComposerAttachButton``
            // follows for its picker, and the same one every sheet in this app follows by
            // routing its push through `onDismiss`.
            history.chosen = row.place
            dismiss()
        } label: {
            HStack(spacing: 10) {
                // The sidebar's own mark, so a channel, a private channel, a person and a
                // group are the same four shapes here that they are there. A thread replaces
                // the channel glyph with the thread symbol — the seam the Drafts screen
                // already uses — and is left alone for a direct message, where a face names
                // the people better than a symbol can and the subtitle still says what it is.
                ConversationMark(
                    conversation: row.conversation,
                    size: Self.markSize,
                    glyphTint: .primary,
                    symbol: row.place.isThread ? ThreadView.threadSymbol : nil
                )
                VStack(alignment: .leading, spacing: 0) {
                    Text(row.conversation.title)
                        .font(.hive(.callout))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    if row.place.isThread {
                        Text("Thread")
                            .font(.hive(.caption))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Self.horizontalPadding)
            .padding(.vertical, 8)
            .contentShape(.rect)
        }
        .buttonStyle(.hivePress(.row))
        .accessibilityLabel(
            row.place.isThread ? "\(row.conversation.title), thread" : row.conversation.title
        )
    }

    /// Wide enough for a two-line channel name at this text size, narrow enough to stay a
    /// dropdown hanging off its button rather than one covering the screen.
    static let width: CGFloat = 260
    /// About seven rows. Twelve at full height would reach the bottom of the phone, and a
    /// popover that tall stops reading as attached to the control that opened it.
    static let maxHeight: CGFloat = 380
    private static let horizontalPadding: CGFloat = 16
    /// Smaller than the sidebar's mark, at the owner's word. This list is a shortcut rather
    /// than a place to read: the rows are half the width of the sidebar's and the name is
    /// what identifies them, so a mark at the sidebar's size dominates a row it is only
    /// meant to categorise.
    private static let markSize: CGFloat = 22
}
