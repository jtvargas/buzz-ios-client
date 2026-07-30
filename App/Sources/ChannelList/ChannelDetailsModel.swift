import BuzzKit
import Observation

@MainActor
@Observable
final class ChannelDetailsModel {
    private(set) var members: [MemberProfile] = []
    private(set) var permissions: ChannelLifecyclePermissions = .none
    private(set) var hasLoaded = false

    private let channelID: String
    private let store: BuzzEventStore
    private let identity: String?

    init(channelID: String, store: BuzzEventStore, identity: String? = nil) {
        self.channelID = channelID
        self.store = store
        self.identity = identity
    }

    nonisolated func run() async {
        do {
            for try await _ in DatabaseSignal.changes(in: store.reader) {
                let rows = (try? store.channelMembers(channelID)) ?? []
                let permissions = identity.flatMap {
                    try? store.channelLifecyclePermissions(identity: $0, channel: channelID)
                } ?? .none
                await apply(rows, permissions: permissions)
            }
        } catch {
            // Keep the last good roster when the observation is cancelled.
        }
    }

    private func apply(
        _ rows: [MemberProfile],
        permissions: ChannelLifecyclePermissions
    ) {
        members = rows
        self.permissions = permissions
        hasLoaded = true
    }
}
