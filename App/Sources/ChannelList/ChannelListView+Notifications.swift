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
/// Every request resolves to the stack's single route path.
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
    ///
    func open(_ destination: AppDestination) {
        let route: AppRoute = switch destination {
        case .threads: .threads
        case .later: .later
        case .drafts: .drafts
        }
        guard path != [route] || hasOverlay else { return }
        closeOpenSurfaces()
        path = [route]
    }

    /// Where this stack is — shared with the Activity tab's, which asks the same question.
    var notificationLocation: InAppNotificationLocation? {
        RecentPlaces.location(path: path)
    }

    /// Jumps to a conversation or a thread, closing whatever was open on the way.
    ///
    func openNotification(_ route: InAppNotificationRoute) {
        closeOpenSurfaces()
        present(route)
    }

    private var hasOverlay: Bool {
        workspacePanel.isOpen || showAccount || showsBrowseChannels || showsCreateChannel
            || showsNewDirectMessage
    }

    private func closeOpenSurfaces() {
        workspacePanel.setOpen(false)
        showAccount = false
        showsBrowseChannels = false
        showsCreateChannel = false
        showsNewDirectMessage = false
    }

    /// The route replacement itself.
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
            path = [.conversation(ConversationRoute(
                channel: conversationRow(for: channelID, fallback: route.fallbackChannel),
                focus: route.focus
            ))]
        case let .thread(channelID, rootID):
            path = [.thread(ThreadRoute(
                root: rootID,
                channel: channelID,
                anchor: route.focus.map { .reply($0.messageID) } ?? .latestReply
            ))]
        }
    }
}
