import Foundation
import GRDB

/// One channel the composer can complete a `#` token to.
///
/// Deliberately the *whole* channel table rather than the channels one identity has
/// joined: a `#`-reference is a pointer, not a membership claim, and the received
/// side resolves the same names through the app-wide `#channel` map built from
/// ``ChannelListRow``. Keeping both sides fed from `channel` means a name that
/// completes in the composer is a name that renders as a link on arrival — which holds
/// only because the receiving scanner tries multi-word spans against that map the way
/// it does for a person's name; a single-run scanner silently truncated
/// `#Design Review` to `Design` and could resolve it to a different channel entirely.
public struct ChannelSuggestion: Sendable, Hashable, Identifiable {
    /// The channel's group id — the `d` of its kind-39000 metadata, which is also
    /// the `h` its messages are scoped by.
    public let id: String
    /// The channel's display name, trimmed and never empty. What the composer
    /// inserts and what the panel shows; the group id is never rendered.
    public let name: String
    /// Whether the channel is closed — NIP-29's bare `private` tag, as projected
    /// into `channel.is_private`. The panel labels it so a reference to a channel
    /// the reader cannot open is not a surprise.
    public let isPrivate: Bool

    public init(id: String, name: String, isPrivate: Bool) {
        self.id = id
        self.name = name
        self.isPrivate = isPrivate
    }
}

public extension BuzzEventStore {
    /// Every *named* channel, ordered by name case-insensitively.
    ///
    /// Synchronous and `nonisolated` so it runs on the concurrent reader off the actor,
    /// the same discipline that lets ``mentionCandidates(channel:selfPubkey:)`` back a
    /// live autocomplete index.
    ///
    /// How it stays live is worth being exact about, because it is indirect: the app's
    /// observation watches `event`, not `channel`. A new or renamed channel appends a
    /// kind-39000 event, so the same signal that carries messages carries this too. A
    /// `channel` row that changed *without* an event — a projection rebuild — would not
    /// re-fire it.
    ///
    /// A channel whose metadata carries no name is omitted rather than falling back
    /// to its group id: this read exists to complete `#name`, and a group id is
    /// precisely what must never reach the screen. Ordering is by the *trimmed* name
    /// (not by recency) because the panel is an alphabetical directory the author scans,
    /// and it must sort on the same string it returns — sorting the raw column floats a
    /// name stored with leading whitespace to the top of a list where it then renders
    /// trimmed. `COLLATE NOCASE` is SQLite's ASCII-only fold, so a name opening with a
    /// non-ASCII letter sorts after `z`; a stable total order matters more here than a
    /// locale-perfect one, since the ranked result set is what the author actually sees.
    nonisolated func channelSuggestions() throws -> [ChannelSuggestion] {
        try reader.read { db in
            try Self.fetchChannelSuggestions(db)
        }
    }
}

extension BuzzEventStore {
    /// The named-channel read, over an open database so an observation can track it.
    ///
    /// `TRIM(name) <> ''` filters in SQL so a whitespace-only name never reaches the
    /// index, and the Swift side trims again because the stored name is authored
    /// text: SQLite's `TRIM` and `String.trimmingCharacters(in: .whitespacesAndNewlines)`
    /// do not agree on non-ASCII whitespace, and the *rendered* name must be the
    /// trimmed one.
    static func fetchChannelSuggestions(_ db: Database) throws -> [ChannelSuggestion] {
        let rows = try Row.fetchAll(db, sql: """
        SELECT id, name, is_private
        FROM channel
        WHERE name IS NOT NULL AND TRIM(name) <> ''
        ORDER BY TRIM(name) COLLATE NOCASE, id
        """)

        return rows.compactMap { row in
            let raw: String? = row["name"]
            guard let name = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { return nil }
            return ChannelSuggestion(
                id: row["id"],
                name: name,
                isPrivate: row["is_private"] ?? false
            )
        }
    }
}
