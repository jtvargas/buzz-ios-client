@testable import Hive
import Foundation
import Testing
import UIKit

/// Part 7's navigation shell: the two tabs, and the name over the home screen.
@Suite("Home navigation", .timeLimit(.minutes(1)))
struct HomeNavigationTests {
    // MARK: - Tabs

    @Test("the selected tab is filled and the others are not")
    func selectedTabIsFilled() {
        #expect(HomeTab.home.symbol(isSelected: false) == "house")
        #expect(HomeTab.home.symbol(isSelected: true) == "house.fill")
        #expect(HomeTab.activity.symbol(isSelected: false) == "bell")
        #expect(HomeTab.activity.symbol(isSelected: true) == "bell.fill")
    }

    @Test("every symbol either tab can draw exists on this system")
    func tabSymbolsExist() {
        // A `.fill` variant that does not exist renders as nothing at all, silently — the
        // trap ``ThreadView/threadSymbol`` is pinned against, and one a derived name is
        // especially exposed to.
        for tab in HomeTab.allCases {
            for selected in [true, false] {
                let symbol = tab.symbol(isSelected: selected)
                #expect(UIImage(systemName: symbol) != nil, "\(symbol) is missing")
            }
        }
        #expect(UIImage(systemName: ActivityView.symbol) != nil)
        #expect(UIImage(systemName: ChannelListView.communitySymbol) != nil)
    }

    // MARK: - What the workspace is called

    @Test("the relay's own NIP-11 name is the community's name")
    func nameComesFromTheInformationDocument() throws {
        // A real answer from JT's relay, trimmed to the fields this reads.
        let document = Data(#"{"name":"Buzz Relay","description":"private team relay"}"#.utf8)
        #expect(CommunityIdentity.name(fromInformationDocument: document) == "Buzz Relay")

        // A document without a name, an empty name, and something that is not a document
        // at all: all three leave the current name alone rather than blanking the heading.
        #expect(CommunityIdentity.name(fromInformationDocument: Data(#"{"description":"x"}"#.utf8)) == nil)
        #expect(CommunityIdentity.name(fromInformationDocument: Data(#"{"name":"   "}"#.utf8)) == nil)
        #expect(CommunityIdentity.name(fromInformationDocument: Data("not json".utf8)) == nil)

        // Bounded: the string becomes an accessibility label, and a relay is free to
        // advertise a paragraph.
        let long = String(repeating: "a", count: 200)
        let capped = try #require(
            CommunityIdentity.name(fromInformationDocument: Data(#"{"name":"\#(long)"}"#.utf8))
        )
        #expect(capped.count == 61)
        #expect(capped.hasSuffix("\u{2026}"))
    }

    @Test("with no answer from the relay, its own host stands in")
    func fallbackNameIsTheRelayHost() {
        #expect(CommunityIdentity.fallbackName(forRelay: "wss://homelab.tail4bc643.ts.net") == "Homelab")
        #expect(CommunityIdentity.fallbackName(forRelay: "ws://relay.example.com:3004") == "Relay")
        // Not a relay URL at all — there is nothing true to derive, so the app's own name.
        #expect(CommunityIdentity.fallbackName(forRelay: "not a url") == CommunityIdentity.defaultName)
        #expect(CommunityIdentity.fallbackName(forRelay: "https://example.com") == CommunityIdentity.defaultName)
    }

    @Test("the document is asked for at the relay's own origin, over HTTP")
    func informationURL() {
        #expect(CommunityIdentity.informationURL(forRelay: "wss://homelab.tail4bc643.ts.net")?.absoluteString
            == "https://homelab.tail4bc643.ts.net")
        #expect(CommunityIdentity.informationURL(forRelay: "ws://10.0.0.2:3004")?.absoluteString
            == "http://10.0.0.2:3004")
        // The socket may carry a path; the document does not live under it.
        #expect(CommunityIdentity.informationURL(forRelay: "wss://example.com/socket")?.absoluteString
            == "https://example.com")
        #expect(CommunityIdentity.informationURL(forRelay: "nonsense") == nil)
    }

    @Test("the heading draws a name before the relay answers, and the answer replaces it")
    @MainActor
    func communityNameResolves() async throws {
        let suiteName = "community-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = CommunityModel(
            relayURLString: "wss://homelab.tail4bc643.ts.net",
            defaults: defaults,
            load: { _ in Data(#"{"name":"Buzz Relay"}"#.utf8) }
        )
        // Nothing cached and nothing fetched yet: the host stands in from the first frame,
        // rather than the heading being empty or saying "Loading".
        #expect(model.name == "Homelab")

        await model.run()
        #expect(model.name == "Buzz Relay")

        // The next launch draws the real name immediately — and keeps drawing it when the
        // relay is unreachable, which for a tailnet relay is most of the time off-tailnet.
        let unreachable = CommunityModel(
            relayURLString: "wss://homelab.tail4bc643.ts.net",
            defaults: defaults,
            load: { _ in nil }
        )
        #expect(unreachable.name == "Buzz Relay")
        await unreachable.run()
        #expect(unreachable.name == "Buzz Relay")

        // Pinned: renaming the key costs every install its cached name.
        #expect(CommunityIdentity.storageKey == "relay.communityName")
    }
}
