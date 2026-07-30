import BuzzKit

/// Where pressing a draft goes.
///
/// A value rather than two lines inside ``ChannelListView``'s press handler, because this
/// is the rule the whole screen exists for — a draft has to land in the conversation it
/// belongs to, and a thread draft and its channel are different destinations that a
/// `rootID` of `nil` is the only thing separating. Pure, so the mapping is tested as
/// itself instead of by driving a navigation stack.
enum DraftDestination: Hashable {
    /// The conversation's own composer: a channel, or a direct message.
    case conversation(channelID: String)
    /// A reply composer inside one of its threads.
    case thread(root: String, channelID: String)

    /// Where a thread draft lands: the **newest reply**, a thread's resting position.
    ///
    /// It opened at the opener first, on the reasoning that someone returning to unsent
    /// writing is coming back to what they were answering. Wrong, and the owner corrected
    /// it on device: a draft is the *last* thing that happened in that thread from the
    /// writer's point of view, so arriving anywhere above the newest reply means scrolling
    /// down before you can carry on. The keyboard is coming up over the bottom of the
    /// screen either way, which makes any other anchor doubly wrong.
    static let threadLanding: ThreadLanding = .latestReply

    /// Both arrivals focus the composer. Someone who came here came to finish writing,
    /// which is the same request the actions sheet's "Reply in thread" makes.
    static func of(_ summary: ComposerDraftSummary) -> DraftDestination {
        guard let root = summary.rootID else {
            return .conversation(channelID: summary.channelID)
        }
        return .thread(root: root, channelID: summary.channelID)
    }
}
