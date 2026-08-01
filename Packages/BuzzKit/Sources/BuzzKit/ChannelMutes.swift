import Foundation
import NostrCore

/// Cross-device channel mutes: the wire shape of the `kind:30078` blob the Buzz
/// clients already share, and the merge that decides what a device believes.
///
/// **This format is not ours to choose.** Desktop and the Flutter mobile client
/// read and write the same addressable event, so a mute set on a phone has to be
/// the mute a laptop reads. The producer this was written against is
/// `mobile/lib/features/channels/channel_mutes/` — `channel_mutes_storage.dart` for
/// the JSON, `channel_mutes_manager.dart` for the tags, the crypto and the merge.
///
/// It shares `kind:30078` with ``ReadState`` and is a *different addressable event*:
/// read state is `d = read-state:<slot>` / `t = read-state`, mutes are
/// `d = channel-mutes` / `t = channel-mutes`. Neither can replace the other, and
/// each subscription asks for its own `t` — see ``SyncEngine/channelMutesFilter(selfPubkeyHex:)``.
enum ChannelMutes {
    /// The schema version written into every blob. Parsers pin to 1 rather than
    /// reading the field, exactly as the Flutter producer does.
    static let schemaVersion = 1

    /// The `d` tag value. One blob per identity — unlike read state, which is
    /// per-installation, a mute is a decision about a channel and not about a device,
    /// so every device writes the same coordinate.
    static let dTagValue = "channel-mutes"

    /// The `t` tag value, which is what scopes the subscription.
    static let tTagValue = "channel-mutes"

    static func dTag() -> [String] { ["d", dTagValue] }
    static func tTag() -> [String] { ["t", tTagValue] }

    /// Whether an event is a well-formed mute blob: exactly one `d` tag reading
    /// `channel-mutes`, and a matching `t` tag. The structural gate before the
    /// content is decrypted — a `kind:30078` that is somebody's read state, or an
    /// app-data event from an unrelated feature, gets no further.
    static func hasValidTags(_ event: NostrEvent) -> Bool {
        let dTags = event.tags.filter { $0.first == "d" }
        guard dTags.count == 1,
              dTags.first.flatMap({ $0.count > 1 ? $0[1] : nil }) == dTagValue
        else { return false }
        return event.tags.contains { $0.count > 1 && $0[0] == "t" && $0[1] == tTagValue }
    }
}

/// One channel's mute decision and when it was taken, in unix seconds.
///
/// An unmute is a record with `muted == false` and a *newer* `updatedAt`, never the
/// absence of a record: the merge is per-channel last-writer-wins, so dropping the
/// false entry would let another device's older `true` win the next time the two
/// blobs meet.
struct ChannelMuteEntry: Equatable, Sendable {
    let muted: Bool
    let updatedAt: Int64
}

/// The decrypted plaintext of a mute blob.
struct ChannelMuteBlob: Equatable, Sendable {
    /// Mute decisions by channel id. Includes the `muted == false` records.
    let channels: [String: ChannelMuteEntry]

    /// The canonical `{"version":1,"channels":{…}}` JSON to encrypt. Sorted keys make
    /// the output deterministic so a test can assert it byte-for-byte.
    func encodedJSON() throws -> String {
        let channelObjects = channels.mapValues { entry in
            ["muted": entry.muted, "updatedAt": Int(entry.updatedAt)] as [String: Any]
        }
        let object: [String: Any] = [
            "version": ChannelMutes.schemaVersion,
            "channels": channelObjects,
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard let json = String(bytes: data, encoding: .utf8) else {
            throw ChannelMuteError.encodingFailed
        }
        return json
    }

    /// Parses a decrypted plaintext, returning `nil` only when the envelope itself is
    /// unreadable. An individual channel entry that fails validation is dropped and the
    /// rest of the blob is still adopted — the same partial-tolerance rule read state
    /// applies, and the reason a peer on a newer schema cannot cost this device every
    /// mute it holds.
    static func decode(plaintext: String) -> ChannelMuteBlob? {
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(plaintext.utf8)),
              let record = parsed as? [String: Any],
              let rawChannels = record["channels"] as? [String: Any]
        else { return nil }

        var channels: [String: ChannelMuteEntry] = [:]
        for (channelID, rawEntry) in rawChannels {
            guard !channelID.isEmpty,
                  let entry = rawEntry as? [String: Any],
                  // `as? Bool` on an NSNumber would accept 0/1 and, worse, accept any
                  // integer as `true`; the producer writes a real JSON boolean.
                  let muted = entry["muted"] as? Bool,
                  let updatedAt = entry["updatedAt"] as? Int
            else { continue }
            channels[channelID] = ChannelMuteEntry(muted: muted, updatedAt: Int64(updatedAt))
        }
        return ChannelMuteBlob(channels: channels)
    }
}

enum ChannelMuteError: Error {
    case encodingFailed
}
