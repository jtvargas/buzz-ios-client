#if DEBUG
import Foundation
import SwiftUI

/// The new-direct-message sheet, opened straight from a launch argument on a roster made up
/// here, so it can be *looked at* on a simulator with no relay in reach.
///
/// # Why this exists rather than a screenshot from the real sidebar
///
/// The sidebar cannot be fixtured: ``ChannelListView`` takes a concrete `SyncEngine` and reads
/// ``AppEnvironment`` from the environment, so standing one up means standing up a socket —
/// which is exactly what ``ConversationFixture`` was built to avoid. The sheet is the opposite
/// shape: its whole input is `[DirectMessagePerson]`, a plain array of values. So the surface
/// under the screenshot here is the shipping view, unmodified, and only the people are made up.
///
/// `-fixtureNewDirectMessage chosen` opens it with three people already picked.
///
/// Compiled out of release entirely, like the conversation fixture beside it.
enum DirectMessagePickerFixture {
    /// The three states worth looking at before this reaches a phone.
    enum State: String, CaseIterable {
        /// Nothing typed: the whole roster, in its resting order.
        case resting
        /// Mid-search, so the ranking is visible rather than described.
        case filtered
        /// Three people picked, which is the only state that draws the chips and the count.
        case chosen
    }

    /// The state a launch asked for, or `nil` for an ordinary launch.
    static var requested: State? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "-fixtureNewDirectMessage"),
              arguments.indices.contains(flag + 1) else { return nil }
        return State(rawValue: arguments[flag + 1])
    }

    /// Made-up people, fixed so a screenshot is the same on every run: a few with a NIP-05, a
    /// couple of agents, and one identity the directory has seen but nobody has named — the
    /// four kinds of row the list has to draw.
    static let roster: [DirectMessagePerson] = [
        person(0x11, "Ada Lovelace", secondary: "ada@buzz.dev"),
        person(0x22, "Jarvis", secondary: "Agent", isAgent: true),
        person(0x33, "Bo Jordan", secondary: "bo@buzz.dev"),
        person(0x44, "Duncan Reed"),
        person(0x55, "Fizz", secondary: "Agent", isAgent: true),
        person(0x66, "Grace Hopper", secondary: "grace@buzz.dev"),
        person(0x77, "Jamie Okafor"),
        person(0x88, "James Whitfield", secondary: "jw@buzz.dev"),
        person(0x99, "Priya Raman"),
        person(0xAA, "Will Pfleger"),
        person(0xBB, "npub1qqqqqq…qqqq", isNamed: false),
    ]

    private static func person(
        _ byte: UInt8,
        _ name: String,
        secondary: String? = nil,
        isAgent: Bool = false,
        isNamed: Bool = true
    ) -> DirectMessagePerson {
        DirectMessagePerson(
            pubkey: String(repeating: String(format: "%02x", byte), count: 32),
            name: name,
            secondary: secondary,
            initials: EntityNames.initials(from: isNamed ? name : nil),
            isAgent: isAgent,
            isNamed: isNamed
        )
    }
}

extension DirectMessagePicker {
    /// The picker in one of the three states worth looking at. Shared by the fixture launch
    /// and the sheet's own previews so the two show the same thing.
    static func preview(_ state: DirectMessagePickerFixture.State) -> DirectMessagePicker {
        var picker = DirectMessagePicker(
            people: DirectMessagePickerFixture.roster,
            maxSelection: relayPeerLimit
        )
        switch state {
        case .resting:
            break
        case .filtered:
            picker.query = "ja"
        case .chosen:
            for person in DirectMessagePickerFixture.roster.prefix(3) {
                picker.toggle(person.pubkey)
            }
        }
        return picker
    }
}

/// Presents the sheet the way the sidebar does — modally, over the app's ground — so what is
/// screenshotted is the card a reader actually sees rather than a full-screen view of its
/// contents.
struct DirectMessagePickerFixtureHost: View {
    let state: DirectMessagePickerFixture.State

    var body: some View {
        Color.hiveNight
            .ignoresSafeArea()
            .sheet(isPresented: .constant(true)) {
                NewDirectMessageSheet(picker: .preview(state)) { _ in }
            }
    }
}
#endif
