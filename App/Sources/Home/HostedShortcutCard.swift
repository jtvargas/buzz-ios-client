import SwiftUI
import UIKit

/// A shortcut card lifted out of the list row it is drawn in, so that a `.contextMenu` written
/// inside it means *this card* and not the row.
///
/// # Why a card needs this at all
///
/// The three shortcut cards share **one** list row — they are a set of destinations above the
/// conversations, not three rows of their own, and ``HomeShortcutCards`` says why. A
/// `.contextMenu` written anywhere inside a list row is installed on the row: the hold is then
/// answered anywhere along it, and the lift takes the whole row with it. The owner measured
/// exactly that on his phone (2026-08-08) — holding **Later** opened the Threads menu, and
/// releasing it collapsed all three cards back together.
///
/// It is the same mechanism that lets ``ChannelListView`` write a context menu beside
/// `.swipeActions` and mean the whole row by it. Useful there, wrong here.
///
/// # Why hosting rather than replacing
///
/// The obvious alternatives both cost more than they look. A `Menu` is bounded to its label,
/// but it tints that label with the accent — the card came out amber beside two white ones —
/// and it carries no button, so ``PressFeedbackButtonStyle`` had nothing to attach to and the
/// card stopped dipping under a finger. Hand-rolling the hold in UIKit means re-supplying
/// everything the button was giving for free: the wash, the shrink, the cancel when a scroll
/// takes the touch, the delayed-touch fix, the accessibility traits.
///
/// So nothing is replaced. The card, its button, and its press treatment are exactly what they
/// are in the other two slots; only the *context* changes. A `UIHostingController` is its own
/// hosting view, so a context menu declared inside it attaches there — to a view with this
/// card's frame — instead of climbing out to the cell.
///
/// # What crosses the boundary, and what does not
///
/// Traits do: Dynamic Type, Reduce Motion and the window tint all reach the hosted card,
/// because a hosting controller inherits its parent's trait collection. SwiftUI `@Environment`
/// values written above this point do **not**, which is why the content this wraps reads
/// nothing but its own arguments. Anything that later needs a custom environment value has to
/// be handed it as a parameter instead.
struct HostedShortcutCard<Content: View>: UIViewControllerRepresentable {
    /// The card, its button, and the menu it offers — built fresh each update so the count and
    /// the enabled state stay live.
    @ViewBuilder var content: () -> Content

    func makeUIViewController(context: Context) -> UIHostingController<Content> {
        let host = UIHostingController(rootView: content())
        // The card draws its own fill and border; anything behind it here would be a second
        // background inside a card that already has one, and would square off its corners.
        host.view.backgroundColor = .clear
        // The hosting view takes the slot the row gives it and the card fills that slot, so
        // the controller must not also try to size itself from its content.
        host.sizingOptions = []
        return host
    }

    func updateUIViewController(_ host: UIHostingController<Content>, context: Context) {
        host.rootView = content()
    }
}
