import Foundation
import NostrCore

public enum ChannelLifecycleError: Error, Equatable, Sendable {
    case noIdentity
    case rejected(OKReason)
    case publishFailed(RelayConnectionError)
}

public extension SyncEngine {
    /// Archives a channel through the NIP-29 metadata-edit command. This is
    /// intentionally kind 9002, not the identity archive kinds 9035/9036.
    func archiveChannel(id channelID: String) async throws {
        try await publishLifecycleCommand(
            kind: .groupEditMetadata,
            channelID: channelID,
            tags: [["h", channelID], ["archived", "true"]],
            acceptedState: .archived
        )
    }

    /// Permanently deletes a channel through kind 9008.
    func deleteChannel(id channelID: String) async throws {
        try await publishLifecycleCommand(
            kind: .groupDelete,
            channelID: channelID,
            tags: [["h", channelID]],
            acceptedState: .deleted
        )
    }
}

extension SyncEngine {
    func signLifecycleCommand(
        kind: EventKind,
        tags: [[String]]
    ) async throws -> NostrEvent {
        try await signer.sign(kind: kind, content: "", tags: tags, createdAt: now())
    }

    private func publishLifecycleCommand(
        kind: EventKind,
        channelID: String,
        tags: [[String]],
        acceptedState: ChannelAccessState
    ) async throws {
        guard let identity = selfPubkeyHex else {
            throw ChannelLifecycleError.noIdentity
        }
        let event = try await signLifecycleCommand(kind: kind, tags: tags)
        do {
            _ = try await connection.publishAwaitingResponse(event)
        } catch RelayConnectionError.publishRejected(let reason) {
            throw ChannelLifecycleError.rejected(reason)
        } catch let error as RelayConnectionError {
            throw ChannelLifecycleError.publishFailed(error)
        }

        // The OK is the authorization boundary. Do not optimistically hide a
        // channel before the relay accepts the command.
        try await store.markChannelAccess(
            identity: identity,
            channel: channelID,
            state: acceptedState
        )
        await unsubscribeChannelContent(channelID)
        channelStates.removeValue(forKey: channelID)
        requestDirectoryRefresh()
    }
}
