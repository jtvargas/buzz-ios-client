import BuzzKit
import Foundation
import Observation

/// Drives ``ThreadsView``: recent thread activity across every channel, live from the
/// store.
///
/// The same pattern as every other list model here — a `ValueObservation` over the
/// `event`/`outbox` region re-fires on each relevant commit and the read is taken again,
/// off the main actor. Nothing is cached between fires, so a reply, a deletion, or a
/// read-state blob is reflected without this model keeping a second copy of the thread
/// list to fall out of step with the store's.
@MainActor
@Observable
final class ThreadsModel {
    /// Threads with replies, most recently active first.
    private(set) var threads: [ThreadActivity] = []
    /// The users each shown message mentions, so the opener and the reply render their
    /// `@`-tokens the same way the thread behind them does.
    private(set) var mentionRefs: [String: MentionRefList] = [:]
    /// True once the first snapshot lands, so the view can tell "no threads" from
    /// "not read yet".
    private(set) var hasLoaded = false

    private let store: BuzzEventStore
    private let selfPubkey: String?

    /// How far back the screen reaches.
    ///
    /// A cap rather than paging: this is a "what have I missed" list, and the fiftieth
    /// most recently active thread is already well past the point where anyone is
    /// catching up. Paging it would be building history browsing for a screen nobody
    /// browses. If the cap is hit the list simply ends — and it is stated here rather
    /// than left implicit, because a silently truncated list reads as a complete one.
    ///
    /// `nonisolated` because the read it bounds runs on the concurrent reader, off this
    /// actor.
    nonisolated static let limit = 50

    init(store: BuzzEventStore, selfPubkey: String?) {
        self.store = store
        self.selfPubkey = selfPubkey
    }

    nonisolated func run() async {
        do {
            for try await _ in DatabaseSignal.changes(in: store.reader) {
                let activity = (try? store.threadActivity(
                    selfPubkey: selfPubkey,
                    limit: Self.limit
                )) ?? []
                // One batched read for both messages of every row, the shape the timeline
                // already uses for a page — not one read per row.
                let ids = activity.flatMap { [$0.opener.id, $0.latestReply.id] }
                let mentions = (try? store.mentions(for: ids)) ?? [:]
                await apply(activity, mentions: mentions)
            }
        } catch {
            // Ends on cancellation or teardown; the last snapshot stays on screen.
        }
    }

    /// The users a message mentions, empty when it mentions none.
    func mentions(for id: String) -> [MentionRef] {
        mentionRefs[id].map { Array($0) } ?? []
    }

    private func apply(_ activity: [ThreadActivity], mentions: [String: MentionRefList]) {
        // Equal values are not written back — the observation re-fires on every committed
        // transaction, and an `@Observable` setter notifies whether or not the value moved.
        guard activity != threads || mentions != mentionRefs || !hasLoaded else { return }
        threads = activity
        mentionRefs = mentions
        hasLoaded = true
    }
}

/// How a thread's opener is shown in a summary row.
enum ThreadSummary {
    /// JT's cap: "Show the original message, limited to 2,000 characters."
    ///
    /// A cap on the *string*, not only on the rendered lines, and that is the point —
    /// `lineLimit` alone still parses, styles and lays out a 60 KB message before
    /// throwing away all but four lines of it, fifty times over on one screen.
    static let openerCharacterLimit = 2000

    /// `text` cut to the limit, with an ellipsis when anything was cut.
    ///
    /// Counted in `Character`s rather than UTF-8 bytes or UTF-16 units, because the limit
    /// is a statement about how much someone is being shown: cutting a family emoji in
    /// half at byte 2000 would satisfy a byte limit and produce mojibake.
    static func opener(_ text: String) -> String {
        guard text.count > openerCharacterLimit else { return text }
        return String(text.prefix(openerCharacterLimit)) + "\u{2026}"
    }

    /// What a row says about the replies it is not showing, or `nil` when it is showing
    /// all of them.
    ///
    /// The newest reply is drawn in full below, so this counts only what sits *between*
    /// it and the opener. A thread with one reply hides nothing and says nothing.
    static func moreReplies(_ activity: ThreadActivity) -> String? {
        let hidden = activity.intermediateReplyCount
        guard hidden > 0 else { return nil }
        return hidden == 1 ? "1 more reply" : "\(hidden) more replies"
    }
}
