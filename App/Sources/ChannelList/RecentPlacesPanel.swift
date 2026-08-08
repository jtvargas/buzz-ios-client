import SwiftUI

/// The history: the last places this reader was, newest first, each one a way back.
///
/// # Why this is not a `.popover`
///
/// It was one, and it crashed the app — four reports off the owner's phone, every one of
/// them `UIKitPopoverBridge.dismissAndReset` running `dismissViewControllerAnimated:` from
/// inside SwiftUI's render pass, either trapping in UIKit's transition machinery or leaving
/// the navigation path to underflow beneath it.
///
/// The cause is structural, not a detail that could be tuned. A `.popover`'s content rides
/// to UIKit as a **preference**: whenever it changes, SwiftUI dismisses the presentation and
/// re-presents it. This one hangs off a toolbar item inside ``ChannelListView``, whose body
/// re-runs on an arriving message, a heartbeat, a presence tick, a picture landing — so the
/// preference changed constantly, and every one of those was a UIKit dismissal scheduled
/// into whatever else was running. Freezing the *list* it drew did not help, because the
/// resolver and the engine state beside it kept changing anyway. It also explains the second
/// symptom the owner reported: a history that closed itself at random was SwiftUI's own
/// dismiss-and-re-present cycle, seen from the outside.
///
/// So there is no presentation here at all. This is a view in the sidebar's own tree, drawn
/// over it, and a rebuild costs a redraw rather than a modal transition. Nothing in it can
/// race a navigation, because navigating is the same kind of state change as opening it.
///
/// # It resolves nothing
///
/// Every row's name and mark come from the shared ``EntityNames``, live, at the moment the
/// panel opens. Only ids are stored (see ``RecentPlace``), so a channel renamed since the
/// visit is listed under its new name, and a peer whose picture has landed since is drawn
/// with it. Storing the strings would have made this the one surface in the app that can
/// disagree with the sidebar about what something is called.
struct RecentPlacesPanel: View {
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
        // of three is a panel the size of three rows rather than a tall box with a gap
        // under it.
        .frame(maxHeight: Self.maxHeight)
        .glassEffect(.regular, in: .rect(cornerRadius: Self.cornerRadius))
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
    /// panel hanging off its button rather than one covering the screen.
    static let width: CGFloat = 260
    /// About seven rows. Twelve at full height would reach the bottom of the phone, and a
    /// panel that tall stops reading as attached to the control that opened it.
    static let maxHeight: CGFloat = 380
    private static let horizontalPadding: CGFloat = 16
    private static let cornerRadius: CGFloat = 22
    /// Smaller than the sidebar's mark, at the owner's word. This list is a shortcut rather
    /// than a place to read: the rows are half the width of the sidebar's and the name is
    /// what identifies them, so a mark at the sidebar's size dominates a row it is only
    /// meant to categorise.
    private static let markSize: CGFloat = 22
}

extension View {
    /// Hangs ``RecentPlacesPanel`` off the trailing edge of this screen, under the toolbar.
    ///
    /// Applied to the sidebar's container rather than to the toolbar button, so the panel is
    /// a sibling of the list instead of a presentation over it — see the type's own note for
    /// what that bought. `places` is a question rather than an answer for the same reason
    /// nothing else here is resolved early: it is asked once, when the panel opens.
    func recentPlacesOverlay(
        isPresented: Binding<Bool>,
        places: @escaping () -> [RecentPlace],
        names: EntityNames,
        open: @escaping (RecentPlace) -> Void
    ) -> some View {
        modifier(RecentPlacesOverlay(isPresented: isPresented, places: places, names: names, open: open))
    }
}

/// The panel, the scrim that dismisses it, and the one snapshot it draws.
private struct RecentPlacesOverlay: ViewModifier {
    @Binding var isPresented: Bool
    let places: () -> [RecentPlace]
    let names: EntityNames
    let open: (RecentPlace) -> Void

    /// The list on screen — and, being an optional, whether there *is* one.
    ///
    /// Presentation is driven from this rather than from ``isPresented`` directly so the
    /// rows can only ever be the ones read at the moment the panel opened. A history that
    /// reshuffled under the finger — which it does, because arriving somewhere is what
    /// writes to it — would be wrong even though it is now merely wrong rather than fatal.
    @State private var shown: [RecentPlace]?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topTrailing) {
                if let shown {
                    // Declared before the panel so it is beneath it, and transparent rather
                    // than dimmed: this is a twelve-row shortcut, not a mode, and darkening
                    // the sidebar would say the app had gone somewhere.
                    Color.clear
                        .contentShape(.rect)
                        .onTapGesture { isPresented = false }
                        .accessibilityLabel("Close history")
                        .accessibilityAction { isPresented = false }
                    RecentPlacesPanel(places: shown, names: names) { place in
                        isPresented = false
                        open(place)
                    }
                    .padding(.trailing, Self.inset)
                    .padding(.top, Self.inset)
                    // Grows out of the control that opened it, which is the corner it is
                    // pinned to.
                    .transition(.scale(scale: 0.9, anchor: .topTrailing).combined(with: .opacity))
                }
            }
            .onChange(of: isPresented) { _, presented in
                withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                    shown = presented ? places() : nil
                }
            }
    }

    /// Clear of the screen's edge by the same amount the toolbar's controls are.
    private static let inset: CGFloat = 12
}
