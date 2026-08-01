import BuzzKit
import Observation

@MainActor
@Observable
final class ChannelDetailsModel {
    private(set) var members: [MemberProfile] = []
    private(set) var permissions: ChannelLifecyclePermissions = .none
    private(set) var hasLoaded = false
    /// The channel's description, topic and purpose — three different things the relay
    /// keeps separately. Empty until the first store read lands.
    private(set) var context = ChannelContext(description: nil, topic: nil, purpose: nil)
    /// Whether this identity has muted the channel on any device.
    private(set) var isMuted = false
    /// The shared canvas. Fetched once when the sheet opens rather than observed: it is
    /// not projected, so there is nothing local to observe. See ``ChannelCanvas``.
    private(set) var canvas: CanvasState = .loading

    /// What the sheet knows about the canvas. `failed` is its own case rather than an
    /// empty document, because "this channel has no canvas" and "we could not ask" are
    /// different sentences and only one of them invites you to write one.
    enum CanvasState: Equatable {
        case loading
        case loaded(ChannelCanvas?)
        case failed
    }

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
                let context = (try? store.channelContext(channelID))
                    ?? ChannelContext(description: nil, topic: nil, purpose: nil)
                let muted = (try? store.isChannelMuted(channelID)) ?? false
                await apply(rows, permissions: permissions, context: context, muted: muted)
            }
        } catch {
            // Keep the last good roster when the observation is cancelled.
        }
    }

    /// Asks the relay for the canvas. Separate from ``run()`` because it is a network
    /// round trip and not a store observation — a failure here must not cost the sheet
    /// its roster.
    func loadCanvas(using engine: SyncEngine?) async {
        guard let engine else {
            canvas = .failed
            return
        }
        do {
            canvas = .loaded(try await engine.channelCanvas(channelID))
        } catch {
            canvas = .failed
        }
    }

    /// Applies a canvas this device just wrote, so the sheet shows the new text without
    /// a second round trip. The relay is still the record; this is the local echo.
    func applyLocalCanvas(_ content: String, authorPubkey: String, at updatedAt: Int64) {
        canvas = .loaded(ChannelCanvas(
            content: content,
            updatedAt: updatedAt,
            authorPubkey: authorPubkey
        ))
    }

    private func apply(
        _ rows: [MemberProfile],
        permissions: ChannelLifecyclePermissions,
        context: ChannelContext,
        muted: Bool
    ) {
        members = rows
        self.permissions = permissions
        self.context = context
        isMuted = muted
        hasLoaded = true
    }
}
