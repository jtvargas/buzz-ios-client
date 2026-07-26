@testable import Hive
import Testing
import UIKit

/// The band that the keyboard's dismissal gesture treats as its own.
///
/// Deliberately not here: whether widening it actually makes the keyboard follow a drag
/// through the composer. That is UIKit's behaviour, not the app's, and it is undocumented
/// for a SwiftUI `ScrollView` — so it was measured with a real finger against the shipping
/// ``ConversationScaffold`` in `~/.buzz/.scratch/kbdragharness`: the same drag moved the
/// keyboard across 0 frames without this and 17 with it. What a unit test can hold is the
/// part the app owns — that the band is the bar's height while a conversation is on
/// screen, tracks the bar as it grows, and is given back on the way out.
@MainActor
@Suite("Conversation keyboard dismiss padding", .timeLimit(.minutes(1)))
struct ConversationKeyboardDismissPaddingTests {
    /// A window with a root view controller, which is where the applier looks: a layout
    /// guide is clamped to its owning view's bounds, so it has to be asked of a view that
    /// spans the window.
    private func makeHost() -> (UIWindow, UIView) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let controller = UIViewController()
        window.rootViewController = controller
        window.isHidden = false
        return (window, controller.view)
    }

    @Test("the bar's height becomes the gesture's band, and is given back on the way out")
    func appliesWhileOnScreen() {
        let (window, host) = makeHost()
        defer { window.isHidden = true }
        #expect(host.keyboardLayoutGuide.keyboardDismissPadding == 0)

        let applier = ConversationKeyboardDismissPadding.Applier()
        applier.points = 112
        // Nothing is applied before there is a window — the host cannot be reached, and a
        // silent no-op here is why the value is applied again from `didMoveToWindow`.
        #expect(host.keyboardLayoutGuide.keyboardDismissPadding == 0)

        host.addSubview(applier)
        #expect(host.keyboardLayoutGuide.keyboardDismissPadding == 112)

        applier.removeFromSuperview()
        #expect(host.keyboardLayoutGuide.keyboardDismissPadding == 0)
    }

    /// A push puts a thread's applier in the hierarchy beside the channel's, and the order
    /// of "the new one arrives" and "the old one leaves" is UIKit's. Both orders have to
    /// end with the thread's band in force — and the pop has to give the channel its own
    /// back, which is what the value would otherwise be stuck at zero for.
    @Test("a pushed surface takes the band over, and a pop hands it back")
    func survivesAPushAndPop() {
        let (window, host) = makeHost()
        defer { window.isHidden = true }
        let channel = ConversationKeyboardDismissPadding.Applier()
        channel.points = 112
        host.addSubview(channel)
        #expect(host.keyboardLayoutGuide.keyboardDismissPadding == 112)

        // Push: the thread arrives first, the channel's view leaves the window after.
        let thread = ConversationKeyboardDismissPadding.Applier()
        // Deliberately the same height — the common case, and the one a value comparison
        // would get wrong.
        thread.points = 112
        host.addSubview(thread)
        channel.removeFromSuperview()
        #expect(host.keyboardLayoutGuide.keyboardDismissPadding == 112)

        // A taller composer on the thread must still reach the guide from there.
        thread.points = 156
        #expect(host.keyboardLayoutGuide.keyboardDismissPadding == 156)

        // Pop: the channel comes back and the thread goes.
        host.addSubview(channel)
        thread.removeFromSuperview()
        #expect(host.keyboardLayoutGuide.keyboardDismissPadding == 112)

        channel.removeFromSuperview()
        #expect(host.keyboardLayoutGuide.keyboardDismissPadding == 0)
    }

    @Test("a bar that grows takes the band with it")
    func tracksBarHeight() {
        let (window, host) = makeHost()
        defer { window.isHidden = true }
        let applier = ConversationKeyboardDismissPadding.Applier()
        applier.points = 112
        host.addSubview(applier)

        // The typing strip appears, or the composer grows a line.
        applier.points = 156
        #expect(host.keyboardLayoutGuide.keyboardDismissPadding == 156)

        applier.removeFromSuperview()
        #expect(host.keyboardLayoutGuide.keyboardDismissPadding == 0)
    }
}
