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

        #expect(recents.places(in: Self.communityA).map(\.channelID) == ["a", "b"])
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

        #expect(recents.places(in: Self.communityA).map(\.channelID) == ["a"])
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

        let places = recents.places(in: Self.communityA)
        #expect(places.count == RecentPlaces.capacity)
        #expect(places.first?.channelID == "c14")
        #expect(places.last?.channelID == "c3")
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

        let places = recents.places(in: Self.communityA)
        #expect(places.count == 2)
        #expect(places.first?.isThread == true)
        #expect(places.last?.isThread == false)
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

        #expect(recents.places(in: Self.communityB).count == RecentPlaces.capacity)
        #expect(!recents.places(in: Self.communityB).contains { $0.channelID == "a-only" })
        #expect(recents.places(in: Self.communityA).map(\.channelID) == ["a-only"])
    }

    /// Every read names the community it is about, so there is no "current" list to be
    /// pointed at the wrong one — the isolation is the lookup itself.
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
        #expect(second.places(in: Self.communityA).map(\.id) == ["a/root"])
        #expect(second.places(in: Self.communityB).map(\.id) == ["b"])
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
        let conversation = ConversationRoute(channel: channel)
        let path: [AppRoute] = [.conversation(conversation)]

        #expect(RecentPlaces.location(path: path) == .channel("a"))
        #expect(RecentPlaces.location(path: []) == nil)
        #expect(
            RecentPlaces.location(
                path: path + [.thread(ThreadRoute(root: "root", channel: "a"))]
            ) == .thread(channelID: "a", rootID: "root")
        )
        #expect(RecentPlaces.location(path: [.threads]) == nil)
    }

    /// The regression the owner reported as "the history randomly disappears".
    ///
    /// The first version held one list plus the community it was loaded for, and re-pointed
    /// it on demand — so a call made while the app had no active community (a launch, a
    /// switch, a signed-out frame) pointed it at nothing and emptied it. Nothing the reader
    /// had done was lost on disk, but the list they were looking at went blank.
    @Test("a visit with no community leaves every community's history alone")
    func nilCommunityDoesNotWipe() {
        let (defaults, suite) = makeSuite()
        defer { forget(suite) }
        let recents = RecentPlaces(defaults: defaults)

        recents.visit(.channel("a"), in: Self.communityA)
        recents.visit(.channel("b"), in: nil)
        recents.visit(nil, in: nil)

        #expect(recents.places(in: Self.communityA).map(\.channelID) == ["a"])
        #expect(recents.places(in: nil).isEmpty)
    }

    /// The other half of the same symptom. The sidebar is empty for as long as its first
    /// read takes, and filtering the history against an empty sidebar would blank it every
    /// cold launch — exactly when the question it answers is worth most.
    @Test("an empty sidebar filters nothing")
    func emptySidebarDoesNotFilter() {
        let (defaults, suite) = makeSuite()
        defer { forget(suite) }
        let recents = RecentPlaces(defaults: defaults)
        recents.visit(.channel("a"), in: Self.communityA)

        #expect(recents.resolved(among: [], in: Self.communityA).map(\.channelID) == ["a"])
    }

    /// A system symbol that does not exist renders as nothing — no warning, no placeholder.
    /// This is the only thing standing between a renamed SF Symbol and an invisible button.
    @Test("the history symbol exists")
    func symbolExists() {
        // `UIImage(named:)`, because this one is the app's own artwork now. Same guard as
        // before and against the same failure: a name that resolves to nothing draws nothing,
        // silently, and the control keeps its hit area either way — so the only way to see it
        // is to look at the toolbar.
        #expect(UIImage(named: HomeToolbarControls.glyph) != nil)
    }
}
