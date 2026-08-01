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
    /// What this reader may do to `row` — see ``BuzzKit/MessageAuthority``.
    ///
    /// Asked of the model rather than computed in the sheet because it is a database
    /// question (who owns which agent, who administers this channel), and because the
    /// channel and a thread must answer it identically.
    func authority(for row: TimelineRow) -> MessageAuthority
    /// Remove a message everybody can see — a `kind:9005` deletion, not the outbox
    /// discard ``delete(_:)`` performs.
    func removeFromChannel(_ eventID: String)
    /// Rewrite a message's text in place — a `kind:40003` edit.
    func editMessage(_ eventID: String, to text: String)
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
        isReadOnly: Bool = false,
        onReplyInThread: ((TimelineRow) -> Void)? = nil
    ) -> some View {
        modifier(
            MessageActionsSheetModifier(
                target: target,
                actions: actions,
                isReadOnly: isReadOnly,
                onReplyInThread: onReplyInThread
            )
        )
    }
}

/// Presents the sheet, and defers the one action that cannot run while it is on screen.
private struct MessageActionsSheetModifier: ViewModifier {
    @Binding var target: MessageActionTarget?
    let actions: any MessageActing
    let isReadOnly: Bool
    let onReplyInThread: ((TimelineRow) -> Void)?

    /// The thread the sheet asked for, held until the sheet has actually gone.
    @State private var pendingThread: TimelineRow?

    func body(content: Content) -> some View {
        content.sheet(item: $target, onDismiss: openPendingThread) { target in
            MessageActionsSheet(
                target: target,
                actions: actions,
                isReadOnly: isReadOnly,
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
