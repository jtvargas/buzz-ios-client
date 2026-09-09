import BuzzKit
import Foundation
import NostrCore
import Observation

/// Something the reader did that earns the App Store review request, and the rule
/// that decides how much of it is enough.
///
/// # The whole switchboard is ``rule``
///
/// Turning a trigger off is `isEnabled: false` on its rule. Removing one is deleting
/// its case — the compiler then points straight at the single `record(_:)` call site
/// that fed it, so a removed trigger cannot leave a live counter behind. Adding one is
/// a case, a rule, and one `record(_:)` line at the moment it describes. Nothing
/// registers, nothing dispatches, and no call site names a number.
enum ReviewTrigger: String, CaseIterable, Sendable {
    /// The app was brought to the foreground.
    case appOpens
    /// A message carrying several pictures was accepted by the relay.
    case imageBatchSent
    /// A reaction was added to a message — added, never withdrawn.
    case reactionsAdded
    /// A conversation was opened from the Drafts screen.
    case draftReopened

    /// How many occurrences arm this trigger, over what span, and whether it counts
    /// at all.
    struct Rule: Sendable {
        /// Occurrences needed. Reaching it arms the request; passing it changes nothing,
        /// because arming clears the counter.
        let count: Int
        let window: Window
        let isEnabled: Bool
    }

    /// How long a trigger's occurrences accumulate before they stop counting.
    enum Window: Sendable {
        /// Resets at local midnight. "Five times in the same day" is this, and it is
        /// deliberately the *device's* calendar rather than a rolling 24 hours: the
        /// owner asked for a day, and a rolling window would arm on the fifth open
        /// spread over two evenings.
        case calendarDay
        /// Never resets. A count of lifetime occurrences.
        case forever
    }

    var rule: Rule {
        switch self {
        case .appOpens: Rule(count: 5, window: .calendarDay, isEnabled: true)
        case .imageBatchSent: Rule(count: 1, window: .forever, isEnabled: true)
        case .reactionsAdded: Rule(count: 3, window: .forever, isEnabled: true)
        case .draftReopened: Rule(count: 2, window: .forever, isEnabled: true)
        }
    }
}

/// Decides when to ask for an App Store review, and holds the counters that decide it.
///
/// # Why the gate matters more than the triggers
///
/// `StoreKit` shows at most three review requests per person per 365 days and reports
/// nothing back when it discards one — `requestReview()` returns `Void` and looks
/// identical whether a sheet appeared or the quota swallowed it. So four triggers
/// without a gate are not four chances to be asked, they are four ways to spend the
/// same one prompt on whichever moment happened to come first. This object allows at
/// most **one ask per app version**, with a floor of ``minimumInterval`` between asks,
/// and clears every counter the moment it asks.
///
/// # Why `UserDefaults`, and why one instance for the process
///
/// The same reasoning as ``AppSettings``: this is a statement about how one person uses
/// one phone, it is small, and losing it costs a delayed prompt. It is deliberately
/// *not* community-scoped — the object graph under ``AppEnvironment`` is rebuilt on
/// every community switch, and a review counter that reset itself when somebody changed
/// workspace would never reach five of anything.
///
/// ``shared`` exists for the reason ``HiveThemeBox/shared`` does: two of the four
/// recording sites are inside models (``ChannelTimelineModel/react(_:on:)`` and
/// ``ThreadModel/react(_:on:)``) built in a view's `init`, before any environment is
/// reachable, and threading an optional through the six construction sites those two
/// views have would be plumbing rather than design. ``AppEnvironment/reviewPrompt``
/// hands back this same instance, so there is one object and one set of counters.
@MainActor
@Observable
final class ReviewPrompt {
    /// The process-wide instance. See the type comment for why there is one.
    static let shared = ReviewPrompt()

    /// A trigger has been armed and nothing has asked yet.
    ///
    /// Observed by ``RootView``, which is the only place in the app that may present the
    /// request. Set here, cleared by ``didRequest()``.
    private(set) var shouldRequest = false

    /// The floor between two asks, independent of the app version.
    ///
    /// A version bump alone is not licence to ask again: this app ships often, and
    /// "once per version" on a weekly release is a prompt a week. Both conditions have
    /// to pass.
    static let minimumInterval: TimeInterval = 90 * 24 * 60 * 60

    /// How many pictures in one message make it a batch worth noticing.
    ///
    /// Four, because the owner asked for *more than three*. Files and videos do not
    /// count — see ``noteSentEvent(_:)``.
    static let batchImageCount = 4

    private let defaults: UserDefaults
    private let now: () -> Date
    /// The running app's marketing version, or `nil` when the bundle carries none — in
    /// which case the per-version half of the gate cannot be enforced and only the
    /// interval floor applies.
    private let appVersion: String?

    /// Whether the foreground is already counted, so the `.inactive` bounce that a
    /// Control Centre pull-down or a permission alert produces is one open rather than
    /// two. Not persisted: a relaunch is an open by definition.
    private var isForegroundCounted = false

    /// - Parameters:
    ///   - defaults: injectable so the counters can be driven against a scratch suite
    ///     rather than the app's own preferences — the seam ``AppSettings`` takes.
    ///   - now: injectable so the day window and the interval floor can be exercised
    ///     without waiting for either.
    init(
        defaults: UserDefaults = .standard,
        appVersion: String? = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
        now: @escaping () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.appVersion = appVersion
        self.now = now
    }

    // MARK: - Recording

