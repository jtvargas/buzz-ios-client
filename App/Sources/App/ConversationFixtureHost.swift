#if DEBUG
import BuzzKit
import NostrCore
import SwiftUI

/// Opens the real conversation surface on a seeded throwaway store — the launch path
/// ``ConversationFixture`` describes.
///
/// # Why the seeding happens before the first body
///
/// The defect class this exists to catch turns on *when* content arrives relative to layout: a
/// `LazyVStack` rests at the bottom of a height it estimated from the rows it had measured at
/// that instant. So a fixture that seeded asynchronously would be testing its own timing rather
/// than the surface's. ``ConversationFixture/prepare(_:)`` opens and seeds the store
/// synchronously, from this initialiser and therefore before any body runs, which is the state
/// a returning reader opens a cached conversation in.
///
/// ``ConversationFixture/Options/primed`` deliberately breaks that when a shape asks for it:
/// the first `n` messages are seeded up front and the rest land after the first layout, which
/// is a thread whose replies arrive a relay round trip later.
struct ConversationFixtureHost: View {
    private let options: ConversationFixture.Options
    /// The conversation, built once per process — see ``ConversationFixture/prepare(_:)`` for
    /// why "once" is a correctness requirement and not a saving. `nil` only when it threw,
    /// which is the branch that draws the failure view instead of a conversation.
    private let prepared: ConversationFixture.Prepared?
    private let failure: String?

    private let opener = ConversationFixture.InertOpener()
    /// So the composer's `+` can be driven all the way to a thumbnail on a simulator
    /// with no relay in reach — see ``ConversationFixture/InertUploader``.
    private let uploader = ConversationFixture.InertUploader()
    /// Empty and never fed. Presence dots are not what this suite measures, and a real
    /// `PresenceStore` with nothing in it is what a conversation looks like before the roster
    /// answers — a state the app has to render anyway.
    private let presence = PresenceStore()

    init(options: ConversationFixture.Options) {
        self.options = options
        // Both land in locals first: the stored properties are `let`, so a partial success
        // followed by a throw could not reassign them.
        var built: ConversationFixture.Prepared?
        var problem: String?
        do {
            built = try ConversationFixture.prepare(options)
        } catch {
            problem = String(describing: error)
        }
        prepared = built
        failure = problem
    }

    var body: some View {
        Group {
            if let prepared {
                NavigationStack {
                    surface(prepared)
                }
            } else {
                // Surfaced rather than crashed: a fixture that traps reads in CI as a crash in
                // the app, which is the most expensive kind of false report.
                ContentUnavailableView {
                    Label("Fixture failed", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(failure ?? "unknown")
                }
                .accessibilityIdentifier("fixtureFailure")
            }
        }
    }

    @ViewBuilder
    private func surface(_ prepared: ConversationFixture.Prepared) -> some View {
        switch options.surface {
        case .thread:
            ThreadView(
                root: prepared.rootID ?? "",
                channel: ConversationFixture.channelID,
                store: prepared.store,
                sender: prepared.sender,
                opener: opener,
                presence: presence,
                uploader: uploader,
                selfPubkey: nil
            )
        case .channel:
            ChannelTimelineView(
                channel: ChannelListRow(
                    id: ConversationFixture.channelID,
                    name: "Fixture",
                    about: nil,
                    picture: nil,
                    isPrivate: false,
                    lastMessageAt: nil,
                    lastMessageSnippet: nil,
                    lastMessageAuthor: nil
                ),
                store: prepared.store,
                sender: prepared.sender,
                typing: NoopEphemeralPublisher(),
                readStateMarking: nil,
                opener: opener,
                presence: presence,
                uploader: uploader,
                selfPubkey: nil
            )
        }
    }
}
#endif
