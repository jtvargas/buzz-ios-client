import BuzzKit
import Foundation

/// The chips above the Activity list: which slice of what is addressed to you is shown.
///
/// One case per chip, and the *only* place the rail's contents are stated — `CaseIterable`
/// is what the rail iterates, so a sixth chip is this enum growing a case rather than a
/// view being edited. That is the scalability JT asked for, and it is worth being explicit
/// about what makes it real: nothing downstream switches exhaustively on a filter except
/// ``matches(_:)`` below, so a new case cannot silently fail to filter.
///
/// The categories themselves live in ``BuzzKit/ActivityCategory``, which is what the store
/// classifies into. This type is the *presentation* of those: `all` has no category behind
/// it, and a future `Unread` or `Later` chip would have no category either. Keeping them
/// separate is what stops the read's vocabulary being dictated by the chip rail's.
enum ActivityFilter: String, CaseIterable, Hashable, Identifiable {
    /// Everything the feed holds. First, selected by default, and never empty when any
    /// other chip is non-empty — see ``matches(_:)``.
    case all
    /// Someone named you.
    case mentions
    /// Something is waiting on a decision from you.
    case action
    /// Traffic in conversations you are in that did not name you.
    case activity
    /// Agents reporting on work.
    case agents

    var id: String { rawValue }

    /// The chip's word. Plural where the chip is a bucket of things, singular where the
    /// category names a state — the same distinction the sidebar's own headings make.
    var title: String {
        switch self {
        case .all: "All"
        case .mentions: "Mentions"
        case .action: "Action"
        case .activity: "Activity"
        case .agents: "Agents"
        }
    }

    /// The category this chip filters to, `nil` for ``all``.
    ///
    /// Not every chip has to have one — that is the point of it being optional rather than
    /// this enum simply being ``BuzzKit/ActivityCategory`` with an extra case.
    var category: ActivityCategory? {
        switch self {
        case .all: nil
        case .mentions: .mention
        case .action: .needsAction
        case .activity: .activity
        case .agents: .agentActivity
        }
    }

    /// Whether a row belongs under this chip.
    ///
    /// Asked of *every* category on the row rather than only its loudest
    /// (``BuzzKit/ActivityEntry/matches(_:)``), so an agent that `@`-names you is under both
    /// Mentions and Agents. A row that appeared under only its loudest category is the
    /// failure mode people report as "my mention disappeared".
    ///
    /// An approval request is **not** also a mention, though it always carries a `p` tag —
    /// that tag addresses it rather than mentioning you, and the relay draws the same line
    /// (`crates/buzz-db/src/feed.rs:106` vs `:191`). See
    /// ``BuzzKit/ActivityFeedRead/Candidate/categories``.
    ///
    /// # Why `all` is unconditional
    ///
    /// Desktop's All view is *not* everything: `matchesInboxAllView`
    /// (`desktop/src/features/home/lib/inboxViewHelpers.ts:78-102`) drops plain
    /// `activity`-category rows, and — the part worth knowing — desktop then offers no chip
    /// that recovers them, so on desktop a generic channel post is reachable from no filter
    /// at all. Hive does not reproduce that, for two reasons. The narrowing desktop is
    /// reaching for already happened further down: this feed's `activity` category means a
    /// direct message or a reply in a thread you are in, never the workspace firehose (see
    /// ``BuzzKit/ActivityFeedRead/candidateSQL``). And a chip that shows rows the All chip
    /// hides makes All a lie — on a phone, where the chip rail is the whole navigation of
    /// this screen, a row you can only find by guessing which chip is hiding it is a row
    /// you will not find.
    func matches(_ entry: ActivityEntry) -> Bool {
        guard let category else { return true }
        return entry.matches(category)
    }
}
