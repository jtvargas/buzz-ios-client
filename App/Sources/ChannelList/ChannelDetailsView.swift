import BuzzKit
import SwiftUI

/// Slack-style channel information surfaced from the title button: topic,
/// privacy/settings context, and the live member roster.
struct ChannelDetailsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.entityNames) private var names
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

                // The group id is a developer detail, not something a reader should
                // meet in the ordinary UI — it stays, labelled for what it is.
                Section("Developer") {
                    LabeledContent("Channel ID") {
                        Text(channel.id)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle(title)
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

    /// The conversation's own title — a channel's name, or the peer's name when this
    /// two-person roster is a direct message. Never the group id.
    private var title: String {
        names.conversation(for: channel).title
    }

    private var topic: String {
        guard let about = channel.about, !about.isEmpty else { return "No topic set" }
        return about
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
                    .font(.body.weight(.medium))
                if let role, !role.isEmpty {
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
}
