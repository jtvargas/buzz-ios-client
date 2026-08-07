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
    /// Open this markdown file in the app's own reader.
    ///
    /// Ahead of ``external(_:)`` and nothing else changes about the link: it is still an
    /// ordinary `https` URL in the text, still autolinked, still carded. What differs is only
    /// where the press goes — into a sheet that renders it, rather than out to a browser that
    /// shows its source. A surface with nowhere to present a sheet falls back to the browser,
    /// which is what pressing it always did.
    case markdownDocument(MarkdownDocument)
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
        // An internal message link navigates to the conversation it names. It does not
        // scroll to the message itself: nothing in the app can select a message by id
        // yet, and pushing the channel is the honest subset rather than a link that
        // looks like it will land somewhere it cannot.
        case let .message(channel, _, _):
            self = .conversation(channelID: channel)
        // A web link that names a markdown file is the one `.web` that does not leave the app.
        // Decided here rather than at each surface so the sheet opens from a channel, a thread
        // and a DM by one rule — and decided *after* the internal schemes above, so nothing
        // that is already an entity can be re-read as a file.
        case let .web(url):
            self = MarkdownDocument(url: url).map(RichTextRoute.markdownDocument) ?? .external(url)
        case let .mail(url):
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

/// Opens a markdown file in the app's reader, from anywhere below the sheet that presents it.
///
/// An environment action for the reason ``OpenConversationAction`` is one: the press happens
/// inside a message row, and a sheet cannot be presented from there — a sheet attached to a row
/// dies with the row when the list recycles it, and one attached to the conversation would have
/// to be repeated on every surface that draws a message. Installed once, above the tabs.
///
/// A surface without one hands the URL to the browser instead of doing nothing, which is the
/// difference between this and `openConversation`: a channel pill with no navigator has nowhere
/// sensible to go, and a file always has.
struct OpenMarkdownDocumentAction {
    private let handler: (MarkdownDocument) -> Void

    init(_ handler: @escaping (MarkdownDocument) -> Void) {
        self.handler = handler
    }

    func callAsFunction(_ document: MarkdownDocument) {
        handler(document)
    }
}

extension EnvironmentValues {
    /// Injected beside the navigation stack that owns the path. `nil` by default.
    @Entry var openConversation: OpenConversationAction?
    /// Injected above the tabs, so one sheet serves every surface that draws a message.
    /// `nil` outside the app's root, where a pressed file opens in the browser instead.
    @Entry var openMarkdownDocument: OpenMarkdownDocumentAction?
    /// Injected by a row that arbitrates its own tap. `nil` on a surface that does not.
    @Entry var claimRowTap: ClaimRowTapAction?
    /// Injected by a row that resolves single taps against double ones. `nil` on a surface
    /// with no message row behind the content, where a tap is answered immediately.
    @Entry var messageTap: MessageTapAction?
}
