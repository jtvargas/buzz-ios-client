import BuzzKit

/// The conversation a leftward drag on the sidebar reopens: the one you were last reading.
///
/// # One slot, not a history
///
/// A browser's forward button walks a list; this is the last thing you closed, and nothing
/// else. The owner asked for "the last conversation/channel I opened", and a single slot is
/// what makes the gesture explainable without any UI to explain it — the highlighted row
/// *is* the whole state, so what a drag will do is on screen before it is made. A stack
/// would need somewhere to show its depth, and a second drag would land somewhere the reader
/// was given no way to predict.
///
/// # Why it is filled on the way *out*
///
/// The slot is set when the navigation path empties, not when a conversation is opened, and
/// those are genuinely different rules. Opening writes down where you are *going*, which is
/// already on screen; leaving writes down where you *were*, which is the thing the sidebar
/// can no longer show you. It also makes the highlight honest for free: a row is marked
/// exactly when backing out of it is what put you here.
///
/// Threads never enter it, which needs no code: ``ChannelListView`` keeps them in
/// `openedThread` and `showsThreads`, and this only ever reads the conversation path.
///
/// # Session-only, deliberately
///
/// Not persisted. A relaunch is a new session with nothing behind it, and a highlight on a
/// row pointing at a conversation the reader last saw yesterday is a claim about their
/// memory rather than about the app's.
struct ConversationResume: Equatable {
    /// Where the reader last was, or `nil` if they have not left a conversation this session.
    private(set) var conversation: ConversationRoute?

    /// Reads what a change to the navigation path means for the slot.
    ///
    /// Pure, and driven from `onChange` rather than from the two call sites that pop, so a
    /// third way back — the system's own back swipe, which no app code runs through — is
    /// covered by construction.
    ///
    /// Only *emptying* the path fills the slot. Popping a conversation opened from inside
    /// another (a `#channel` reference, a profile sheet's Message) leaves the reader in the
    /// one underneath, which is on screen, so there is nothing to remember yet.
    mutating func observe(path: [ConversationRoute], previously: [ConversationRoute]) {
        guard path.isEmpty, let left = previously.last else { return }
        conversation = left
    }

    /// The slot, if the sidebar still lists the conversation it names.
    ///
    /// Checked against the live list rather than trusted, because a conversation can leave
    /// the sidebar while it is in here — a hidden direct message, a channel this key was
    /// removed from. Reopening one would not be *harmful* (nothing here writes to the relay)
    /// but it would put the reader somewhere the sidebar says they cannot go, with a
    /// highlight on a row that no longer exists to explain it.
    func resolved(among channels: [ChannelListRow]) -> ConversationRoute? {
        guard let conversation, channels.contains(where: { $0.id == conversation.channel.id }) else { return nil }
        return conversation
    }
}
