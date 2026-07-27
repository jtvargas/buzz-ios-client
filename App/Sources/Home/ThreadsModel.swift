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
    /// The users each shown message mentions, so the two messages a row draws render their
    /// `@`-tokens the same way the thread behind them does.
    private(set) var mentionRefs: [String: MentionRefList] = [:]
    /// Who has replied in each thread, in the order they first spoke — the row's subtitle,
    /// and the faces on its replies strip.
    private(set) var participants: [String: ThreadParticipants] = [:]
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

    /// How many of a thread's people are read back.
    ///
    /// Generous rather than tight, because this number is not only how many names can be
    /// shown — it is the total the subtitle counts *from*, and a cap below the real number
    /// would make "and 4 others" understate by exactly the amount it was capped by. The read
    /// costs one row per distinct author, not per reply, so a thread would need fifty
    /// different people in it to reach this.
    nonisolated static let participantLimit = 50

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
                // Batched reads over the whole page, the shape the timeline already uses —
                // not one read per row. Both of a row's messages go into the one read,
                // because both are rendered: a mention inside the newest reply that was
                // never resolved draws as a raw `@`-token or as a pill that opens nobody.
                // Fifty rows is one hundred ids, which is one `IN` clause, not a hundred
                // trips to the reader.
                let shown = activity.flatMap { [$0.opener.id, $0.latestReply.id] }
                let mentions = (try? store.mentions(for: shown)) ?? [:]
                let people = (try? store.threadParticipants(
                    for: activity.map(\.rootID),
                    limit: Self.participantLimit
                )) ?? [:]
                await apply(activity, mentions: mentions, participants: people)
            }
        } catch {
            // Ends on cancellation or teardown; the last snapshot stays on screen.
        }
    }

    /// The users a message mentions, empty when it mentions none.
    func mentions(for id: String) -> [MentionRef] {
        mentionRefs[id].map { Array($0) } ?? []
    }

    /// Everyone in a thread, in the order they arrived: whoever opened it, then whoever
    /// replied.
    ///
    /// The opener is first and always present. ``BuzzKit/ThreadParticipants`` deliberately
    /// answers a narrower question — who *replied* — because that is what the faces under a
    /// message in a timeline mean. A thread's people include the person who started it.
    func people(in activity: ThreadActivity) -> [String] {
        let repliers = participants[activity.rootID].map { Array($0.pubkeys) } ?? []
        return [activity.opener.pubkey] + repliers.filter { $0 != activity.opener.pubkey }
    }

    private func apply(
        _ activity: [ThreadActivity],
        mentions: [String: MentionRefList],
        participants people: [String: ThreadParticipants]
    ) {
        // Equal values are not written back — the observation re-fires on every committed
        // transaction, and an `@Observable` setter notifies whether or not the value moved.
        guard activity != threads
            || mentions != mentionRefs
            || people != participants
            || !hasLoaded
        else { return }
        threads = activity
        mentionRefs = mentions
        participants = people
        hasLoaded = true
    }
}

/// How a thread's two messages — its opener and its newest reply — are shown in a summary
/// row.
enum ThreadSummary {
    /// JT's cap: "Show the original message, limited to 2,000 characters."
    ///
    /// A cap on the *string*, not only on the rendered lines, and that is the point —
    /// `lineLimit` alone still parses, styles and lays out a 60 KB message before
    /// throwing away all but four lines of it, fifty times over on one screen.
    ///
    /// One number for both messages a row draws, not one per message: they sit one above
    /// the other in the same list at the same size, and a screen where the opener is cut
    /// and the reply below it is not would read as a bug in the cut.
    static let characterLimit = 2000

    /// `text` cut to the limit, with an ellipsis when anything was cut.
    ///
    /// Counted in `Character`s rather than UTF-8 bytes or UTF-16 units, because the limit
    /// is a statement about how much someone is being shown: cutting a family emoji in
    /// half at byte 2000 would satisfy a byte limit and produce mojibake.
    static func cut(_ text: String) -> String {
        guard text.count > characterLimit else { return text }
        return String(text.prefix(characterLimit)) + "\u{2026}"
    }

    /// A message as the summary row renders it: the real message row, over content cut to
    /// the limit.
    ///
    /// The cut is on the *row*, before the view sees it, because the row is what carries
    /// the text into the markdown engine — capping only what is drawn would still parse,
    /// style and lay out a 60 KB message fifty times on one screen. Both bodies are cut:
    /// the rich one is what renders when there is one.
    static func summarised(_ row: TimelineRow) -> TimelineRow {
        let content = cut(row.content)
        let rich = row.richContent.map(cut)
        guard content != row.content || rich != row.richContent else { return row }
        return rebuilt(row, content: content, richContent: rich, replyCount: row.replyCount)
    }

