import SwiftUI
import UIKit

/// A native hold-for-menu bounded to one card inside a shared list row.
///
/// # Why SwiftUI cannot do this
///
/// The three shortcut cards are one list row — a set of destinations above the conversations
/// rather than three rows of their own. A `.contextMenu` written anywhere inside a list row is
/// installed *on the row*: holding **Later** opened the Threads menu, and the lift took all
/// three cards and dropped them back together. Both measured on the owner's phone, 2026-08-08.
/// It is the same mechanism that lets ``ChannelListView`` write a context menu beside
/// `.swipeActions` and mean the whole row by it — useful there, wrong here.
///
/// Two ways out were tried on device and rejected. A `Menu` is bounded to its label, but it
/// tints that label with the accent and carries no button for ``PressFeedbackButtonStyle`` to
/// attach to, so the card came out amber and stopped dipping. Hosting the card in its own
/// `UIHostingController` bounded the menu and cost the card every touch it had: it drew
/// identically to its neighbours and answered nothing at all.
///
/// # What this does instead
///
/// `UIContextMenuInteraction` is handed **the touch location** and may answer `nil` — "no menu
/// here". SwiftUI's wrapper never exposes that, which is the whole reason a `.contextMenu`
/// cannot be narrowed. So the interaction goes on the view above the card, and the delegate
/// hands back a menu only for a touch inside this card's own rectangle. Later and Drafts get
/// `nil`, so nothing lifts and nothing opens.
///
/// The lift is the row's own drawing clipped to the card's rounded rectangle — a
/// `UIPreviewParameters.visiblePath` — so what rises is this card and nothing either side of
/// it, without rendering the card a second time.
///
/// **Nothing about the card changes.** It keeps its `Button`, its press treatment, its label
/// colour, and its place in the scrolling list. This view draws nothing, takes no touches
/// (`allowsHitTesting(false)` at the call site, like ``ScrollTouchDelivery``) and exists only
/// as a vantage point that knows where the card is.
struct ShortcutCardMenu: UIViewRepresentable {
    /// What the menu offers. Rebuilt on every update so the enabled state stays live.
    let title: String
    let systemImage: String
    /// Offered but inert rather than absent — see ``HomeShortcutCards``.
    let isEnabled: Bool
    let action: () -> Void

    func makeUIView(context: Context) -> VantageView {
        let view = VantageView()
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ uiView: VantageView, context: Context) {
        context.coordinator.title = title
        context.coordinator.systemImage = systemImage
        context.coordinator.isEnabled = isEnabled
        context.coordinator.action = action
        context.coordinator.card = uiView
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(title: title, systemImage: systemImage, isEnabled: isEnabled, action: action)
    }

    /// A view that draws nothing and exists to say where the card is.
    ///
    /// The interaction is installed on its **superview**, not on itself: this view takes no
    /// touches, and a view that takes no touches cannot host an interaction that needs them.
    /// The superview is whatever SwiftUI put the row's content in, which is at least the card
    /// and at most the row — either is correct, because the delegate bounds the menu by
    /// location rather than by whose view it is.
    final class VantageView: UIView {
        weak var coordinator: Coordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil, let host = superview, let coordinator else { return }
            coordinator.card = self
            // Idempotent: SwiftUI can move this view between windows, and a second
            // interaction would offer the menu twice.
            guard !host.interactions.contains(where: { $0 is UIContextMenuInteraction }) else {
                return
            }
            host.addInteraction(UIContextMenuInteraction(delegate: coordinator))
        }
    }

    final class Coordinator: NSObject, UIContextMenuInteractionDelegate {
        var title: String
        var systemImage: String
        var isEnabled: Bool
        var action: () -> Void
        /// The card's own view — what the touch location is measured against.
        weak var card: UIView?

        init(title: String, systemImage: String, isEnabled: Bool, action: @escaping () -> Void) {
            self.title = title
            self.systemImage = systemImage
            self.isEnabled = isEnabled
            self.action = action
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            configurationForMenuAtLocation location: CGPoint
        ) -> UIContextMenuConfiguration? {
            // The whole point: a touch outside this card is not this card's business, and
            // answering `nil` is how a hold on Later stays a hold on nothing.
            guard cardFrame(in: interaction.view) != nil, isInsideCard(location, of: interaction) else {
                return nil
            }
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
                guard let self else { return nil }
                let item = UIAction(
                    title: title,
                    // Not destructive: nothing is removed and nothing is published — a mark
                    // is this device saying it has looked.
                    image: UIImage(systemName: systemImage),
                    attributes: isEnabled ? [] : .disabled
                ) { _ in self.action() }
                return UIMenu(children: [item])
            }
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            previewForHighlightingMenuWithConfiguration configuration: UIContextMenuConfiguration
        ) -> UITargetedPreview? {
            preview(for: interaction)
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            previewForDismissingMenuWithConfiguration configuration: UIContextMenuConfiguration
        ) -> UITargetedPreview? {
            // The same preview on the way out, so the card settles back into itself rather
            // than collapsing into the row it shares.
            preview(for: interaction)
        }

        /// What rises under the menu: the interaction's own drawing, clipped to the card.
        ///
        /// Clipped rather than re-rendered, so the lifted card is the card — the same pixels,
        /// including whatever the press treatment was drawing at the moment of the hold.
        private func preview(for interaction: UIContextMenuInteraction) -> UITargetedPreview? {
            guard let host = interaction.view, let frame = cardFrame(in: host) else { return nil }
            let parameters = UIPreviewParameters()
            parameters.visiblePath = UIBezierPath(
                roundedRect: frame,
                cornerRadius: HomeShortcutCard.cornerRadius
            )
            // Clear, because the card draws its own fill and border; anything here would be a
            // second background inside a card that already has one.
            parameters.backgroundColor = .clear
            return UITargetedPreview(view: host, parameters: parameters)
        }

        private func isInsideCard(_ location: CGPoint, of interaction: UIContextMenuInteraction) -> Bool {
            guard let host = interaction.view, let frame = cardFrame(in: host) else { return false }
            return frame.contains(location)
        }

        /// The card's rectangle in the interaction view's own coordinates.
        private func cardFrame(in host: UIView?) -> CGRect? {
            guard let card, let host, card.window != nil else { return nil }
            return card.convert(card.bounds, to: host)
        }
    }
}
