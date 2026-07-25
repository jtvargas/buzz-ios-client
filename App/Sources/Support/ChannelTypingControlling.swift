import BuzzKit
import NostrCore

/// Opening and closing a channel's typing subscription — the narrow slice of
/// ``SyncEngine`` a visible channel drives so it actually receives typing (measured
/// relay fact: h-tagged typing is fanned out only to a subscription carrying the
/// matching `#h`, which the global content filter lacks).
///
/// Behind a protocol so the timeline model can bracket its observation with
/// open/close against a scripted control in tests, and so the model depends on an
/// intent rather than the whole engine actor. ``SyncEngine`` exposes exactly these
/// two methods, so the conformance is free.
protocol ChannelTypingControlling: Sendable {
    @discardableResult
    func openChannelTyping(_ channel: String) async throws -> SubscriptionID

    func closeChannelTyping(_ channel: String) async
}

extension SyncEngine: ChannelTypingControlling {}