    /// The newest reply as the summary row renders it: the same cut as the opener, over a
    /// row that no longer claims a thread of its own.
    ///
    /// The tally is what has to go, not the participants. ``TimelineRowView`` draws its
    /// replies strip on `replyCount > 0` and an `onOpenThread` it was given, so handing it
    /// no faces would only empty the strip rather than remove it — and the reply *needs*
    /// that handler, because its own tap is how the row offers "take me to what I missed".
    /// Zeroing the tally is therefore the only lever, and it is the honest one: on this
    /// surface the newest reply is a message being shown, not a thread root, and the strip
    /// that belongs to this conversation is already under the opener above it.
    ///
    /// A reply usually arrives with a zero tally anyway, because NIP-10 keeps every reply's
    /// `root` tag on the message that opened the thread. "Usually" is a property of the
    /// clients seen so far rather than of the data: a reply whose own `root` names itself
    /// projects as its own root and would otherwise grow a second strip here.
    static func summarisedReply(_ row: TimelineRow) -> TimelineRow {
        let summary = summarised(row)
        guard summary.hasThread || summary.lastReplyAt != nil else { return summary }
        return rebuilt(summary, content: summary.content, richContent: summary.richContent, replyCount: 0)
    }

    /// One message with some of its fields replaced.
    ///
    /// ``BuzzKit/TimelineRow``'s properties are all `let` and it offers no `with`-style
    /// copy, so both transforms above would otherwise spell out the same fourteen arguments
    /// — and a field added to the row would then have to be remembered in two places.
    ///
    /// `lastReplyAt` follows `replyCount` rather than being its own parameter: it is the
    /// time of a reply the tally counts, and a row saying "no replies, last one an hour
    /// ago" is not a state any caller should be able to ask for.
    private static func rebuilt(
        _ row: TimelineRow,
        content: String,
        richContent: String?,
        replyCount: Int
    ) -> TimelineRow {
        TimelineRow(
            id: row.id,
            pubkey: row.pubkey,
            createdAt: row.createdAt,
            content: content,
            isEdited: row.isEdited,
            isDeleted: row.isDeleted,
            richContent: richContent,
            delivery: row.delivery,
            authorName: row.authorName,
            authorPicture: row.authorPicture,
            parentID: row.parentID,
            rootID: row.rootID,
            replyCount: replyCount,
            lastReplyAt: replyCount > 0 ? row.lastReplyAt : nil
        )
    }
}

/// Who is in a thread, as one line under its heading.
///
/// A sentence rather than a stack of faces: this row already draws the opener with its
/// author's avatar and the replies strip with the repliers', so a third set of pictures
/// would be the same information a third time. What the line adds is the *names* — the
/// question "is this conversation mine to read" is answered by who is in it.
enum ThreadParticipantSummary {
    /// How many people are named before the rest become a number. Three, which is JT's own
    /// example — enough to recognise a conversation by, short enough to stay on one line.
    static let namedLimit = 3

    /// `Jonathan`, `Jonathan and Jarvis`, `Jonathan, Jarvis, and Lisanne`, then
    /// `Jonathan, Jarvis, Lisanne, and 3 others`.
    ///
    /// Pure, and given already-resolved names rather than pubkeys: turning a key into
    /// something a reader sees is ``EntityNames``' job everywhere in this app, and a second
    /// resolver here would be a second answer to the same question.
    ///
    /// `total` is passed separately from `names.count` because the two differ: the caller
    /// may hand over fewer names than the thread has people (the read is capped), and the
    /// count is what "and 3 others" has to be true about.
    static func text(names: [String], total: Int? = nil) -> String? {
        let people = names.filter { !$0.isEmpty }
        guard !people.isEmpty else { return nil }
        let total = max(total ?? people.count, people.count)
        let named = Array(people.prefix(min(namedLimit, total)))
        let others = total - named.count

        if others > 0 {
            let rest = others == 1 ? "1 other" : "\(others) others"
            return named.joined(separator: ", ") + ", and " + rest
        }
        switch named.count {
        case 1:
            return named[0]
        case 2:
            return named[0] + " and " + named[1]
        default:
            return named.dropLast().joined(separator: ", ") + ", and " + (named.last ?? "")
        }
    }
}
