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

    /// Desktop's `deriveCommunityName`, case for case, as a table.
    ///
    /// The table *is* the contract, and it is the reason this is a table rather than a few
    /// assertions: a Hive install is paired to a Desktop pointed at the same relay, so the
    /// two screens have to land on the same string or they report a disagreement that does
    /// not exist. Every expectation below was read off Desktop
    /// (`buzz/desktop/src/features/communities/communityStorage.ts:130`) rather than off
    /// Hive's implementation, and each names the branch of that function it pins — so this
    /// fails if either side is edited alone.
    ///
    /// Nothing here asks the relay anything. The name used to come from NIP-11, which cannot
    /// answer it: every Buzz relay serves the same hardcoded `"Buzz Relay"` on purpose
    /// (see ``CommunityIdentity``), which is the bug this table replaced.
    @Test("the community name is derived from the relay host exactly as Buzz Desktop derives it")
    func derivedNameMatchesDesktop() {
        let cases: [(relay: String, name: String)] = [
            // The prefilled tailnet relay: the first label, left lowercase. `Homelab` is the
            // nicer heading and was removed anyway — it is a difference the owner can see
            // between the phone in their hand and the laptop in front of them.
            ("wss://homelab.tail4bc643.ts.net", "homelab"),
            // Hosts are case-insensitive and WHATWG lowercases while parsing, where
            // Foundation hands the host back as typed. Normalised, so capitals still agree.
            ("wss://Homelab.Tail4bc643.TS.NET", "homelab"),
            // `relay` names the machine rather than the community, so the label after it is
            // the one an operator actually chose.
            ("wss://relay.acme.com", "acme"),
            ("ws://relay.example.com:3004", "example"),
            // Still "the first label", which for a bare two-label domain is the domain.
            ("wss://example.com", "example"),
            // A single-label LAN host resolved through a search domain: nothing to take.
            ("wss://myrelay", "myrelay"),
            // Desktop's staging sniff scans *every* label and runs before the subdomain is
            // taken, so it beats the `relay` skip above rather than combining with it.
            ("wss://buzz-oss.stage.blox.sqprod.co", "Buzz (staging)"),
            ("wss://relay.staging.example.com", "Buzz (staging)"),
            // Crude, and copied without improvement: an IP relay yields its first octet,
            // because `10` is the string on the laptop's screen.
            ("ws://10.0.0.2:3004", "10"),
            ("ws://localhost:3004", "Local Dev"),
            ("ws://127.0.0.1:3004", "Local Dev"),
            ("ws://0.0.0.0:3004", "Local Dev"),
            // The one entry Desktop's literal list cannot express on this platform:
            // `URL.hostname` keeps an IPv6 literal's brackets and `URL.host()` strips them,
            // so copying Desktop's `[::1]` alone would silently never fire here.
            ("ws://[::1]:3004", "Local Dev"),
        ]
        for (relay, name) in cases {
            #expect(CommunityIdentity.name(forRelay: relay) == name, "\(relay)")
        }
    }

    @Test("a relay URL this app could never have connected to is called what Desktop calls one")
    func unusableRelayURLIsTheDefaultName() {
        // Desktop's `catch` arm, reached here through the same validation the identity gate
        // applies. Not "Buzz" and not the app's name: `Community` is Desktop's word for it.
        for relay in ["not a url", "", "   ", "wss://", "://nope"] {
            #expect(CommunityIdentity.name(forRelay: relay) == CommunityIdentity.defaultName, "[\(relay)]")
        }
        #expect(CommunityIdentity.defaultName == "Community")

        // One narrowing, deliberate and unreachable in practice: Desktop's own parser accepts
        // an `https://` URL and would read `example` out of this, because it only rewrites
        // `ws`/`wss` and leaves anything else alone. Hive derives from `relay.websocketURL`,
        // and all three writers of that key — `submitIdentity`, `createIdentity`, and the
        // NIP-AB importer — put the string through `RelayEndpoint.websocketURL(from:)` or
        // `websocketURLString(fromAnyRelay:)` first. So a stored `https://` relay is not a
        // state that exists, and answering `Community` is honest about a URL we never held
        // rather than guessing a name for one.
        #expect(CommunityIdentity.name(forRelay: "https://example.com") == CommunityIdentity.defaultName)
    }

    @Test("the name is bounded, because VoiceOver reads the whole of it")
    func nameIsBounded() {
        // The heading truncates by width; the accessibility label it becomes does not. A DNS
        // label may be 63 characters, so this is reachable without anyone being hostile.
        let long = String(repeating: "a", count: 63)
        let capped = CommunityIdentity.name(forRelay: "wss://\(long).example.com")
        #expect(capped.count == 61)
        #expect(capped.hasSuffix("\u{2026}"))

        // Under the bound nothing is added, so nothing is claimed to have been cut — and the
        // bound is the only step Desktop has no counterpart for, so it must not fire on the
        // names either client will really show.
        #expect(CommunityIdentity.sanitised("Buzz") == "Buzz")
        #expect(CommunityIdentity.sanitised("   ") == nil)
    }
}
