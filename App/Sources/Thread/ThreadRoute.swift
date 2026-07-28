import Foundation

/// Where a thread is pushed from and where it rests when it gets there.
///
/// Split out of `ChannelTimelineView.swift`, which pushes it, so that file is about the
/// channel: the destination is a value two surfaces and a navigation stack share, and it
/// belongs beside the view it opens.

/// A pushed thread: its root id, the channel it lives in, and where it should land. No
/// title — the thread resolves its own heading through the shared directory, so a DM's
/// thread cannot be labelled with the group name the pushing view happened to be showing.
struct ThreadRoute: Hashable, Identifiable {
    let root: String
    let channel: String
    /// Where the thread opens. Defaults to the newest reply, which is where a thread
    /// reached from a message in its own channel should open — the reader is already
    /// looking at the opener.
    var anchor: ThreadLanding = .latestReply
    /// Whether the reply composer takes the keyboard once the thread has settled. Set only
    /// by the actions sheet's "Reply in thread", which is a request to write.
    var focusesComposer: Bool = false

    /// Deliberately the root alone, and neither the anchor nor the focus with it. A thread is
    /// one destination however it was reached, and folding either in would let the same
    /// thread be pushed twice onto the same stack.
    var id: String { root }
}

/// Where a thread rests when it opens.
enum ThreadLanding: Hashable, Sendable {
    /// The newest reply — a conversation's resting position, and where someone who came
    /// to catch up wants to be.
    case latestReply
    /// The message that started the thread, for someone who came to find out what it is
    /// about.
    case opener
}
