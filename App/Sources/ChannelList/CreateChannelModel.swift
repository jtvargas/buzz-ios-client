import BuzzKit
import NostrCore
import Observation

/// What the app needs from the engine to make a channel.
///
/// A protocol for the same reason ``DirectMessageOpening`` is one: the substance here is
/// the states *around* the call — in flight, refused, created — and a stub is how those
/// are asserted without a relay. Not main-actor isolated, because `SyncEngine` is an
/// actor and an actor cannot conform to a globally isolated protocol.
protocol ChannelCreating: Sendable {
    /// Creates a channel and returns its id.
    func createChannel(name: String, about: String?, isPrivate: Bool) async throws -> String
}

extension SyncEngine: ChannelCreating {}

/// Drives ``CreateChannelSheet``: the three fields, whether they may be submitted, and
/// what came back.
///
/// A model rather than `@State` in the sheet because the interesting part of a create is
/// not the form — it is the round trip: the guard that stops a second tap becoming a
/// second channel, the refusal turned into a sentence, and the id the sheet hands back.
/// None of that is assertable inside a view body.
@MainActor
@Observable
final class CreateChannelModel {
    var name = ""
    var about = ""
    var isPrivate = false
    /// True from the moment Create is pressed until the relay answers.
    private(set) var isSubmitting = false
    /// The last refusal, in words, or `nil`. Cleared when a new attempt starts.
    private(set) var failure: String?
    /// The created channel's id, once there is one. The sheet reports it and dismisses.
    private(set) var created: String?

    private let engine: any ChannelCreating

    init(engine: any ChannelCreating) {
        self.engine = engine
    }

    /// Whether Create is live: a name that survives canonicalisation, and no attempt
    /// already in flight.
    ///
    /// Asked of BuzzKit rather than re-implemented here, so `#` and `"   "` are refused
    /// by the same rule that will name the channel.
    var canSubmit: Bool {
        !isSubmitting && !SyncEngine.canonicalChannelName(name).isEmpty
    }

    /// Publishes the create and records what came back.
    ///
    /// The in-flight guard is the whole reason this is `async` and not fire-and-forget: a
    /// create is not idempotent, so a second tap while the first is on the wire would make
    /// a second channel — unlike opening a DM, where the relay answers both taps with the
    /// same room.
    func submit() async {
        guard canSubmit else { return }
        isSubmitting = true
        failure = nil
        do {
            created = try await engine.createChannel(
                name: name,
                about: about,
                isPrivate: isPrivate
            )
        } catch {
            failure = Self.message(for: error)
        }
        isSubmitting = false
    }

    /// What a failed create says out loud.
    ///
    /// The typed reasons become sentences here rather than being shown raw: a relay's
    /// `restricted: not a member of this community` is accurate and means nothing to the
    /// person who just typed a name. The unclassified arm keeps the relay's own words,
    /// because a deployment refusing for a reason this client has never seen is exactly
    /// when the raw text is worth more than a summary.
    static func message(for error: Error) -> String {
        switch error {
        case ChannelCreationError.emptyName:
            "A channel needs a name."
        case let ChannelCreationError.rejected(reason):
            message(for: reason)
        case ChannelCreationError.publishFailed:
            "Could not reach the relay. The channel may not have been created."
        default:
            "Could not create the channel."
        }
    }

    private static func message(for reason: OKReason) -> String {
        switch reason {
        case .restricted:
            "This workspace did not allow you to create a channel."
        case .rateLimited:
            "Too many channels too quickly. Try again in a moment."
        case let .invalid(message):
            "The relay refused that: \(message)"
        case let .duplicate(message), let .pow(message), let .authRequired(message),
             let .blocked(message), let .error(message), let .unspecified(message):
            message.isEmpty ? "The relay refused that." : "The relay refused that: \(message)"
        }
    }
}
