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

extension EnvironmentValues {
    /// Injected beside the navigation stack that owns the path. `nil` by default.
    @Entry var openConversation: OpenConversationAction?
}
