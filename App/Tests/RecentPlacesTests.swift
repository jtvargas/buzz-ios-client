import BuzzKit
import Foundation
import Testing
import UIKit

@testable import Hive

/// The history behind the home screen's toolbar: what it remembers, in what order, and —
/// the owner's own requirement — that one community's history is never the other's.
///
/// Pure. Every rule here is a function of a list and an id, so none of this needs a screen,
/// a store or a relay. The one thing that *is* asserted against the system is the toolbar
/// symbol's existence, because a misspelt system symbol draws nothing at all and would ship
/// as an invisible button.
@Suite("Recent places", .timeLimit(.minutes(1)))
@MainActor
struct RecentPlacesTests {
    private static let communityA = UUID()
    private static let communityB = UUID()

    /// A throwaway defaults suite, so a test run never writes over the history of whatever
    /// build is installed on this machine.
    private func makeSuite() -> (defaults: UserDefaults, name: String) {
        let name = "hive.tests.recents.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    private func forget(_ suite: String) {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    private static func row(_ id: String) -> ChannelListRow {
        ChannelListRow(
            id: id,
            name: id,
            about: nil,
            picture: nil,
            isPrivate: false,
            lastMessageAt: nil,
            lastMessageSnippet: nil,
            lastMessageAuthor: nil
        )
    }

    @Test("the newest place is first, and a revisit moves rather than repeats")
    func newestFirst() {
        let (defaults, suite) = makeSuite()
        defer { forget(suite) }
        let recents = RecentPlaces(defaults: defaults)

        recents.visit(.channel("a"), in: Self.communityA)
        recents.visit(.channel("b"), in: Self.communityA)
        recents.visit(.channel("a"), in: Self.communityA)

        #expect(recents.places.map(\.channelID) == ["a", "b"])
    }

    /// Standing in the sidebar is not a place, and it is what the recorder is handed every
    /// time the reader backs out of one.
    @Test("nowhere is not recorded")
    func nowhereIsNotAPlace() {
        let (defaults, suite) = makeSuite()
        defer { forget(suite) }
        let recents = RecentPlaces(defaults: defaults)

        recents.visit(.channel("a"), in: Self.communityA)
        recents.visit(nil, in: Self.communityA)

        #expect(recents.places.map(\.channelID) == ["a"])
    }

    /// The owner's number, and the reason the list is a history rather than a log.
    @Test("the list stops at twelve, dropping the oldest")
    func capacity() {
        let (defaults, suite) = makeSuite()
        defer { forget(suite) }
        let recents = RecentPlaces(defaults: defaults)

        for index in 0..<15 {
            recents.visit(.channel("c\(index)"), in: Self.communityA)
        }

        #expect(recents.places.count == RecentPlaces.capacity)
        #expect(recents.places.first?.channelID == "c14")
        #expect(recents.places.last?.channelID == "c3")
    }

    /// Both appear in the owner's reference, on adjacent rows: a channel and a thread
    /// inside it are two places you can be, and going back to one is not going back to the
    /// other.
    @Test("a channel and a thread inside it are separate places")
    func threadIsItsOwnPlace() {
        let (defaults, suite) = makeSuite()
        defer { forget(suite) }
        let recents = RecentPlaces(defaults: defaults)

        recents.visit(.channel("a"), in: Self.communityA)
        recents.visit(.thread(channelID: "a", rootID: "root"), in: Self.communityA)

        #expect(recents.places.count == 2)
        #expect(recents.places.first?.isThread == true)
        #expect(recents.places.last?.isThread == false)
    }

    /// The owner's requirement, and the sharp end of it: the twelve slots are *per
    /// community*, so reading a dozen channels in one cannot push the other's history out.
    @Test("one community's visits never enter or evict another's")
    func communitiesDoNotMix() {
        let (defaults, suite) = makeSuite()
        defer { forget(suite) }
        let recents = RecentPlaces(defaults: defaults)

        recents.visit(.channel("a-only"), in: Self.communityA)
        for index in 0..<RecentPlaces.capacity {
            recents.visit(.channel("b\(index)"), in: Self.communityB)
        }

        #expect(recents.places.count == RecentPlaces.capacity)
        #expect(!recents.places.contains { $0.channelID == "a-only" })

        recents.use(Self.communityA)
        #expect(recents.places.map(\.channelID) == ["a-only"])
    }

