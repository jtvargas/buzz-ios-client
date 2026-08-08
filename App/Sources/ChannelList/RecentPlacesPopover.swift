import SwiftUI

/// The history: the last places this reader was, newest first, each one a way back.
///
/// # Why a popover and not a menu
///
/// A `Menu` can only draw a label and a symbol, and half of these rows are people — a
/// direct message is recognised by a face, and a group by how many people are in it. The
/// owner's reference shows exactly that, so the rows have to be real views. What the
/// popover buys with them is its own chrome: it points at the control that opened it, so
/// nothing on screen has to explain where the list came from.
///
/// # It resolves nothing
///
/// Every row's name and mark come from the shared ``EntityNames``, live, at the moment the
/// popover opens. Only ids are stored (see ``RecentPlace``), so a channel renamed since the
/// visit is listed under its new name, and a peer whose picture has landed since is drawn
/// with it. Storing the strings would have made this the one surface in the app that can
/// disagree with the sidebar about what something is called.
struct RecentPlacesPopover: View {
    let places: [RecentPlace]
    let names: EntityNames
    let open: (RecentPlace) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("History")
                .font(.hive(.subheadline, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, Self.horizontalPadding)
                .padding(.top, 14)
                .padding(.bottom, 6)
                .accessibilityAddTraits(.isHeader)
            if places.isEmpty {
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
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(places) { place in
                    row(place)
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

    private func row(_ place: RecentPlace) -> some View {
        let conversation = names.conversation(for: place.channelID)
        return Button {
            open(place)
        } label: {
            HStack(spacing: 10) {
                // The sidebar's own mark, so a channel, a private channel, a person and a
                // group are the same four shapes here that they are there. A thread replaces
                // the channel glyph with the thread symbol — the seam the Drafts screen
                // already uses — and is left alone for a direct message, where a face names
                // the people better than a symbol can and the subtitle still says what it is.
                ConversationMark(
                    conversation: conversation,
                    size: Self.markSize,
                    glyphTint: .primary,
                    symbol: place.isThread ? ThreadView.threadSymbol : nil
                )
                VStack(alignment: .leading, spacing: 0) {
                    Text(conversation.title)
                        .font(.hive(.callout))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    if place.isThread {
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
        .accessibilityLabel(place.isThread ? "\(conversation.title), thread" : conversation.title)
    }

    /// Wide enough for a two-line channel name at this text size, narrow enough to stay a
    /// popover pointing at its button rather than a panel covering the screen.
    private static let width: CGFloat = 260
    /// About seven rows. Twelve at full height would reach the bottom of the phone, and a
    /// popover that tall stops reading as attached to the control that opened it.
    private static let maxHeight: CGFloat = 380
    private static let horizontalPadding: CGFloat = 16
    /// Smaller than the sidebar's mark, at the owner's word. This list is a shortcut rather
    /// than a place to read: the rows are half the width of the sidebar's and the name is
    /// what identifies them, so a mark at the sidebar's size dominates a row it is only
    /// meant to categorise.
    private static let markSize: CGFloat = 22
}
