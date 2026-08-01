import BuzzKit
import Observation
import SwiftUI

/// Who is in this conversation, behind the `person.3.fill` button in the navigation bar.
///
/// Two sources, and they are genuinely different questions rather than one query with a
/// filter. A **channel** asks its roster: the relay-signed membership, which includes the
/// people who have never said a word — being in the room is the fact, not having spoken.
/// A **thread** has no roster at all; a thread is not something you are a member of, so
/// the only honest answer is whoever has spoken in it, which the surface already holds and
/// this sheet is handed.
struct ConversationPeopleSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// Live for a channel, `nil` for a thread — a thread's people are a fact about the rows
    /// on screen, so there is nothing to observe that the pushing surface is not already
    /// observing.
    @State private var roster: ChannelRosterModel?
    @State private var presence: PresenceModel
    private let participants: [ConversationPerson]
    private let title: String
    private let emptyMessage: String

    /// A channel's roster, read live so somebody joining while the sheet is open appears.
    init(channel: String, store: BuzzEventStore, presenceStore: PresenceStore) {
        _roster = State(initialValue: ChannelRosterModel(channelID: channel, store: store))
        _presence = State(initialValue: PresenceModel(store: presenceStore))
        participants = []
        title = "Members"
        emptyMessage = "No members available"
    }

    /// A thread's participants, as the thread's own rows report them.
    init(threadParticipants: [ConversationPerson], presenceStore: PresenceStore) {
        _roster = State(initialValue: nil)
        _presence = State(initialValue: PresenceModel(store: presenceStore))
        participants = threadParticipants
        title = "In This Thread"
        emptyMessage = "Nobody has replied yet."
    }

    var body: some View {
        NavigationStack {
            ConversationPeopleList(
                people: roster?.people ?? participants,
                // A thread's people are never "still loading": they are derived from rows
                // the reader is already looking at.
                isLoading: roster.map { !$0.hasLoaded } ?? false,
                emptyMessage: emptyMessage,
                presence: presence
            )
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        // Resting medium so the conversation stays visible behind it — this sheet answers
        // a question *about* what is on screen — and draggable to large because a busy
        // channel's roster is longer than half a phone. JT's dial if medium reads as
        // cramped; pinning to large is one word.
        .presentationDetents([.medium, .large])
        .task { await presence.run() }
        .task { await roster?.run() }
    }
}

/// A channel's roster, observed.
///
/// Its own model rather than a reuse of ``ChannelDetailsModel``: that one also reads
/// permissions, context, mutes and the canvas, and a sheet that only lists people should
/// not open a network round trip for a document nothing on it draws.
@MainActor
@Observable
final class ChannelRosterModel {
    private(set) var people: [ConversationPerson] = []
    /// Whether the first read has landed. `false` with an empty list means "not yet",
    /// which is a different sentence from "nobody".
    private(set) var hasLoaded = false

    private let channelID: String
    private let store: BuzzEventStore

    init(channelID: String, store: BuzzEventStore) {
        self.channelID = channelID
        self.store = store
    }

    nonisolated func run() async {
        do {
            for try await _ in DatabaseSignal.changes(in: store.reader) {
                let rows = (try? store.channelMembers(channelID)) ?? []
                await apply(rows.map(ConversationPerson.init(member:)))
            }
        } catch {
            // Keep the last good roster when the observation is cancelled.
        }
    }

    private func apply(_ rows: [ConversationPerson]) {
        people = rows
        hasLoaded = true
    }
}
