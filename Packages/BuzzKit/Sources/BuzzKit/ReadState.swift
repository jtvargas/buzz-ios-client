import Foundation
import NostrCore

/// NIP-RS cross-device read state: the wire shape of a `kind:30078` read-state
/// blob and the validation both producing and consuming one must apply.
///
/// The blob is a NIP-78 addressable (parameterized-replaceable) event whose
/// `content` is NIP-44 ciphertext encrypted to the user's own identity. The
/// plaintext is a flat `{ "<context-id>": <unix-seconds> }` map of read frontiers,
/// one entry per readable context (a channel is keyed by its bare id — the `h` its
/// messages are scoped by). The merge across a user's devices is a grow-only
/// max-register CvRDT: the effective frontier of a context is the maximum of its
/// timestamp across every device's blob, so a stale replay can never lower a read
/// position (see ``BuzzEventStore/applyReadState(author:slot:contexts:sourceCreatedAt:sourceEventID:)``).
///
/// This mirrors the upstream Buzz clients byte-for-byte so read state syncs
/// cross-client with Desktop and mobile:
/// - Spec: `buzz/docs/nips/NIP-RS.md`.
/// - Desktop producer/format: `desktop/src/features/channels/readState/readStateFormat.ts`,
///   `desktop/src/features/communities/communityMarkRead.ts`.
/// - Mobile format/consumer: `mobile/lib/features/channels/read_state/read_state_format.dart`.
enum ReadState {
    /// The `d` tag value prefix. The remainder is a random, per-installation slot id
    /// with no relationship to the client id — solely the addressable-event key.
    static let dTagPrefix = "read-state:"

    /// The `t` tag value that lets a relay serve read-state blobs without returning
    /// every `kind:30078` app-data event the user owns.
    static let tTagValue = "read-state"

    /// The schema version of the plaintext blob. Blobs with any other `v` are ignored.
    static let schemaVersion = 1

    /// The maximum number of context entries a single blob may carry; a larger blob
    /// is rejected whole (NIP-RS Content Validation).
    static let maxContexts = 10_000

    /// The inclusive timestamp range a context entry may hold (unix seconds, u32).
    static let timestampRange: ClosedRange<Int64> = 0 ... 4_294_967_295

    /// The maximum byte length of a context id.
    static let maxContextIDBytes = 256

    // MARK: - Tag builders

    /// The `["d", "read-state:<slot>"]` tag identifying this installation's blob.
    static func dTag(slotID: String) -> [String] {
        ["d", dTagPrefix + slotID]
    }

    /// The mandatory `["t", "read-state"]` tag.
    static func tTag() -> [String] {
        ["t", tTagValue]
    }

    // MARK: - Tag validation

    /// Whether an event carries exactly one valid read-state `d` tag and exactly one
    /// `["t","read-state"]` tag — the structural gate before its content is decrypted.
    static func hasValidTags(_ event: NostrEvent) -> Bool {
        let dTags = event.tags.filter { $0.first == "d" }
        guard dTags.count == 1,
              let value = dTags.first.flatMap({ $0.count > 1 ? $0[1] : nil }),
              isValidDTag(value)
        else { return false }

        let tTags = event.tags.filter { $0.count > 1 && $0[0] == "t" && $0[1] == tTagValue }
        return tTags.count == 1
    }

    /// The slot id carried in an event's read-state `d` tag, or `nil` if the event is
    /// not a well-formed read-state event.
    static func slotID(from event: NostrEvent) -> String? {
        guard hasValidTags(event),
              let value = event.tags.first(where: { $0.first == "d" }).flatMap({ $0.count > 1 ? $0[1] : nil })
        else { return nil }
        return String(value.dropFirst(dTagPrefix.count))
    }

    /// Whether a `d` tag value is `read-state:<slot>` with a 1–64 char ASCII slot.
    static func isValidDTag(_ value: String) -> Bool {
        guard value.hasPrefix(dTagPrefix) else { return false }
        let slot = value.dropFirst(dTagPrefix.count)
        guard (1 ... 64).contains(slot.count) else { return false }
        return slot.allSatisfy { $0.isASCII }
    }
}

/// The decrypted plaintext of a read-state blob: the owning client's id and its
/// per-context read frontiers.
struct ReadStateBlob: Equatable {
    /// The stable installation identifier inside the encrypted content — the only
    /// link between a blob and the device that owns it, never visible to the relay.
    let clientID: String
    /// Read frontier per context (unix seconds). Sanitized: every value is an
    /// integer in ``ReadState/timestampRange`` and every key is at most
    /// ``ReadState/maxContextIDBytes`` bytes.
    let contexts: [String: Int64]

    /// The canonical `{"v":1,"client_id":…,"contexts":{…}}` JSON to encrypt. Sorted
    /// keys make the output deterministic so a test can assert it byte-for-byte.
    func encodedJSON() throws -> String {
        let object: [String: Any] = [
            "v": ReadState.schemaVersion,
            "client_id": clientID,
            "contexts": contexts.mapValues { Int($0) },
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard let json = String(bytes: data, encoding: .utf8) else {
            throw ReadStateError.encodingFailed
        }
        return json
    }

    /// Parses and validates a decrypted plaintext, returning `nil` for any blob that
    /// fails validation whole. Individual context entries that fail validation are
    /// dropped; the rest of the blob is still processed (NIP-RS Content Validation).
    static func decode(plaintext: String) -> ReadStateBlob? {
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(plaintext.utf8)),
              let record = parsed as? [String: Any]
        else { return nil }

        // `v` must be present and exactly the known version; an unknown version is
        // ignored, a missing/non-integer one is discarded — both surface as nil here.
        guard let version = record["v"] as? Int, version == ReadState.schemaVersion else { return nil }

        guard let clientID = record["client_id"] as? String,
              (1 ... 64).contains(clientID.count)
        else { return nil }

        guard let rawContexts = record["contexts"] as? [String: Any],
              rawContexts.count <= ReadState.maxContexts
        else { return nil }

        return ReadStateBlob(clientID: clientID, contexts: sanitize(rawContexts))
    }

    /// Keeps only context entries whose key fits the byte cap and whose value is an
    /// integer in range; a non-integer or out-of-range value drops that one entry.
    static func sanitize(_ contexts: [String: Any]) -> [String: Int64] {
        var result: [String: Int64] = [:]
        for (key, value) in contexts {
            guard key.utf8.count <= ReadState.maxContextIDBytes else { continue }
            guard let seconds = integerSeconds(value), ReadState.timestampRange.contains(seconds) else { continue }
            result[key] = seconds
        }
        return result
    }

    /// A strictly-integer reading of a JSON number: an `NSNumber` that is not an
    /// integer type (a float/double like `1.5`) is rejected, matching the upstream
    /// `value is int` discipline rather than silently truncating.
    private static func integerSeconds(_ value: Any) -> Int64? {
        guard let number = value as? NSNumber else { return nil }
        // CFNumber float types are the JSON reals NIP-RS says to discard.
        guard !CFNumberIsFloatType(number) else { return nil }
        return number.int64Value
    }
}

/// Errors raised while building a read-state blob.
enum ReadStateError: Error, Equatable {
    /// Serializing the blob to JSON produced non-UTF-8 bytes — unreachable in
    /// practice (`JSONSerialization` emits UTF-8), surfaced rather than force-unwrapped.
    case encodingFailed
}
