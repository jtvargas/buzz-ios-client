import BuzzKit
import Foundation

// MARK: - Typing

/// The thread's own-typing publish.
///
/// A thread used to publish none at all: typing was "signalled at the channel level",
/// which meant a reply being written in a thread announced itself nowhere, because the
/// channel composer is not the one being typed in. Now it publishes in the thread's own
/// scope, tagged exactly as the reply it precedes will be — so every client that scopes
/// typing by the NIP-10 markers (this one, and the desktop client's `threadHeadId`)
/// shows it against the thread rather than the channel.
extension ThreadModel {
    /// Publishes an own typing indicator for this thread as the composer changes,
    /// throttled to one publish per ``typingThrottle`` window. Empty input never
    /// publishes — clearing the field is not typing.
    ///
    /// Fire-and-forget: typing is ephemeral (S-3), so a failure is dropped. The `h` tag
    /// is what makes a channel-scoped ephemeral acceptable to the relay at all (S-5);
    /// the `e` marker is what places it in this thread.
    func handleTyping(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let instant = clock()
        if let last = lastTypingPublish, instant - last < typingThrottle { return }
        lastTypingPublish = instant

        let tags = OutboundTags.typing(channel: channel, thread: root)
        let typing = self.typing
        Task { await typing.publishEphemeral(kind: .typing, content: "", tags: tags) }
    }
}
