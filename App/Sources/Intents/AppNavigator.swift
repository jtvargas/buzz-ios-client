import Observation

/// Anything the app can be asked to navigate to from outside its view tree.
enum AppTarget: Hashable, Sendable {
    case destination(AppDestination)
    case conversation(EntityID)
    case thread(channelID: String, rootID: String)
}

/// Holds a screen the system has asked for until the app is in a state to show it.
///
/// # Why a queue and not a function call
///
/// An app intent can run at any moment of the app's life, and the most common one is the
/// worst one: the app is not running, Siri launches it, and ``perform()`` writes here while
/// ``RootView`` is still drawing ``AppEnvironment/Phase/needsIdentity`` or
/// ``AppEnvironment/Phase/bootstrapping``. The view that knows how to open Threads —
/// ``ChannelListView`` — does not exist yet, so there is nothing to call. A direct call
/// would land on the floor and the intent would open the app and stop on the sidebar, which
/// is the single most likely way this feature ships broken.
///
/// So the request simply *stays* here. ``ChannelListView`` reads it with
/// `.onChange(of:initial:)`, and `initial: true` is what makes a request made before that
/// view existed get picked up the moment it does. The reminder-alert path one file over
/// leans on the same pair for the same reason — a tap that launches the app writes its
/// value before the view is there to hear about it.
///
/// # Why it is owned by `AppEnvironment`
///
/// It has to outlive every screen, survive a community switch (``RootView`` keys the whole
/// workspace on the active community, so anything below that boundary is discarded), and be
/// reachable from a type the view tree does not own — an ``AppIntent`` reaches it through
/// `@Dependency`, registered once in ``HiveApp/init()``. ``AppEnvironment`` is the only
/// object built early enough and living long enough to be all three, which is the same
/// argument that put ``AppEnvironment/reminderAlerts`` there.
@MainActor
@Observable
final class AppNavigator {
    /// The screen waiting to be opened, or `nil` when there is nothing outstanding.
    ///
    /// Read-only from outside: an intent asks with ``request(_:)`` and the navigation
    /// surface clears with ``consume()``, so "who is allowed to set this" is answered by the
    /// two method names rather than by a convention nobody can see.
    private(set) var pending: AppTarget?

    init() {}

    /// Asks for a screen. Called from an intent's `perform()`, never from a view.
    ///
    /// A later request replaces an earlier unconsumed one rather than queueing behind it:
    /// two "open X" commands in a row mean the person changed their mind, and arriving at
    /// the first screen on the way to the second would be a flicker, not a feature.
    func request(_ target: AppTarget) {
        pending = target
    }

    /// Marks the outstanding request as handled.
    ///
    /// The navigation surface calls this **as it acts**, not before and not later. Clearing
    /// is what stops an unrelated body pass from re-pushing the same screen — the same
    /// discipline `DirectMessageRouter`'s pending conversation is read with.
    func consume() {
        pending = nil
    }
}
