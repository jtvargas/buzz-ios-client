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
    private let channel: ChannelListRow
    private let engine: SyncEngine?

    init(
        channel: ChannelListRow,
        store: BuzzEventStore,
        presenceStore: PresenceStore,
        engine: SyncEngine? = nil,
        selfPubkey: String? = nil
    ) {
        self.channel = channel
        self.engine = engine
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
                    // A DM has no topic to set, so the section appears only when one
                    // somehow exists rather than as an empty placeholder.
                    if !topic.isEmpty {
                        Section("Topic") { Text(topic) }
                    }
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
        }
        .task { await model.run() }
        .task { await presence.run() }
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
        Section("Topic") {
            Text(topic.isEmpty ? "No topic set" : topic)
                .foregroundStyle(topic.isEmpty ? .secondary : .primary)
        }

        Section("Settings") {
            LabeledContent("Visibility", value: channel.isPrivate ? "Private" : "Public")
            LabeledContent("Members", value: "\(model.members.count)")
        }

        Section("Members") {
            if model.members.isEmpty, !model.hasLoaded {
                ProgressView()
            } else if model.members.isEmpty {
                Text("No members available")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.members, id: \.pubkey) { member in
                    MemberRow(
                        pubkey: member.pubkey,
                        name: names.name(for: member.pubkey),
                        picture: names.picture(for: member.pubkey) ?? member.picture
                            .flatMap(URL.init(string:)),
                        initials: names.initials(for: member.pubkey),
                        role: member.role,
                        isOnline: presence.isOnline(member.pubkey)
                    )
                }
            }
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

    var topic: String {
        channel.about?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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

/// One roster row, named and pictured through the shared directory rather than from
/// the roster's own raw fields, so a member reads the same here as in the timeline.
private struct MemberRow: View {
    let pubkey: String
    let name: String
    let picture: URL?
    let initials: String
    let role: String?
    let isOnline: Bool

    var body: some View {
        HStack(spacing: 10) {
            AvatarView(url: picture, seed: pubkey, monogram: initials, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.hive(.body, weight: .medium))
                if let role, !role.isEmpty {
                    Text(role.capitalized)
                        .font(.hive(.caption))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            PresenceDot(isOnline: isOnline)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(isOnline ? "Online" : "Offline")
    }
}
