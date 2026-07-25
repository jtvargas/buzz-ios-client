import BuzzKit
import Observation

/// Who is typing in one channel, live from ``PresenceStore``.
///
/// Typing is channel-scoped (S-5). The device's own typing is excluded — the relay
/// fans an ephemeral back to its author, and a composer must never render "you are
/// typing" to yourself.
@MainActor
@Observable
final class ChannelTypingModel {
    /// The pubkeys of others typing in this channel, ordered.
    private(set) var typers: [String] = []

    private let channel: String
    private let store: PresenceStore
    private let selfPubkey: String?

    init(channel: String, store: PresenceStore, selfPubkey: String?) {
        self.channel = channel
        self.store = store
        self.selfPubkey = selfPubkey
    }

    /// Consumes the channel's typing stream until cancelled. Attach with `.task`.
    func run() async {
        for await list in await store.typing(in: channel) {
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
            return "Several people are typing…"
        }
    }
}
