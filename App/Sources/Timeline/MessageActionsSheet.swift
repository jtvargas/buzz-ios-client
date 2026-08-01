import BuzzKit
import SwiftUI
import UIKit

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
struct MessageActionsSheet: View {
    let target: MessageActionTarget
    let actions: any MessageActing
    let isReadOnly: Bool
    /// Absent inside a thread, where the message is already open.
    let onReplyInThread: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    /// Rests at medium, as asked. The picker is the only thing that takes the other one:
    /// several hundred glyphs behind a search field do not fit in half a screen.
    @State private var detent: PresentationDetent = .height(260)
    @State private var isPickingEmoji = false
    @State private var isShowingWorkInProgress = false
    @State private var isConfirmingDelete = false
    /// Pushed on this sheet's own stack, the way the picker is — never a second sheet: a
    /// modal presented from inside a modal races the first one's dismissal.
    @State private var isEditing = false
    @State private var draft = ""

    /// The height of a quick-reaction target, and of the emoji picker's button beside it.
    private static let paletteHeight: CGFloat = 48
    /// The height of one action row. Comfortably past the 44pt minimum, which is what makes
    /// a list of three read as a list rather than as a stack of buttons.
    private static let rowHeight: CGFloat = 52

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !isReadOnly {
                    palette
                    Divider()
                        .padding(.horizontal, 20)
                }
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
            .navigationDestination(isPresented: $isEditing) { editor }
        }
        .presentationDetents([.height(260), .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .alert("WIP", isPresented: $isShowingWorkInProgress) {
            Button("OK", role: .cancel) {}
        }
        // Destructive for everybody in the channel, so it asks.
        .alert("Delete message?", isPresented: $isConfirmingDelete) {
            Button("Delete", role: .destructive) {
                HiveHaptics.play(.delete)
                actions.removeFromChannel(target.row.id)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes it for everyone in the channel.")
        }
        .onChange(of: isPickingEmoji) { _, isPicking in
            detent = isPicking ? .large : .medium
        }
        .onChange(of: isEditing) { _, editing in
            detent = editing ? .large : .medium
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
            // At the target rather than inside ``send(_:)``: the picker's cells reach that
            // same applier and play their own, so a play there would arrive twice for one
            // emoji chosen from the picker.
            HiveHaptics.play(.reaction)
            send(emoji)
        } label: {
            // See ``EmojiPickerView``'s cell for why an emoji is asked for in Inter.
            Text(emoji)
                .font(.hive(fixedSize: 28, relativeTo: .title2))
                .frame(maxWidth: .infinity)
                .frame(height: Self.paletteHeight)
                .background(
                    isMine ? Color.hiveAccent.opacity(0.18) : .clear,
                    in: .rect(cornerRadius: 12)
                )
                .contentShape(.rect)
        }
        // In the target's own corner rather than the vocabulary's default: the own-reaction
        // tint above is drawn at 12, and a wash a couple of points off it would show at the
        // corners of precisely the reactions a reader presses again.
        .buttonStyle(.hivePress(.control, in: .rect(cornerRadius: 12)))
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
        .buttonStyle(.hivePress)
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
        if let onReplyInThread, !isReadOnly {
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
        publishedMessageActions
        ownSendActions
    }

    /// Edit and Delete on a message that has *landed*.
    ///
    /// Gated by ``BuzzKit/MessageAuthority``, which answers the two separately because the
    /// relay does: an admin may take a message down but may not rewrite it. These never
    /// appear beside ``ownSendActions``' "Delete", which requires a row that has *not*
    /// landed.
    @ViewBuilder
    private var publishedMessageActions: some View {
        if !isReadOnly {
            let authority = actions.authority(for: target.row)
            if authority.canEdit {
                actionRow("Edit Message", symbol: "pencil") {
                    draft = target.row.content
                    isEditing = true
                }
            }
            if authority.canDelete {
                actionRow("Delete Message", symbol: "trash", role: .destructive) {
                    isConfirmingDelete = true
                }
            }
        }
    }

    /// The edit field, pushed rather than presented. Seeded from the message's current
    /// text, which is what makes this an *edit* rather than a re-send.
    private var editor: some View {
        VStack(spacing: 0) {
            TextEditor(text: $draft)
                .font(.hive(.body))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 16)
                .padding(.top, 12)
            Spacer(minLength: 0)
        }
        .navigationTitle("Edit message")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    actions.editMessage(target.row.id, to: draft)
                    dismiss()
                }
                // An empty edit is a deletion wearing a disguise, and unchanged text still
                // stamps the message as edited for everybody. Both refused.
                .disabled(!isSaveable)
            }
        }
    }

    /// Whether the draft is worth publishing: non-empty once trimmed, and actually
    /// different from what is already there.
    private var isSaveable: Bool {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != target.row.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Retry and Delete, on an own message that has not landed. They were in the long-press
    /// menu this sheet replaces and would otherwise have gone with it — a failed send would
    /// then have had only the strip under it to retry from, and no way to be discarded at all.
    @ViewBuilder
    private var ownSendActions: some View {
        if target.isOwn, target.row.delivery != .sent, !isReadOnly {
            if case .failed = target.row.delivery,
               target.row.failureIsRetryable {
                actionRow("Retry", symbol: "arrow.clockwise") {
                    actions.retry(target.row.id)
                    dismiss()
                }
            }
            actionRow("Delete", symbol: "trash", role: .destructive) {
                HiveHaptics.play(.delete)
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
        // A row rather than the emphasis the small controls above take: this is a list row,
        // and a row's feedback is the row lighting up. One that shrank as well would pull
        // away from both screen edges and read as a card lifting off the list.
        .buttonStyle(.hivePress(.row))
    }
}
