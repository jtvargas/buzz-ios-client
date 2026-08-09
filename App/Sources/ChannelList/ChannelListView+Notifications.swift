import SwiftUI

/// Every way this stack is navigated from *outside* its own view tree: an App Intent, a deep
/// link, a tapped foreground banner.
///
/// Split out for room — `ChannelListView.swift` sits against swiftlint's 1000-line error
/// ceiling, and this is the concern with a seam already cut through it (the routes are
/// resolved by statics in `ChannelListView+ConversationRow.swift`, which reach none of this
/// view's state). The cost is that the surfaces below are `internal` rather than `private`;
/// they are `@State` on a single view either way, and nothing outside this pair of files
/// writes them.
///
/// What they all share is the invariant in ``ChannelListView/openNotification(_:)``: one
/// navigation change per turn of the run loop.
extension ChannelListView {
    /// Opens one navigation request originating outside this view tree.
    ///
    /// The route is derived in ``ChannelListView/route(for:)``, which reads nothing this holds.
    func open(_ target: AppTarget) {
        if case let .destination(destination) = target { return open(destination) }
        guard let route = Self.route(for: target) else { return }
        openNotification(route)
    }

    /// Opens a screen the system asked for — see ``AppDestination``.
    ///
    /// Not ``press(_:)``. A card is tapped by somebody already looking at the sidebar, so it
    /// pushes onto whatever is there; an intent arrives from outside with no idea what is
    /// open, and landing *on top of* a conversation would give the reader a screen they have
    /// to undo before they can do anything else. So this pops first — the same conclusion
    /// the reminder alert reached, for the same reason.
    ///
    /// Idempotent on the screen being asked for: asking for Threads while Threads is already
    /// open leaves it exactly where it is rather than popping and re-pushing it, which would
    /// be a visible flinch for no change of destination.
    func open(_ destination: AppDestination) {
        openedThread = nil
        path = []
        if destination != .threads { showsThreads = nil }
        if destination != .later { showsLater = nil }
        if destination != .drafts { showsDrafts = nil }
        switch destination {
        case .threads: if showsThreads == nil { showsThreads = ThreadsRoute() }
        case .later: if showsLater == nil { showsLater = LaterRoute() }
        case .drafts: if showsDrafts == nil { showsDrafts = DraftsRoute() }
        }
    }

    /// Where this stack is — shared with the Activity tab's, which asks the same question.
    var notificationLocation: InAppNotificationLocation? {
        RecentPlaces.location(path: path, openedThread: openedThread)
    }

    /// Jumps to a conversation or a thread, closing whatever was open on the way.
    ///
    /// # Why closing and opening cannot share an update
    ///
    /// `navigationDestination(item:)` does not simply push. It presents by truncating the
    /// stack back to the depth it was asked *from* — `programmaticallyPresentView(_:fromDepth:)`
    /// — and if the path is being emptied in the same pass, that depth no longer exists and
    /// `AnyNavigationPath.HomogeneousBoxBase.removeLast(_:)` trips a Swift precondition. Two
    /// of the owner's eleven crash reports are exactly that stack. The old shape here wrote
    /// `path = []` and `openedThread = …` back to back, which is that crash spelled out.
    ///
    /// So: unwind, then present on the next turn of the main actor — and only pay for the
    /// second turn when there is something to unwind, so the common jump from the sidebar
    /// stays a single transition.
    ///
    /// The sheets are closed on the same first pass for the same reason rather than a proven
    /// one: dismissing a presentation while a push begins is the other crash signature in
    /// those reports, and nothing here needs the two to be simultaneous.
    func openNotification(_ route: InAppNotificationRoute) {
        guard hasOpenSurface else { return present(route) }

        // Unanimated, so the reader sees one movement — the arrival — rather than a pop
        // followed by a push.
        var silent = Transaction()
        silent.disablesAnimations = true
        withTransaction(silent) { closeOpenSurfaces() }
        Task { @MainActor in present(route) }
    }

    /// Whether anything is on top of the sidebar: a pushed screen, an item destination, a
    /// sheet, or the workspace panel.
    private var hasOpenSurface: Bool {
        workspacePanel.isOpen || showAccount || showsBrowseChannels || showsCreateChannel
            || showsNewDirectMessage || !path.isEmpty || openedThread != nil
            || showsDrafts != nil || showsThreads != nil || showsLater != nil
    }

    private func closeOpenSurfaces() {
        workspacePanel.setOpen(false)
        showAccount = false
        showsBrowseChannels = false
        showsCreateChannel = false
        showsNewDirectMessage = false
        showsDrafts = nil
        showsThreads = nil
        showsLater = nil
        openedThread = nil
        path = []
    }

    /// The push itself, onto a stack that is already empty.
    ///
    /// Both branches aim at the *message* when the route names one, which is the whole reason
    /// a tapped banner feels like an answer rather than a room to search: the surface opens,
    /// walks back to that message and washes it once. It is the landing search already
    /// performs, reached through the same two mechanisms — nothing here is new.
    ///
    /// `.latestReply` is the fallback and not the rule. A thread reached without a message —
    /// an App Intent, a recent place — still wants its newest reply, which is where somebody
    /// who came to catch up belongs.
    private func present(_ route: InAppNotificationRoute) {
        switch route.location {
        case let .channel(channelID):
            path = [ConversationRoute(
                channel: conversationRow(for: channelID, fallback: route.fallbackChannel),
                focus: route.focus
            )]
        case let .thread(channelID, rootID):
            openedThread = ThreadRoute(
                root: rootID,
                channel: channelID,
                anchor: route.focus.map { .reply($0.messageID) } ?? .latestReply
            )
        }
    }
}
