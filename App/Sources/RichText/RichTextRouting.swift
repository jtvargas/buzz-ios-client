import SwiftUI

/// What a surface should do with a pressed link.
///
/// The decision is a value, and the pure function that produces it is what the tests
/// exercise — an `OpenURLAction` closure is not something a unit test can press.
enum RichTextRoute: Equatable {
    /// Show this identity's profile sheet. People and agents alike: the sheet already
    /// says which one it is showing, and a second sheet would be a second thing to
    /// keep in step for one line of difference.
    case profile(pubkey: String)
    /// Navigate to this conversation.
    case conversation(channelID: String)
    /// Land on a message in this conversation. Stage 1 lands in an already-loaded channel;
    /// later routing stages use the retained root id to choose a thread destination.
    case message(channelID: String, eventID: String, threadRootID: String?)
    /// Hand back to the system's own link handling (Safari, Mail).
    case external(URL)

    /// The route a pressed URL describes, or `nil` when it is not one this app
    /// recognises — in which case the surface passes it to `openURL` untouched
    /// rather than swallowing it.
    init?(url: URL) {
        switch RichTextTarget(url: url) {
        case let .user(pubkey):
            self = .profile(pubkey: pubkey)
        case let .channel(id):
            self = .conversation(channelID: id)
        case let .message(channel, event, thread):
            self = .message(channelID: channel, eventID: event, threadRootID: thread)
        case let .web(url), let .mail(url):
            self = .external(url)
        case nil:
            return nil
        }
    }
}

/// Navigates to a conversation by id, from anywhere below the navigation stack.
///
/// An environment action rather than a closure threaded through the row, for the same
/// reason ``DirectMessageRouter`` is one: the tap happens inside a pushed timeline,
/// and the push belongs to the stack at the root. A surface without one simply does
/// not act on a `#`-channel press — the pill is still tinted, because it is still a
/// resolved reference, but nothing moves.
struct OpenConversationAction {
    private let handler: (String) -> Void

    init(_ handler: @escaping (String) -> Void) {
        self.handler = handler
    }

    func callAsFunction(_ channelID: String) {
        handler(channelID)
    }
}

/// Tells the surrounding row that a control inside the message body has just handled a
/// tap, so the row's own deferred tap does not also fire.
///
/// # Why this exists when links already arbitrate
///
/// Every *interactive range of text* — mention, channel, link, email — is a `link` run,
/// so all of them travel through the row's `OpenURLAction`, which claims the tap on the
/// way past (see ``TimelineRowView``). An attachment is not a link run and never reaches
/// that action: it is a view, it presents its own viewer, and it has nothing to hand to
/// `openURL`. Without a claim of its own, tapping a picture would open the viewer *and*
/// push the thread behind it — the same defect the reaction chips have `onOpenPalette`
/// to avoid.
///
/// An environment action rather than another parameter on ``RichTextView`` because the
/// renderer is shared: the sidebar snippet and the Threads summary draw the same message
/// on surfaces with no row tap to suppress, and they should inject nothing rather than
/// pass a closure that does nothing.
struct ClaimRowTapAction {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    func callAsFunction() {
        handler()
    }
}

/// Hands a picture's own tap to the message row, which decides whether it was a single tap —
/// open the picture — or the first half of a double tap, which opens a sheet instead.
///
/// # Why the picture cannot decide this itself
///
/// A double tap is resolved by *waiting*, and what has to be waited for is the second tap on
/// **the message**, wherever it lands: the first on the picture and the second an inch below
/// it on the text is the same gesture to the reader. Only the row sees both. So an attachment
/// does not open itself and then hope; it hands over what it would have done, and the row
/// runs it once no second tap has come. See ``MessageTapArbiter``.
///
/// *What* a second tap then means is the caller's, not the row's: two taps on the message's
/// text open the message's actions, and two on a picture inside it open the picture's own —
/// see ``MediaActionsSheet`` for why those are different sheets. The last tap decides, which
/// is the only rule that can be stated at all for a pair that landed on two different things.
///
/// Beside ``ClaimRowTapAction`` because they are two halves of one arrangement — the claim
/// stops the row *also* acting on a tap a control handled, and this decides *when* that
/// control's own action runs — and injected by the same row, through the same renderer.
struct MessageTapAction {
    private let handler: (@escaping () -> Void, (() -> Void)?) -> Void
    private let doubleHandler: (@escaping () -> Void) -> Void

    init(
        single handler: @escaping (@escaping () -> Void, (() -> Void)?) -> Void,
        double doubleHandler: @escaping (@escaping () -> Void) -> Void
    ) {
        self.handler = handler
        self.doubleHandler = doubleHandler
    }

    func callAsFunction(single: @escaping () -> Void, double: (() -> Void)?) {
        handler(single, double)
    }

    /// Reports a double tap the system recognised as one, which is the only way it can be
    /// reported by a `Button` — see ``MessageTapArbiter/doubleTapped(_:)`` for why a control
    /// cannot simply be tapped twice.
    func reportDouble(_ double: @escaping () -> Void) {
        doubleHandler(double)
    }
}

extension Optional where Wrapped == MessageTapAction {
    /// Runs `single` through the row's arbitration when there is a row arbitrating, and at
    /// once when there is not.
    ///
    /// The `nil` case is not a degradation to be avoided — it is every surface that draws a
    /// message without a row behind it, and a tap there must not be made to wait for a
    /// gesture nothing is listening for.
    func run(single: @escaping () -> Void, double: (() -> Void)?) {
        guard let tap = self else {
            single()
            return
        }
        tap(single: single, double: double)
    }

    /// Reports a system-recognised double tap to the row, and does nothing where no row is
    /// arbitrating — there, the single tap already ran.
    func reportDouble(_ double: @escaping () -> Void) {
        self?.reportDouble(double)
    }
}

extension EnvironmentValues {
    /// Injected beside the navigation stack that owns the path. `nil` by default.
    @Entry var openConversation: OpenConversationAction?
    /// Injected by a row that arbitrates its own tap. `nil` on a surface that does not.
    @Entry var claimRowTap: ClaimRowTapAction?
    /// Injected by a row that resolves single taps against double ones. `nil` on a surface
    /// with no message row behind the content, where a tap is answered immediately.
    @Entry var messageTap: MessageTapAction?
}
