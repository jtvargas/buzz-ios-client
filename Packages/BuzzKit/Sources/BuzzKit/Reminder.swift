import Foundation
import NostrCore

/// Reminders — "remind me about this message later" — as NIP-ER models them.
///
/// # Why this mirrors the desktop client field for field
///
/// A reminder is not local state. It is a `kind:30300` addressable event authored by the
/// identity that set it and NIP-44 encrypted to itself, so the same reminder set on a phone
/// is the one a desktop shows, and completing it in either place completes it in both. The
/// JSON below is therefore a *contract*, not a convenience: it is exactly what
/// `desktop/src/features/reminders/lib/reminderTypes.ts` writes and
/// `parseReminderContent` will accept. A field renamed here is a reminder the other client
/// silently drops.
///
/// Unlike ``ChannelMutes``, which keeps a whole table in one blob, each reminder is its own
/// addressable event under a random `d` tag — so two devices setting two reminders do not
/// overwrite each other, and completing one does not rewrite the rest.
public enum Reminders {
    /// The tag the relay reads to know when a reminder is due.
    public static let notBeforeTag = "not_before"
    /// Set on a reminder that is finished, so the relay can eventually collect it.
    public static let expirationTag = "expiration"

    /// A `d` tag with 128 bits of entropy, which NIP-ER requires.
    ///
    /// Sixteen raw bytes rather than a `UUID`: a v4 UUID spends six of its bits on version
    /// and variant markers and carries only 122 random ones, which is under the floor.
    public static func randomDTag() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: UInt8.min ... UInt8.max)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// When a finished reminder may be collected: 30–90 days out, jittered.
    ///
    /// Jittered because every client completing reminders at the same cadence would
    /// otherwise hand the relay a synchronised pile of expirations. Desktop picks the same
    /// window for the same reason.
    public static func jitteredExpiration(from now: Date) -> Int64 {
        let days = Int64.random(in: 30 ... 89)
        return Int64(now.timeIntervalSince1970) + days * 86_400
    }

    /// Parses a `not_before` value the way the relay's own validator does: ASCII digits
    /// only, no leading zero unless the value *is* zero.
    ///
    /// Strict on purpose. A client that accepted `007` would show a reminder the relay
    /// considers malformed and will not serve to anyone else — a reminder that exists on
    /// one device and nowhere else is worse than one that never appeared.
    public static func parseNotBefore(_ raw: String) -> Int64? {
        guard !raw.isEmpty else { return nil }
        if raw != "0", raw.hasPrefix("0") { return nil }
        guard raw.allSatisfy(\.isASCII), raw.allSatisfy(\.isNumber) else { return nil }
        return Int64(raw)
    }

    /// The longest preview stored on a reminder's target.
    ///
    /// The payload is encrypted to one identity, so this is not a privacy bound — it is a
    /// size one. A reminder carrying a whole message would put the message in two places
    /// and grow an addressable event that is replaced on every status change.
    public static let previewLimit = 140

    /// `text` cut to ``previewLimit``, on a character boundary.
    public static func preview(of text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > previewLimit else { return trimmed }
        return String(trimmed.prefix(previewLimit))
    }
}

// MARK: - Content

/// Where a reminder points. Absent for a note-only reminder, which NIP-ER allows and this
/// client does not yet create.
public struct ReminderTarget: Codable, Sendable, Hashable {
    public let eventID: String
    public let channelID: String
    public let preview: String
    public let authorPubkey: String

    public init(eventID: String, channelID: String, preview: String, authorPubkey: String) {
        self.eventID = eventID
        self.channelID = channelID
        self.preview = preview
        self.authorPubkey = authorPubkey
    }

    /// The wire names, which are desktop's and are not the Swift ones. `eventId` rather
    /// than `eventID` is the contract; the property keeps the house spelling.
    private enum CodingKeys: String, CodingKey {
        case eventID = "eventId"
        case channelID = "channelId"
        case preview
        case authorPubkey
    }
}

public enum ReminderStatus: String, Codable, Sendable, CaseIterable {
    /// Set and waiting. The only status that carries a `not_before`.
    case pending
    /// Completed by the reader.
    case done
    /// Dismissed without completing.
    case cancelled
}

/// The decrypted plaintext of a reminder.
public struct ReminderContent: Codable, Sendable, Hashable {
    public var target: ReminderTarget?
    public var note: String?
    public var status: ReminderStatus

    public init(target: ReminderTarget? = nil, note: String? = nil, status: ReminderStatus) {
        self.target = target
        self.note = note
        self.status = status
    }

    /// Parses decrypted plaintext, failing closed.
    ///
    /// NIP-ER requires a client to ignore plaintext that is not an object or carries an
    /// unknown `status`, which is what a strict `Decodable` on ``ReminderStatus`` already
    /// does — an unrecognised status throws rather than defaulting to `pending`, so a
    /// future status invented by another client cannot resurface here as a live reminder.
    public static func decode(plaintext: String) -> ReminderContent? {
        guard let data = plaintext.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ReminderContent.self, from: data)
    }

    public func encodedJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Projection

/// One reminder as the `reminder` projection holds it — decrypted, flattened, and read
/// fresh so a `ValueObservation` keeps the Later screen live.
public struct ReminderRow: Sendable, Hashable, Identifiable {
    /// The `d` tag. The reminder's identity across every revision of its event.
    public let id: String
    /// The event this row was last built from.
    public let eventID: String
    public let createdAt: Int64
    /// When it is due. `nil` once the reminder is finished, which is what NIP-ER says a
    /// done or cancelled reminder looks like.
    public let notBefore: Int64?
    public let status: ReminderStatus
    public let target: ReminderTarget?
    public let note: String?

    public init(
        id: String,
        eventID: String,
        createdAt: Int64,
        notBefore: Int64?,
        status: ReminderStatus,
        target: ReminderTarget?,
        note: String?
    ) {
        self.id = id
        self.eventID = eventID
        self.createdAt = createdAt
        self.notBefore = notBefore
        self.status = status
        self.target = target
        self.note = note
    }

    /// When this reminder should fire, as a `Date`.
    public var dueDate: Date? {
        notBefore.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }
}
