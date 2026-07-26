import BuzzKit
import SwiftUI

/// Slack-style channel information surfaced from the title button: topic,
/// privacy/settings context, and the live member roster.
struct ChannelDetailsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: ChannelDetailsModel
    @State private var presence: PresenceModel
    private let channel: ChannelListRow

    init(channel: ChannelListRow, store: BuzzEventStore, presenceStore: PresenceStore) {
        self.channel = channel
        _model = State(initialValue: ChannelDetailsModel(channelID: channel.id, store: store))
        _presence = State(initialValue: PresenceModel(store: presenceStore))
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Topic") {
                    Text(topic)
                        .foregroundStyle(channel.about?.isEmpty == false ? .primary : .secondary)
                }

                Section("Settings") {
                    LabeledContent("Visibility", value: channel.isPrivate ? "Private" : "Public")
                    LabeledContent("Members", value: "\(model.members.count)")
                    LabeledContent("Channel ID") {
                        Text(channel.id)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Section("Members") {
                    if model.members.isEmpty, !model.hasLoaded {
                        ProgressView()
                    } else if model.members.isEmpty {
                        Text("No members available")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.members, id: \.pubkey) { member in
                            MemberRow(member: member, isOnline: presence.isOnline(member.pubkey))
                        }
                    }
                }
            }
            .navigationTitle(displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await model.run() }
        .task { await presence.run() }
    }

    private var displayName: String {
        if let name = channel.name, !name.isEmpty { return name }
        return channel.id
    }

    private var topic: String {
        guard let about = channel.about, !about.isEmpty else { return "No topic set" }
        return about
    }
}

private struct MemberRow: View {
    let member: MemberProfile
    let isOnline: Bool

    var body: some View {
        HStack(spacing: 10) {
            AvatarView(
                url: member.picture.flatMap(URL.init(string:)),
                seed: member.pubkey,
                initial: String(displayName.prefix(1)).uppercased(),
                size: 32
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(displayName)
                    .font(.body.weight(.medium))
                if let role = member.role, !role.isEmpty {
                    Text(role.capitalized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            PresenceDot(isOnline: isOnline)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(isOnline ? "Online" : "Offline")
    }

    private var displayName: String {
        guard let name = member.displayName, !name.isEmpty else {
            return String(member.pubkey.prefix(8))
        }
        return name
    }
}