    /// Counts one occurrence of `trigger` and arms the request if that was enough.
    ///
    /// Nothing happens once the gate is closed, and the counter does not advance either:
    /// a person who has already been asked this version is not accumulating credit
    /// towards the next one, and their reactions between now and the next release should
    /// not arm it the instant it ships.
    func record(_ trigger: ReviewTrigger) {
        let rule = trigger.rule
        guard rule.isEnabled, isAllowedToAsk else { return }
        guard bump(trigger, in: rule.window) >= rule.count else { return }
        shouldRequest = true
    }

    /// The app came to the foreground. Consecutive calls without an intervening
    /// ``noteLeftForeground()`` count once.
    func recordAppOpen() {
        guard !isForegroundCounted else { return }
        isForegroundCounted = true
        record(.appOpens)
    }

    /// The app was backgrounded, so the next foreground is a new open.
    func noteLeftForeground() {
        isForegroundCounted = false
    }

    /// One event this device sent and the relay acknowledged.
    ///
    /// Counted here rather than at the composer because the owner asked for pictures
    /// that "are sent correctly to the relay": at the composer nothing is known yet, and
    /// a send whose uploads fail never reaches this. Pictures only — a message carrying
    /// four PDFs is not the moment this is trying to catch.
    func noteSentEvent(_ event: NostrEvent) {
        let images = MessageMedia.parse(tags: event.tags).filter { $0.kind == .image }.count
        guard images >= Self.batchImageCount else { return }
        record(.imageBatchSent)
    }

    /// Watches one engine's relay acknowledgements for the picture-batch trigger.
    ///
    /// Runs for as long as the engine it was handed lives, which is one community's
    /// session — ``RootView`` restarts it across the remount boundary.
    nonisolated func watchSentEvents(on engine: SyncEngine) async {
        for await event in await engine.sentConfirmations() {
            await noteSentEvent(event)
        }
    }

    // MARK: - The gate

    /// Whether an ask is permitted at all: not already asked in this version, and not
    /// within ``minimumInterval`` of the last one.
    var isAllowedToAsk: Bool {
        if let appVersion, defaults.string(forKey: Key.lastAskedVersion) == appVersion {
            return false
        }
        let lastAsked = defaults.object(forKey: Key.lastAskedAt) as? Double
        guard let lastAsked else { return true }
        return now().timeIntervalSince1970 - lastAsked >= Self.minimumInterval
    }

    /// Records that the request was made, and disarms everything.
    ///
    /// "Made", not "seen": `requestReview()` has no completion, so whether a sheet
    /// actually appeared is not knowable from here. Treating the attempt as the ask is
    /// the conservative reading — it can delay a prompt, never repeat one.
    func didRequest() {
        shouldRequest = false
        if let appVersion {
            defaults.set(appVersion, forKey: Key.lastAskedVersion)
        }
        defaults.set(now().timeIntervalSince1970, forKey: Key.lastAskedAt)
        for trigger in ReviewTrigger.allCases {
            defaults.removeObject(forKey: Key.count(trigger))
            defaults.removeObject(forKey: Key.windowStart(trigger))
        }
    }

    #if DEBUG
    /// Clears every counter and the gate, so the triggers can be walked again on a
    /// build whose version has not changed. Reached from Settings; compiled out of
    /// release.
    func resetForTesting() {
        shouldRequest = false
        isForegroundCounted = false
        defaults.removeObject(forKey: Key.lastAskedVersion)
        defaults.removeObject(forKey: Key.lastAskedAt)
        for trigger in ReviewTrigger.allCases {
            defaults.removeObject(forKey: Key.count(trigger))
            defaults.removeObject(forKey: Key.windowStart(trigger))
        }
    }

    /// What each trigger has counted so far, for the debug row that shows it.
    func debugCounts() -> [(ReviewTrigger, Int)] {
        ReviewTrigger.allCases.map { ($0, defaults.integer(forKey: Key.count($0))) }
    }
    #endif

    // MARK: - Counters

    /// Adds one to `trigger`'s counter, resetting it first if its window has rolled
    /// over, and answers the new total.
    private func bump(_ trigger: ReviewTrigger, in window: ReviewTrigger.Window) -> Int {
        let current = now()
        var count = defaults.integer(forKey: Key.count(trigger))
        if case .calendarDay = window {
            let dayStart = Calendar.current.startOfDay(for: current).timeIntervalSince1970
            if defaults.object(forKey: Key.windowStart(trigger)) as? Double != dayStart {
                defaults.set(dayStart, forKey: Key.windowStart(trigger))
                count = 0
            }
        }
        count += 1
        defaults.set(count, forKey: Key.count(trigger))
        return count
    }

    /// The `UserDefaults` keys.
    ///
    /// Derived from the trigger's raw value rather than listed, which is what keeps
    /// "add a trigger" to a case and a rule. Unlike the starred-conversation and
    /// section-expansion keys, these are deliberately *not* pinned by a test: renaming
    /// a case discards that trigger's progress, and the cost of that is one prompt
    /// arriving later than it would have.
    private enum Key {
        static let lastAskedVersion = "review.lastAskedVersion"
        static let lastAskedAt = "review.lastAskedAt"

        static func count(_ trigger: ReviewTrigger) -> String {
            "review.\(trigger.rawValue).count"
        }

        static func windowStart(_ trigger: ReviewTrigger) -> String {
            "review.\(trigger.rawValue).windowStart"
        }
    }
}
