import BuzzKit
import SwiftUI
import UIKit

/// The message a long press opened the actions sheet for.
///
/// A wrapper rather than a bare `TimelineRow?` for the reason ``ProfilePeer`` is one:
/// `sheet(item:)` keys the presentation off it, so long-pressing a second message while the
/// first sheet is still animating away re-presents for the new row instead of showing the
/// old one's actions.
struct MessageActionTarget: Identifiable, Equatable {
    let row: TimelineRow
    /// Whether this is the local identity's own send — what gates Retry and Delete.
    let isOwn: Bool

    var id: String { row.id }
}

/// What a message surface can do to one of its rows.
///
/// Both conversation models already had all five, with these signatures, because the row's
/// own closures were wired straight to them. Naming them as a protocol is what lets one
/// sheet serve the channel and the thread without either surface passing five closures
/// through a modifier — and what keeps the sheet's *reads* live: the models are
/// `@Observable`, so a reaction landing while the sheet is open re-draws the palette
/// underneath it.
@MainActor
protocol MessageActing: AnyObject {
    /// The surviving reaction groups on a message, own reaction marked.
    func reactions(for id: String) -> [ReactionGroup]
    /// Send a fresh reaction.
    func react(_ emoji: String, on targetID: String)
    /// Add, or withdraw an own reaction.
    func toggleReaction(_ group: ReactionGroup, on targetID: String)
    /// Re-queue a failed send.
    func retry(_ eventID: String)
    /// Discard an own pending or failed send.
    func delete(_ eventID: String)
}

extension View {
    /// Presents ``MessageActionsSheet`` for whichever message `target` names.
    ///
    /// One modifier rather than a `.sheet` per surface, for the reason ``profileSheet(peer:presence:)``
    /// is one: the channel and a thread open the same sheet from the same gesture, and a
    /// second copy is a second place for the two to drift.
    ///
    /// `onReplyInThread` is absent inside a thread, where there is nowhere further to go —
    /// the same asymmetry as ``TimelineRowView/onOpenThread``, and it is what removes the
    /// row rather than leaving a control that cannot work.
    func messageActionsSheet(
        target: Binding<MessageActionTarget?>,
        actions: any MessageActing,
        onReplyInThread: ((TimelineRow) -> Void)? = nil
    ) -> some View {
        modifier(
            MessageActionsSheetModifier(
                target: target,
                actions: actions,
                onReplyInThread: onReplyInThread
            )
        )
    }
}

/// Presents the sheet, and defers the one action that cannot run while it is on screen.
private struct MessageActionsSheetModifier: ViewModifier {
    @Binding var target: MessageActionTarget?
    let actions: any MessageActing
    let onReplyInThread: ((TimelineRow) -> Void)?

    /// The thread the sheet asked for, held until the sheet has actually gone.
    @State private var pendingThread: TimelineRow?

    func body(content: Content) -> some View {
        content.sheet(item: $target, onDismiss: openPendingThread) { target in
            MessageActionsSheet(
                target: target,
                actions: actions,
                // The sheet only needs to know *whether* the action exists; the row it
                // applies to is the one it was presented for.
                onReplyInThread: onReplyInThread.map { _ in { pendingThread = target.row } }
            )
        }
    }

    /// Pushes the thread the sheet asked for, once the sheet is off the screen.
    ///
    /// Pushing from inside the sheet's own button would start a navigation transition while
    /// a modal dismissal is still running — two presentations animating over each other,
    /// where UIKit drops the second. `sheet(item:onDismiss:)` is the hook that says the
    /// modal has gone, and it fires for a swipe-down as well as for the button, which is why
    /// the request is a stored row rather than a closure fired on the way out.
    private func openPendingThread() {
        guard let row = pendingThread else { return }
        pendingThread = nil
        onReplyInThread?(row)
    }
}

/// The message actions sheet: a row of quick reactions with the full picker at the end of
/// it, then the actions themselves.
///
/// # Why this is a sheet and not a context menu
///
/// It replaces `.contextMenu`, and the reason is what the menu brings with it rather than
/// what it lacks. A context menu lifts a snapshot of the pressed view and presents it over a
/// blurred screen; on a message that snapshot is the row, so a long press flashed a large
/// floating card of the message before showing anything actionable, and iOS's own text
/// interaction rode along with it. The owner asked for the actions *immediately*, with none
/// of that. A sheet has no lift, no snapshot, and no text interaction — and it arrives with
/// the drag indicator and the swipe-down dismissal a menu cannot offer.
///
/// The background is deliberately not set. A sheet's default background is the system's, and
/// on iOS 26 that is the Liquid Glass material — the same reasoning that keeps the composer
/// to one glass surface applies here, so nothing inside draws its own.
private struct MessageActionsSheet: View {
    let target: MessageActionTarget
    let actions: any MessageActing
    /// Absent inside a thread, where the message is already open.
    let onReplyInThread: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    /// Rests at medium, as asked. The picker is the only thing that takes the other one:
    /// several hundred glyphs behind a search field do not fit in half a screen.
    @State private var detent: PresentationDetent = .height(220)
    @State private var isPickingEmoji = false
    @State private var isShowingWorkInProgress = false