    /// The second guard, for a read taken while a switch is in flight: a list loaded for
    /// one community answers a question about another with nothing, rather than with the
    /// wrong community's rows.
    @Test("a read for a different community answers empty")
    func readsAreCommunityScoped() {
        let (defaults, suite) = makeSuite()
        defer { forget(suite) }
        let recents = RecentPlaces(defaults: defaults)
        recents.visit(.channel("a"), in: Self.communityA)

        #expect(recents.resolved(among: [Self.row("a")], in: Self.communityA).count == 1)
        #expect(recents.resolved(among: [Self.row("a")], in: Self.communityB).isEmpty)
        #expect(recents.resolved(among: [Self.row("a")], in: nil).isEmpty)
    }

    /// A conversation can leave the sidebar while it is in here — a hidden direct message,
    /// a channel this key was removed from. Offering it would be a row that navigates
    /// somewhere the sidebar says the reader cannot go.
    @Test("a place whose conversation has left the sidebar is dropped")
    func unlistedPlacesAreDropped() {
        let (defaults, suite) = makeSuite()
        defer { forget(suite) }
        let recents = RecentPlaces(defaults: defaults)

        recents.visit(.channel("gone"), in: Self.communityA)
        recents.visit(.channel("here"), in: Self.communityA)

        let resolved = recents.resolved(among: [Self.row("here")], in: Self.communityA)
        #expect(resolved.map(\.channelID) == ["here"])
    }

    /// A history that empties every launch is not a history. Asserted through a second
    /// object over the same defaults, which is what a relaunch is.
    @Test("the history survives a relaunch, per community")
    func persists() {
        let (defaults, suite) = makeSuite()
        defer { forget(suite) }

        let first = RecentPlaces(defaults: defaults)
        first.visit(.thread(channelID: "a", rootID: "root"), in: Self.communityA)
        first.visit(.channel("b"), in: Self.communityB)

        let second = RecentPlaces(defaults: defaults)
        second.use(Self.communityA)
        #expect(second.places.map(\.id) == ["a/root"])
        second.use(Self.communityB)
        #expect(second.places.map(\.id) == ["b"])
    }

    /// Pinned for the reason ``StarredConversations/storageKey`` is: renaming this silently
    /// discards the history every existing install has built, and nothing else would catch
    /// it. The community's id being *in* the key is the whole of the isolation.
    @Test("the storage key names the community")
    func storageKeyIsPinned() {
        let community = UUID(uuidString: "0F5A1F62-1E4E-4E2E-9F1E-2B7A3C4D5E6F")!
        #expect(
            RecentPlaces.storageKey(for: community)
                == "home.recent.places.0F5A1F62-1E4E-4E2E-9F1E-2B7A3C4D5E6F"
        )
    }

    /// The rule both tabs' stacks share. A thread is where the reader is even though the
    /// conversation it belongs to is still underneath it on the stack.
    @Test("the thread on top wins over the conversation under it")
    func locationPrefersTheThread() {
        let channel = ChannelListRow(
            id: "a",
            name: "a",
            about: nil,
            picture: nil,
            isPrivate: false,
            lastMessageAt: nil,
            lastMessageSnippet: nil,
            lastMessageAuthor: nil
        )
        let path = [ConversationRoute(channel: channel)]

        #expect(RecentPlaces.location(path: path, openedThread: nil) == .channel("a"))
        #expect(RecentPlaces.location(path: [], openedThread: nil) == nil)
        #expect(
            RecentPlaces.location(
                path: path,
                openedThread: ThreadRoute(root: "root", channel: "a")
            ) == .thread(channelID: "a", rootID: "root")
        )
    }

    /// A system symbol that does not exist renders as nothing — no warning, no placeholder.
    /// This is the only thing standing between a renamed SF Symbol and an invisible button.
    @Test("the history symbol exists")
    func symbolExists() {
        #expect(UIImage(systemName: HomeToolbarControls.symbol) != nil)
    }
}
