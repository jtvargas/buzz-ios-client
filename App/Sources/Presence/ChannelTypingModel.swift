import BuzzKit
import Observation

/// Who is typing in one conversation, live from ``PresenceStore``.
///
/// Typing is scoped (S-5): to a channel, or to one thread inside it. A thread's model
/// names its root and hears that thread alone. A channel's model carries no `thread` and
/// hears the channel's own level alone — an agent replying inside a thread is silent
/// here, because the message it is announcing is not going to arrive here.
/// See ``BuzzKit/PresenceStore/TypingAudience``.
///
/// The device's own typing is excluded — the relay fans an ephemeral back to its author,
/// and a composer must never render "you are typing" to yourself.
@MainActor
@Observable
final class ChannelTypingModel {
    /// The pubkeys of others typing in this scope, ordered.
    private(set) var typers: [String] = []

    private let channel: String
    private let thread: String?
    private let store: PresenceStore
    private let selfPubkey: String?

    init(channel: String, thread: String? = nil, store: PresenceStore, selfPubkey: String?) {
        self.channel = channel
        self.thread = thread
        self.store = store
        self.selfPubkey = selfPubkey
    }

    /// Consumes the scope's typing stream until cancelled. Attach with `.task`.
    func run() async {
        for await list in await store.typing(in: channel, thread: thread) {
            typers = list.filter { $0 != selfPubkey }
        }
    }

    /// The "X is typing…" string, with each typer's name resolved by `nameFor`. Nil
    /// when no one is typing, so a view can hide the strip entirely.
    func indicator(nameFor: (String) -> String) -> String? {
        TypingIndicator.text(for: typers.map(nameFor))
    }
}

/// Builds the human "X is typing…" phrase from resolved names. Pure and view-free,
/// so the pluralization is unit-testable on its own.
///
/// The wording is upstream mobile's, arity for arity
/// (`mobile/lib/features/channels/channel_detail_page/app_bar.dart:17-21`). At three or
/// more this used to read "Several people are typing…", which named nobody; upstream
/// keeps the first name and counts the *others*, so three typers read "Alice and 2
/// others are typing…". Desktop diverges — it lists all three at exactly three — and is
/// deliberately not the reference here.
///
/// The ellipsis is the typographic `…` rather than three periods, matching upstream's
/// channel indicator.
enum TypingIndicator {
    static func text(for names: [String]) -> String? {
        switch names.count {
        case 0:
            return nil
        case 1:
            return "\(names[0]) is typing…"
        case 2:
            return "\(names[0]) and \(names[1]) are typing…"
        default:
            // Never singular: this branch starts at three names, so the count of others
            // is at least two.
            return "\(names[0]) and \(names.count - 1) others are typing…"
        }
    }
}