    /// The height of a quick-reaction target, and of the emoji picker's button beside it.
    private static let paletteHeight: CGFloat = 48
    /// The height of one action row. Comfortably past the 44pt minimum, which is what makes
    /// a list of three read as a list rather than as a stack of buttons.
    private static let rowHeight: CGFloat = 52

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                palette
                Divider()
                    .padding(.horizontal, 20)
                actionRows
                Spacer(minLength: 0)
            }
            // The root of this stack is the sheet itself and has no title; only the pushed
            // picker wants a bar.
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $isPickingEmoji) {
                EmojiPickerView(onSelect: send)
                    .navigationTitle("Add reaction")
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
        .presentationDetents([.height(220), .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .alert("WIP", isPresented: $isShowingWorkInProgress) {
            Button("OK", role: .cancel) {}
        }
        .onChange(of: isPickingEmoji) { _, isPicking in
            detent = isPicking ? .large : .medium
        }
    }

    // MARK: - Reactions

    /// One row: the five quick reactions, then the picker. Six equal columns rather than a
    /// leading group with the picker pushed right — evenly spaced is what Slack draws, and it
    /// keeps every target the same size as the reader's thumb travels along the row.
    private var palette: some View {
        HStack(spacing: 0) {
            ForEach(ReactionPalette.common, id: \.self, content: quickReaction)
            pickerButton
        }
        .padding(.horizontal, 12)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private func quickReaction(_ emoji: String) -> some View {
        let isMine = ownReaction(emoji)
        return Button {
            send(emoji)
        } label: {
            // See ``EmojiPickerView``'s cell for why an emoji is asked for in Lato.
            Text(emoji)
                .font(.hive(fixedSize: 28, relativeTo: .title2))
                .frame(maxWidth: .infinity)
                .frame(height: Self.paletteHeight)
                .background(
                    isMine ? Color.accentColor.opacity(0.18) : .clear,
                    in: .rect(cornerRadius: 12)
                )
                .contentShape(.rect)
        }
        .buttonStyle(PressFeedbackButtonStyle())
        .accessibilityLabel(EmojiCatalog.unicodeName(of: emoji))
        .accessibilityAddTraits(isMine ? [.isSelected] : [])
    }

    /// The same smiley-and-plus pairing the add-reaction pill under a message carries, so
    /// the two ways into the picker read as the same control.
    private var pickerButton: some View {
        Button {
            isPickingEmoji = true
        } label: {
            HStack(spacing: 1) {
                Image(systemName: "face.smiling")
                Image(systemName: "plus")
                    .font(.hiveSymbol(fixedSize: 9, weight: .bold))
            }
            .font(.hiveSymbol(.title3))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: Self.paletteHeight)
            .contentShape(.rect)
        }
        .buttonStyle(PressFeedbackButtonStyle())
        .accessibilityLabel("More reactions")
    }

    /// Applies a chosen emoji — from the palette or from the picker — and closes the sheet.
    ///
    /// The choice between adding and toggling is ``ReactionPalette/choice(for:in:)``'s, not
    /// this view's: pressing an emoji the reader has already sent has to withdraw it rather
    /// than queue a second identical reaction.
    private func send(_ emoji: String) {
        switch ReactionPalette.choice(for: emoji, in: actions.reactions(for: target.row.id)) {
        case let .add(emoji):
            actions.react(emoji, on: target.row.id)
        case let .toggle(group):
            actions.toggleReaction(group, on: target.row.id)
        }
        dismiss()
    }

    /// Whether the reader has already sent this emoji on this message — what tints the
    /// quick-reaction target, exactly as it tints the chip under the message.
    private func ownReaction(_ emoji: String) -> Bool {
        actions.reactions(for: target.row.id).contains { $0.emoji == emoji && $0.reactedBySelf }
    }

    // MARK: - Actions

    @ViewBuilder
    private var actionRows: some View {
        if let onReplyInThread {
            // The thread's own mark, not a reply arrow: `text.append` is what the thread
            // heading and the Threads tab already use, so the symbol means one thing.
            actionRow("Reply in thread", symbol: ThreadView.threadSymbol) {
                onReplyInThread()
                dismiss()
            }
        }
        actionRow("Copy Message", symbol: "doc.on.doc") {
            UIPasteboard.general.string = target.row.content
            dismiss()
        }
        // Deliberately does not dismiss: the alert is the whole outcome, and closing the
        // sheet out from under it would leave the notice floating over the conversation.
        actionRow("Remind Me", symbol: "clock") {
            isShowingWorkInProgress = true
        }
        ownSendActions
    }

    /// Retry and Delete, on an own message that has not landed. They were in the long-press
    /// menu this sheet replaces and would otherwise have gone with it — a failed send would
    /// then have had only the strip under it to retry from, and no way to be discarded at all.
    @ViewBuilder
    private var ownSendActions: some View {
        if target.isOwn, target.row.delivery != .sent {
            if case .failed = target.row.delivery {
                actionRow("Retry", symbol: "arrow.clockwise") {
                    actions.retry(target.row.id)
                    dismiss()
                }
            }
            actionRow("Delete", symbol: "trash", role: .destructive) {
                actions.delete(target.row.id)
                dismiss()
            }
        }
    }

    private func actionRow(
        _ title: String,
        symbol: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            HStack(spacing: 16) {
                Image(systemName: symbol)
                    .font(.hiveSymbol(.body))
                    // A fixed gutter so the labels start on one line whatever width each
                    // glyph happens to draw at.
                    .frame(width: 24)
                Text(title)
                    .font(.hive(.body))
                Spacer(minLength: 0)
            }
            .foregroundStyle(role == .destructive ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
            .padding(.horizontal, 20)
            .frame(minHeight: Self.rowHeight)
            .contentShape(.rect)
        }
        .buttonStyle(MessageActionRowStyle())
    }
}

/// A full-width row that lights on press. A fill rather than the dim
/// ``PressFeedbackButtonStyle`` gives the small controls on a message: this is a list row,
/// and a row's feedback is the row highlighting.
private struct MessageActionRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.secondary.opacity(configuration.isPressed ? 0.16 : 0))
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
