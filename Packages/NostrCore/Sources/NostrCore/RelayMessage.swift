import Foundation

/// A frame received from relay to client (NIP-01, NIP-42).
///
/// # Single-pass decode
///
/// Every `EVENT` frame carries a full event object, and this is the hottest
/// decode path in the client — a backfill can push hundreds of them a second.
/// The frame is therefore read in exactly one pass: `decode(from:)` hands the
/// bytes to a single `JSONDecoder`, `init(from:)` walks the array positionally
/// through one `unkeyedContainer`, and the embedded event is decoded *inline*
/// from that same container via `container.decode(NostrEvent.self)`.
///
/// The event is never lifted out to a dictionary and re-serialized: there is one
/// parse of the bytes and zero re-encoding, so nothing bridges through
/// `JSONSerialization` and non-ASCII content survives byte for byte (an id
/// recomputed after decode still matches).
///
/// # Tolerance
///
/// Relay input is untrusted, so a bad frame must never crash the reader. Every
/// structural problem surfaces as a typed ``FrameError`` for the caller to log
/// and skip; a frame naming a type this client does not model is likewise a
/// (recoverable) ``FrameError/unknownType(_:)`` rather than a silent success.
/// The trailing message on `OK` and `CLOSED` is optional in practice despite the
/// spec, so its absence is tolerated as an empty string.
public enum RelayMessage: Sendable, Equatable, Decodable {
    /// An event delivered for an active subscription.
    case event(subscriptionID: String, event: NostrEvent)
    /// The relay's verdict on a publish: accepted, plus a machine-readable note.
    case ok(eventID: String, accepted: Bool, message: String)
    /// End of stored events for a subscription — everything after is live.
    case eose(subscriptionID: String)
    /// The relay closed a subscription, usually a policy refusal.
    case closed(subscriptionID: String, message: String)
    /// A human-readable notice, typically an error.
    case notice(message: String)
    /// A NIP-42 challenge the client must answer with a signed event.
    case authChallenge(challenge: String)

    /// Why a relay frame could not be turned into a ``RelayMessage``.
    public enum FrameError: Error, Equatable {
        /// The bytes were not a JSON array (malformed, truncated, or an object).
        case notAnArray
        /// The array was empty and so carried no type tag.
        case empty
        /// The leading element was present but not a string.
        case nonStringType
        /// The type tag named a frame this client does not model.
        case unknownType(String)
        /// A recognised frame had missing or mistyped positional fields, or an
        /// embedded event that would not decode.
        case malformed(type: String)
    }

    /// Decodes a single relay frame from its raw bytes in one pass.
    ///
    /// All failures are reported as ``FrameError``; the underlying
    /// `DecodingError` for unparseable bytes is folded into
    /// ``FrameError/notAnArray`` so callers face a single error surface.
    public static func decode(from data: Data) throws -> RelayMessage {
        do {
            return try JSONDecoder().decode(RelayMessage.self, from: data)
        } catch let error as FrameError {
            throw error
        } catch {
            // The decoder rejected the bytes before the positional reader ran:
            // non-JSON, truncated, or a non-array top-level value.
            throw FrameError.notAnArray
        }
    }

    public init(from decoder: any Decoder) throws {
        guard var container = try? decoder.unkeyedContainer() else {
            throw FrameError.notAnArray
        }
        guard !container.isAtEnd else {
            throw FrameError.empty
        }
        guard let type = try? container.decode(String.self) else {
            throw FrameError.nonStringType
        }

        switch type {
        case "EVENT":
            let subscriptionID = try Self.string(&container, type)
            let event = try Self.event(&container, type)
            self = .event(subscriptionID: subscriptionID, event: event)
        case "OK":
            let eventID = try Self.string(&container, type)
            let accepted = try Self.bool(&container, type)
            self = .ok(eventID: eventID, accepted: accepted, message: Self.trailingMessage(&container))
        case "EOSE":
            self = try .eose(subscriptionID: Self.string(&container, type))
        case "CLOSED":
            let subscriptionID = try Self.string(&container, type)
            self = .closed(subscriptionID: subscriptionID, message: Self.trailingMessage(&container))
        case "NOTICE":
            self = try .notice(message: Self.string(&container, type))
        case "AUTH":
            self = try .authChallenge(challenge: Self.string(&container, type))
        default:
            throw FrameError.unknownType(type)
        }
    }

    // MARK: - Positional readers

    /// A required string field. A missing or mistyped slot is `.malformed`.
    private static func string(
        _ container: inout UnkeyedDecodingContainer,
        _ type: String
    ) throws -> String {
        guard !container.isAtEnd, let value = try? container.decode(String.self) else {
            throw FrameError.malformed(type: type)
        }
        return value
    }

    /// A required boolean field, as `OK` carries at index 2.
    private static func bool(
        _ container: inout UnkeyedDecodingContainer,
        _ type: String
    ) throws -> Bool {
        guard !container.isAtEnd, let value = try? container.decode(Bool.self) else {
            throw FrameError.malformed(type: type)
        }
        return value
    }

    /// A required embedded event, decoded inline from the same container so the
    /// frame is parsed only once. A field that is absent or not a valid event is
    /// `.malformed`.
    private static func event(
        _ container: inout UnkeyedDecodingContainer,
        _ type: String
    ) throws -> NostrEvent {
        guard !container.isAtEnd, let event = try? container.decode(NostrEvent.self) else {
            throw FrameError.malformed(type: type)
        }
        return event
    }

    /// The optional trailing message on `OK` / `CLOSED`. Absent — or present but
    /// not a string — collapses to the empty string, matching what relays send
    /// in practice.
    private static func trailingMessage(_ container: inout UnkeyedDecodingContainer) -> String {
        guard !container.isAtEnd else { return "" }
        return (try? container.decode(String.self)) ?? ""
    }
}
