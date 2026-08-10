import BuzzKit
import Observation
import SwiftUI

/// Which message's reactors are on screen, and which emoji the finger held.
///
/// Identified by the message alone: one hold opens one sheet, and re-identifying it when
/// the held emoji differs would re-present the sheet rather than page it.
struct ReactionReactorsTarget: Identifiable {
    let messageID: String
    /// The chip that was held — the page the sheet opens on. Only the *initial* page:
    /// once open, the reader's swipe owns the selection.
    let emoji: String

    var id: String { messageID }
}

/// Who reacted to one message, read live.
///
/// Live rather than a snapshot taken as the sheet opened, for the reason the chips are
/// live: this is a room, and somebody reacting while the list is open belongs in it. It is
/// also what makes the reader's own reaction appear the instant they send one — the store
/// read folds the outbox in.
@MainActor
@Observable
final class ReactionReactorsModel {
    private(set) var groups: [ReactionReactorGroup] = []
    /// Whether the first read has landed. `false` with no groups means "not yet", which is
    /// a different sentence from "nobody" — the same distinction ``ChannelRosterModel``
    /// draws.
    private(set) var hasLoaded = false

    private let targetID: String
    private let store: BuzzEventStore
    private let selfPubkey: String?

    init(targetID: String, store: BuzzEventStore, selfPubkey: String?) {
        self.targetID = targetID
        self.store = store
        self.selfPubkey = selfPubkey
    }

    nonisolated func run() async {
        do {
            for try await _ in DatabaseSignal.changes(in: store.reader) {
                let groups = (try? store.reactors(for: targetID, selfPubkey: selfPubkey)) ?? []
                await apply(groups)
            }
        } catch {
            // Keep the last good list when the observation is cancelled.
        }
    }

    private func apply(_ groups: [ReactionReactorGroup]) {
        self.groups = groups
        hasLoaded = true
    }
}

/// The reactors on a message: a strip of that message's reactions across the top, and the
/// people behind the selected one below it, swipeable between reactions.
///
/// The list is ``ConversationPeopleList`` — the same one the channel roster and a thread's
/// participants are drawn with — so a reactor's face, name and presence read identically
/// here and everywhere else they appear. The strip is the only new furniture.
struct ReactionReactorsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: ReactionReactorsModel
    @State private var presence: PresenceModel
    @State private var selected: String

    init(
        target: ReactionReactorsTarget,
        store: BuzzEventStore,
        presenceStore: PresenceStore,
        selfPubkey: String?
    ) {
        _model = State(initialValue: ReactionReactorsModel(
            targetID: target.messageID,
            store: store,
            selfPubkey: selfPubkey
        ))
        _presence = State(initialValue: PresenceModel(store: presenceStore))
        _selected = State(initialValue: target.emoji)
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Reactions")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .task { await model.run() }
        .task { await presence.run() }
        // A reaction can be withdrawn while the sheet is open, taking its page with it.
        // Re-pointing at the first surviving emoji is what keeps a `TabView` whose
        // selection no longer names a page from drawing nothing at all.
        .onChange(of: model.groups) { _, groups in
            guard !groups.contains(where: { $0.emoji == selected }) else { return }
            guard let first = groups.first else { return }
            selected = first.emoji
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.groups.isEmpty {
            // Two different sentences, and the sheet was opened *from* a chip — so an empty
            // list here is the last reaction being withdrawn under the reader, not a
            // message that never had one.
            if model.hasLoaded {
                ContentUnavailableView(
                    "No reactions",
                    systemImage: "face.smiling",
                    description: Text("Every reaction on this message has been withdrawn.")
                )
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            TabView(selection: $selected) {
                ForEach(model.groups) { group in
                    ConversationPeopleList(
                        people: group.reactors.map { ConversationPerson(pubkey: $0) },
                        // A page only exists because it has reactors, and the read that
                        // produced it has already landed.
                        isLoading: false,
                        emptyMessage: "Nobody has reacted with this yet.",
                        presence: presence
                    )
                    .tag(group.emoji)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            // The strip is chrome over the list rather than a band above it: a grouped
            // `List` in a sheet draws its own page through the UIKit trait environment,
            // and a ground named out here could only agree with it by luck. `.bar` is the
            // same material a toolbar resolves, so it steps with the sheet it is in.
            // See ``SwiftUI/View/hiveSheetGround()``.
            .safeAreaInset(edge: .top, spacing: 0) { strip }
        }
    }

    /// The message's reactions across the top, the selected one underlined — the tab bar
    /// the swipe below it moves through.
    private var strip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(model.groups) { group in
                        tab(for: group)
                            .id(group.emoji)
                    }
                }
                .padding(.horizontal, 8)
            }
            .scrollIndicators(.hidden)
            // The held chip may be off the end of a message with many reactions. Opening
            // on a page the strip does not show reads as the strip having lost it.
            .onAppear { proxy.scrollTo(selected, anchor: .center) }
            .onChange(of: selected) { _, emoji in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(emoji, anchor: .center) }
            }
        }
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func tab(for group: ReactionReactorGroup) -> some View {
        let isSelected = group.emoji == selected
        return Button {
            selected = group.emoji
        } label: {
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Text(group.emoji)
                        .font(.hive(.body))
                    Text("\(group.count)")
                        .font(.hive(.subheadline, weight: .semibold))
                        .monospacedDigit()
                        // Named concretely rather than as `.primary`, which is the primary
                        // *level of the enclosing foreground style* and so takes the tint
                        // of whatever container this ends up in.
                        .foregroundStyle(isSelected ? Color.hiveAccent : Color.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                Capsule()
                    .fill(isSelected ? Color.hiveAccent : Color.clear)
                    .frame(height: 2)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.hivePress(.control, in: .rect(cornerRadius: 8)))
        .accessibilityLabel("\(group.emoji), \(group.count)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

extension View {
    /// Presents ``ReactionReactorsSheet`` for whichever chip `target` names.
    ///
    /// One modifier rather than a `.sheet` per surface, for the reason
    /// ``messageActionsSheet(target:actions:isReadOnly:onReplyInThread:onRemind:)`` is one:
    /// the channel and a thread open the same sheet from the same hold, and a second copy
    /// is a second place for the two to drift.
    func reactionReactorsSheet(
        target: Binding<ReactionReactorsTarget?>,
        store: BuzzEventStore,
        presenceStore: PresenceStore,
        selfPubkey: String?
    ) -> some View {
        sheet(item: target) { target in
            ReactionReactorsSheet(
                target: target,
                store: store,
                presenceStore: presenceStore,
                selfPubkey: selfPubkey
            )
        }
    }
}
