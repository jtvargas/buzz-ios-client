import QuickLook
import SwiftUI

/// Presents iOS's native file preview, *modally*, and clears `url` when it closes.
///
/// # Why this presents rather than embeds
///
/// `QLPreviewController` draws its own chrome — the close button, the search field and
/// the share action — only when it is **presented**. Handed to SwiftUI as the content of
/// a `.sheet`, it is installed as a *child* view controller instead: it has no presenting
/// controller, decides it is not modal, and renders the document with no controls at all.
/// The document looked right, which is what made it read as a styling gap rather than as
/// the wrong presentation.
///
/// So this view draws nothing. It contributes a host controller to the hierarchy and, when
/// `url` becomes non-`nil`, asks that host to present the preview the way UIKit expects.
/// The reference client reaches the same chrome the same way — its file open hands the URL
/// to the system, which presents Quick Look modally.
///
/// # Why the binding is cleared from the delegate
///
/// Quick Look owns its own dismissal: the close button is its, not ours. `url` is therefore
/// cleared when the controller reports that it went away, rather than by anything here
/// driving the dismissal — otherwise the state stays set after a close and the file cannot
/// be opened a second time.
struct FileQuickLookPresenter: UIViewControllerRepresentable {
    @Binding var url: URL?

    func makeCoordinator() -> Coordinator {
        Coordinator(clear: { url = nil })
    }

    func makeUIViewController(context _: Context) -> UIViewController {
        let host = UIViewController()
        host.view.isUserInteractionEnabled = false
        host.view.backgroundColor = .clear
        return host
    }

    func updateUIViewController(_ host: UIViewController, context: Context) {
        context.coordinator.clear = { url = nil }

        guard let url else {
            context.coordinator.presented = nil
            return
        }
        // Presenting twice for one URL would stack two previews on one tap. The coordinator
        // remembers what is already up rather than asking the host, because `present` is
        // animated and `presentedViewController` is not set for the length of that animation.
        guard context.coordinator.presented != url, host.presentedViewController == nil else {
            return
        }
        context.coordinator.presented = url
        context.coordinator.url = url

        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        controller.delegate = context.coordinator
        host.present(controller, animated: true)
    }

    /// `@MainActor` because it holds a closure that clears a SwiftUI binding, and
    /// `@preconcurrency` on the conformances because Quick Look's protocols come from
    /// Objective-C carrying no isolation of their own. Both callbacks arrive on the main
    /// thread — the sibling coordinators in this app need neither annotation only because
    /// they capture nothing that is actor-isolated.
    @MainActor
    final class Coordinator: NSObject, @preconcurrency QLPreviewControllerDataSource,
        @preconcurrency QLPreviewControllerDelegate {
        var url: URL?
        /// What is on screen, so a re-render during the present animation cannot stack a second.
        var presented: URL?
        var clear: () -> Void

        init(clear: @escaping () -> Void) {
            self.clear = clear
        }

        func numberOfPreviewItems(in _: QLPreviewController) -> Int {
            url == nil ? 0 : 1
        }

        func previewController(_: QLPreviewController, previewItemAt _: Int) -> any QLPreviewItem {
            (url ?? URL(fileURLWithPath: "/")) as NSURL
        }

        func previewControllerDidDismiss(_: QLPreviewController) {
            presented = nil
            clear()
        }
    }
}
