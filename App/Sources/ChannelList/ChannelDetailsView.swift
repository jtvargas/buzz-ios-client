import BuzzKit
import SwiftUI

/// The details sheet behind a conversation's title.
///
/// It reads as whatever the conversation *is* (§4/§8): a channel gets Slack's topic,
/// settings, and roster; a direct message gets the person — their avatar, their name,
/// and what they are (a NIP-05 identifier, or "Agent") — because a two-person roster
/// and a "Visibility: Private" row tell a reader nothing they did not already know.
struct ChannelDetailsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.entityNames) private var names
    @State private var model: ChannelDetailsModel
    @State private var presence: PresenceModel
    @State private var confirmsArchive = false
    @State private var confirmsDelete = false
    @State private var operationError: String?
    @State private var isMutating = false
    /// Pushed on this sheet's own stack, never presented as a second sheet: a modal
    /// presented from inside a modal races the first one's dismissal (see Part 13).
    @State private var isEditingCanvas = false
    @State private var canvasDraft = ""
    private let channel: ChannelListRow
    private let engine: SyncEngine?
    private let selfPubkey: String?

    init(
        channel: ChannelListRow,
        store: BuzzEventStore,
        presenceStore: PresenceStore,
        engine: SyncEngine? = nil,
        selfPubkey: String? = nil
    ) {
        self.channel = channel
        self.engine = engine
        self.selfPubkey = selfPubkey
        _model = State(initialValue: ChannelDetailsModel(
            channelID: channel.id,
            store: store,
            identity: selfPubkey
        ))
        _presence = State(initialValue: PresenceModel(store: presenceStore))
    }

    var body: some View {
        let conversation = names.conversation(for: channel)

        return NavigationStack {
            List {
                // `isOneToOne`, not `isDirect`: a group DM has no peer to put a face, a
                // presence dot, or a profile link under, and the channel sections — its
                // member list above all — are exactly what it wants instead.
                if conversation.isOneToOne {
                    peerSection(conversation)
                    // Mute is the one management control a direct message has: it has no
                    // topic to set, no roster to manage and no canvas to share, but it can
                    // certainly be something you would rather not be told about.
                    muteSection
                } else {
                    channelSections
                }
                // The group id is a developer detail, not something a reader should
                // meet in the ordinary UI — it stays, labelled for what it is.
                Section("Developer") {
                    LabeledContent("Channel ID") {
                        Text(channel.id)
                            .font(.hiveMono(.caption))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle(conversation.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(isPresented: $isEditingCanvas) {
                ChannelCanvasEditor(text: $canvasDraft, onSave: saveCanvas)
            }
        }
        .task { await model.run() }
        .task { await presence.run() }
        // Only where a canvas can be drawn. A direct message has no shared document and
        // renders no canvas section, so fetching one there would be a relay round trip for
        // something this sheet has already decided not to show.
        .task {
            guard !channel.isDirectMessage else { return }
            await model.loadCanvas(using: engine)
        }
        .confirmationDialog(
            "Archive Channel?",
            isPresented: $confirmsArchive,
            titleVisibility: .visible
        ) {
            Button("Archive Channel", role: .destructive) { archive() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "The channel will disappear from this app. Restoring it requires Desktop or CLI because this release has no archived-channel browser."
            )
        }
        .confirmationDialog(
            "Delete Channel Permanently?",
            isPresented: $confirmsDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Channel", role: .destructive) {
                // Archive, beside this, plays nothing: it is reversible, and the one
                // two-beat feedback in the app is reserved for what is not.
                HiveHaptics.play(.delete)
                delete()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone. Cached history will remain read-only on this device.")
        }
        .alert(
            "Couldn’t Update Channel",
            isPresented: Binding(
                get: { operationError != nil },
                set: { if !$0 { operationError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(operationError ?? "")
        }
    }
}

// MARK: - Direct messages

private extension ChannelDetailsView {
    /// A DM's header: the peer, large. No visibility row (a DM is private by
    /// definition), no member list (it is the two of you).
    @ViewBuilder
    func peerSection(_ conversation: ConversationIdentity) -> some View {
        Section {
            VStack(spacing: 8) {
                AvatarView(
                    url: conversation.picture,
                    seed: conversation.avatarSeed,
                    monogram: conversation.initials,
                    size: 76
                )
                Text(conversation.title)
                    .font(.hive(.title3, weight: .semibold))
                if let subtitle = peerSubtitle(conversation) {
                    Text(subtitle)
                        .font(.hive(.subheadline))
                        .foregroundStyle(.secondary)
                }
                if let peer = conversation.peer {
                    Label(
                        presence.isOnline(peer) ? "Online" : "Offline",
                        systemImage: presence.isOnline(peer) ? "circle.fill" : "circle"
                    )
                    .font(.hive(.caption))
                    .foregroundStyle(presence.isOnline(peer) ? .green : .secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
        }
        .listRowBackground(Color.clear)
    }

    /// What the peer *is*: their NIP-05 identifier, or "Agent" when that is all the
    /// directory knows. Never a raw key.
    func peerSubtitle(_ conversation: ConversationIdentity) -> String? {
        guard let peer = conversation.peer else { return nil }
        if let label = names.secondaryLabel(for: peer) { return label }
        return conversation.kind == .agent ? "Agent" : nil
    }
}

// MARK: - Channels

private extension ChannelDetailsView {
    @ViewBuilder
    var channelSections: some View {
        muteSection

        Section("Context") {
            contextRow("Description", model.context.description)
            contextRow("Topic", model.context.topic)
            contextRow("Purpose", model.context.purpose)
        }

        canvasSection

        Section("Settings") {
            LabeledContent("Visibility", value: channel.isPrivate ? "Private" : "Public")
            membersLink
        }

        if engine != nil, model.permissions.canArchive || model.permissions.canDelete {
            Section("Management") {
                if model.permissions.canArchive {
                    Button("Archive Channel", systemImage: "archivebox") {
                        confirmsArchive = true
                    }
                    .disabled(isMutating)
                }
                if model.permissions.canDelete {
                    Button("Delete Channel", systemImage: "trash", role: .destructive) {
                        confirmsDelete = true
                    }
                    .disabled(isMutating)
                }
            }
        }
    }

    /// The roster, one push away rather than spelled out here.
    ///
    /// The same ``ConversationPeopleList`` the `person.3.fill` button in the navigation bar
    /// opens, not a second copy: one list of who is in a room, reachable from wherever a
    /// reader thinks to look for it. Inlining it under this sheet's other six sections was
    /// what made the sheet long enough that the management controls fell off the bottom of
    /// a phone.
    @ViewBuilder
    var membersLink: some View {
        NavigationLink {
            ConversationPeopleList(
                people: model.members.map(ConversationPerson.init(member:)),
                isLoading: !model.hasLoaded,
                emptyMessage: "No members available",
                presence: presence
            )
            .navigationTitle("Members")
            .navigationBarTitleDisplayMode(.inline)
        } label: {
            LabeledContent("Members", value: "\(model.members.count)")
        }
    }

    /// The mute toggle. Its own section so the switch is not read as one more fact about
    /// the channel: everything else on this sheet describes the room, and this is the one
    /// row that changes what the room does to you.
    ///
    /// Offered without an engine too — disabled — rather than hidden, so the sheet does
    /// not silently lose a control depending on how it was opened.
    @ViewBuilder
    var muteSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { model.isMuted },
                set: { setMuted($0) }
            )) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Mute conversation")
                        Text("Suppress its unread badge")
                            .font(.hive(.caption))
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: model.isMuted ? "bell.slash" : "bell")
                }
            }
            .disabled(engine == nil)
        }
    }

    /// One `Context` row. All three are drawn whether or not they are set, matching the
    /// other Buzz clients: on a *management* sheet, "no purpose set" is information —
    /// it is the difference between a channel nobody has described and one you are
    /// looking at the wrong way.
    @ViewBuilder
    func contextRow(_ label: String, _ value: String?) -> some View {
        let text = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.hive(.caption, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(text.isEmpty ? "Not set" : text)
                .font(.hive(.body))
                .foregroundStyle(text.isEmpty ? .secondary : .primary)
        }
        .accessibilityElement(children: .combine)
    }

    /// The shared document. Hidden for a direct message, which has no shared document
    /// to speak of — the other clients hide it there too.
    @ViewBuilder
    var canvasSection: some View {
        if !channel.isDirectMessage {
            Section("Canvas") {
                switch model.canvas {
                case .loading:
                    ProgressView()
                case .failed:
                    Text("Couldn’t load the canvas.")
                        .foregroundStyle(.secondary)
                case let .loaded(canvas):
                    canvasBody(canvas)
                }
            }
        }
    }

    @ViewBuilder
    func canvasBody(_ canvas: ChannelCanvas?) -> some View {
        let body = canvas?.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        Text(body.isEmpty ? "No canvas set for this channel." : body)
            .font(.hive(.body))
            .foregroundStyle(body.isEmpty ? .secondary : .primary)
            // Enough to recognise the document without turning the sheet into it. The
            // editor is where the whole thing lives.
            .lineLimit(8)
        if engine != nil {
            Button(body.isEmpty ? "Create Canvas" : "Edit Canvas", systemImage: "square.and.pencil") {
                canvasDraft = canvas?.content ?? ""
                isEditingCanvas = true
            }
        }
    }

    func setMuted(_ muted: Bool) {
        guard let engine else { return }
        Task { await engine.setChannelMuted(channel.id, muted: muted) }
    }

    /// Queues the edited canvas and pops back to the sheet.
    ///
    /// **The echo is not a relay confirmation.** The write rides the durable outbox like
    /// every other publish in this app, so what `try` can report is that the event was
    /// signed and queued — not that the relay took it. That is the same bargain a sent
    /// message makes here, and it is the right one for a document somebody just typed: a
    /// canvas written on a train must not vanish when the editor closes.
    ///
    /// The cost, and it is real: a canvas the relay *refuses* still shows here until the
    /// sheet is reopened, because the canvas is not projected and so has no observation to
    /// correct it from. Nobody has yet watched this relay accept a kind 40100 from this
    /// client — see the PR.
    func saveCanvas() {
        guard let engine else { return }
        let content = canvasDraft
        isMutating = true
        Task {
            do {
                try await engine.setChannelCanvas(channel.id, content: content)
                model.applyLocalCanvas(
                    content,
                    authorPubkey: selfPubkey ?? "",
                    at: Int64(Date().timeIntervalSince1970)
                )
                isEditingCanvas = false
            } catch {
                operationError = String(describing: error)
            }
            isMutating = false
        }
    }

    func archive() {
        guard let engine else { return }
        isMutating = true
        Task {
            do {
                try await engine.archiveChannel(id: channel.id)
                dismiss()
            } catch {
                operationError = lifecycleMessage(error)
            }
            isMutating = false
        }
    }

    func delete() {
        guard let engine else { return }
        isMutating = true
        Task {
            do {
                try await engine.deleteChannel(id: channel.id)
                dismiss()
            } catch {
                operationError = lifecycleMessage(error)
            }
            isMutating = false
        }
    }

    func lifecycleMessage(_ error: any Error) -> String {
        switch error {
        case ChannelLifecycleError.noIdentity:
            "No signed-in identity is available."
        case let ChannelLifecycleError.rejected(reason):
            String(describing: reason)
        case let ChannelLifecycleError.publishFailed(failure):
            String(describing: failure)
        default:
            String(describing: error)
        }
    }
}
