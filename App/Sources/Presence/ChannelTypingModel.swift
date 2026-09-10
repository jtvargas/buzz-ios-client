import BuzzKit
import Observation

/// Who is typing or working in one conversation, live from ``PresenceStore``.
/// Agents publish the typing heartbeat throughout a work turn, including tool use.
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
    /// Recent heartbeats survive progress messages; only known agents render these.
    private(set) var active: [String] = []

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
        for await snapshot in await store.conversationActivity(in: channel, thread: thread) {
            guard !Task.isCancelled else { return }
            let typing = snapshot.typing.filter { $0 != selfPubkey }
            let activity = snapshot.active.filter { $0 != selfPubkey }
            if typers != typing { typers = typing }
            if active != activity { active = activity }
        }
    }

    func workingAgents(isAgent: (String) -> Bool) -> [String] {
        active.filter(isAgent)
    }

    /// One label per activity, so agents and humans are never grouped under the same
    /// verb. Classification is resolved alongside names, allowing directory updates to
    /// correct the wording even while the set of active pubkeys stays the same.
    func indicator(
        nameFor: (String) -> String,
        isAgent: (String) -> Bool,
        activity: TypingIndicator.Activity
    ) -> String? {
        let names = (activity == .working ? active : typers)
            .filter { isAgent($0) == (activity == .working) }
            .map(nameFor)
        return TypingIndicator.text(for: names, activity: activity)
    }
}

/// Builds "X is typing…" for humans or "X is working…" for agents from resolved names.
/// Multiple agents use a collective label; their individual names live in the popover.
///
/// Human typing uses upstream mobile's wording, arity for arity
/// (`mobile/lib/features/channels/channel_detail_page/app_bar.dart:17-21`). At three or
/// more this used to read "Several people are typing…", which named nobody; upstream
/// keeps the first name and counts the *others*, so three typers read "Alice and 2
/// others are typing…". Desktop diverges — it lists all three at exactly three — and is
/// deliberately not the reference here.
///
/// The ellipsis is the typographic `…` rather than three periods, matching upstream's
/// channel indicator.
enum TypingIndicator {
    enum Activity: String {
        case typing
        case working
    }

    static func text(for names: [String], activity: Activity = .typing) -> String? {
        if activity == .working, names.count > 1 { return "Agents are working…" }
        switch names.count {
        case 0:
            return nil
        case 1:
            return "\(names[0]) is \(activity.rawValue)…"
        case 2:
            return "\(names[0]) and \(names[1]) are \(activity.rawValue)…"
        default:
            // Never singular: this branch starts at three names, so the count of others
            // is at least two.
            return "\(names[0]) and \(names.count - 1) others are \(activity.rawValue)…"
        }
    }
}
