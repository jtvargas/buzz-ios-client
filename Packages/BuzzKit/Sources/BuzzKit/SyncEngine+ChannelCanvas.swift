import Foundation
import NostrCore

/// A channel's canvas: the one shared Markdown document per channel, read on demand
/// and written through the durable outbox.
///
/// **Deliberately not projected.** Every other channel-scoped kind this client reads
/// earns a projection table because something draws it continuously — the timeline,
/// the sidebar, a badge. The canvas is drawn in exactly one place, a sheet somebody
/// opens on purpose, so a one-shot query at that moment costs one round trip and
/// saves a table, a projector branch, a projection-version bump, and a standing
/// subscription that would carry the document into every channel switch.
///
/// The price, stated plainly: the canvas is **not available offline** and a second
/// person's edit is not seen until the sheet is reopened. Both are acceptable for a
/// document read on purpose; neither would be acceptable for a message.
public struct ChannelCanvas: Sendable, Equatable {
    /// The Markdown body. Empty when the channel has a canvas event whose content is
    /// empty — which is how the canvas is cleared, since there is no delete for it.
    public let content: String
    /// When the newest canvas event was written, in unix seconds.
    public let updatedAt: Int64
    /// Who wrote it.
    public let authorPubkey: String

    public init(content: String, updatedAt: Int64, authorPubkey: String) {
        self.content = content
        self.updatedAt = updatedAt
        self.authorPubkey = authorPubkey
    }
}

public extension SyncEngine {
    /// Fetches a channel's canvas, or `nil` when it has never had one.
    ///
    /// `limit: 1` is newest-first at the relay, which is the whole of the "replaceable
    /// by convention" rule: the canvas is an ordinary event kind, so history accretes
    /// and the newest one is the document.
    func channelCanvas(_ channel: String) async throws -> ChannelCanvas? {
        let filter = Filter(kinds: [.canvas], limit: 1, tagQueries: ["h": [channel]])
        let events = try await subscriptions.query([filter])
        // The relay's `limit` is a bound, not an ordering guarantee once a query is
        // merged from more than one source, so pick the newest here rather than trust
        // position 0.
        guard let newest = events.max(by: { lhs, rhs in
            lhs.createdAt == rhs.createdAt ? lhs.id < rhs.id : lhs.createdAt < rhs.createdAt
        }) else { return nil }
        return ChannelCanvas(
            content: newest.content,
            updatedAt: newest.createdAt,
            authorPubkey: newest.pubkey
        )
    }

    /// Replaces a channel's canvas.
    ///
    /// Rides the outbox like every other write, so it survives a relaunch and retries
    /// on its own. The `h` tag is mandatory — the relay refuses a canvas that names no
    /// channel — and is the only tag the document needs.
    func setChannelCanvas(_ channel: String, content: String) async throws {
        _ = try await store.enqueue(
            kind: .canvas,
            content: content,
            in: channel,
            tags: [["h", channel]],
            with: signer
        )
        await drainOutbox()
    }
}
