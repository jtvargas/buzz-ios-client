import Foundation

/// What the app hands the Threads widget so the widget can answer "how many threads have
/// something new in them?" against the relay, with the app not running.
///
/// # Why a snapshot at all, when the widget talks to the relay itself
///
/// The relay can say what was *said*; only this device can say what has been *read*. The
/// Threads number is the intersection of the two, and the read half is three things the
/// relay either does not hold or the widget cannot reach: the per-channel NIP-RS frontier
/// (in the community's SQLite store), the device-local thread marks (in `UserDefaults`,
/// deliberately never synced — see `ThreadReadMarks`), and which threads the reader
/// participates in at all. So the app pre-computes the *cutoffs* and the widget applies
/// them to what it fetches. No database, no GRDB and no message text cross into the
/// extension: ids, timestamps and one URL.
///
/// # One blob under one key
///
/// `UserDefaults` writes are per key and are not transactional, so a widget reload landing
/// between two of them would read a watchlist from one moment against a count from another
/// — a wrong number, silently. Everything the widget needs is therefore one `Codable` value
/// under ``defaultsKey``: it is either the old snapshot or the new one, never half of each.
struct ThreadsWidgetSnapshot: Codable, Sendable, Equatable {
    /// One thread the reader participates in, and the timestamp a reply must beat to be
    /// new *to them*.
    struct Watched: Codable, Sendable, Equatable {
        /// The thread's root event id — what replies carry in their `e` tag.
        let rootID: String
        /// The channel the thread lives in, carried so the widget can re-derive this
        /// thread's cutoff when a fresher read frontier arrives from another device.
        let channelID: String
        /// `max(channel read frontier, device-local thread mark)` at snapshot time.
        ///
        /// The two conditions the app applies — "a foreign reply past the channel
        /// frontier" and "the newest foreign reply past this device's mark" — are both
        /// tests on the *newest* foreign reply, so their conjunction is one comparison
        /// against the larger of the two bounds. Collapsing them here is what lets the
        /// widget count with a single `>` per thread instead of carrying the shape of the
        /// store's query into an extension.
        let cutoff: Int64
    }

    /// The App Group both binaries read and write. Declared in each target's entitlements;
    /// a mismatch between the two is a widget that silently sees no snapshot at all.
    static let appGroupID = "group.com.jtvargas.hive"

    /// The single defaults key holding the encoded snapshot.
    static let defaultsKey = "threadsWidget.snapshot"

    /// The Keychain access group the identity key is published into for the widget.
    ///
    /// Spelled with the team prefix because that is what `SecItem*` expects at runtime,
    /// while the entitlement files spell the same group as `$(AppIdentifierPrefix)…`.
    static let keychainAccessGroup = "J7K9Z79S5F.com.jtvargas.hive.shared"

    /// How many threads the watchlist carries.
    ///
    /// Not a display limit — a relay one. The watchlist becomes an OR-chain of `#e` terms
    /// in one Postgres query, and measured on the live relay the planner keeps using the
    /// tags GIN index up to roughly this many terms and abandons it past forty, at which
    /// point it filters every candidate row instead (5.8 ms at twenty, 52 ms plus 22 ms of
    /// planning at forty). Twenty most-recently-active threads is the bound that keeps the
    /// fast plan; threads older than that are invisible to the widget until the app runs
    /// again, which is the honest trade and is why the face carries a timestamp.
    static let watchlistLimit = 20

    /// The community's display name, so a number on the Home Screen says whose it is.
    let communityName: String
    /// The relay's `POST /query` endpoint for this community.
    ///
    /// Communities are told apart by host — including by port, which is how this device's
    /// two differ — and the relay binds the tenant off the `Host` header. Carrying the
    /// resolved URL rather than rebuilding it in the extension keeps that derivation in
    /// one place.
    let queryURLString: String
    /// The Keychain account this community's identity signs with.
    let keychainAccount: String
    /// The reader's own pubkey, so their own replies do not count as new to them.
    let selfPubkeyHex: String
    /// The threads being watched, most recently active first.
    let watched: [Watched]
    /// The number the app itself was showing when this was written.
    ///
    /// Rendered before the first fetch of a reload and whenever a fetch fails, so the
    /// widget's worst case is the app's last known-good answer with a stale timestamp
    /// rather than a zero. A zero the reader cannot tell from a real zero is the one
    /// failure this whole design is arranged to avoid.
    let localCount: Int
    /// When the app wrote this.
    let capturedAt: Date
}

extension ThreadsWidgetSnapshot {
    /// The shared defaults suite, or `nil` if the App Group is not configured on this
    /// build — which is a build error wearing a runtime costume, so callers render the
    /// "open Hive" placeholder rather than pretending the count is zero.
    static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    /// Reads the snapshot the app last wrote, or `nil` when there is none.
    static func load(from defaults: UserDefaults? = ThreadsWidgetSnapshot.sharedDefaults) -> ThreadsWidgetSnapshot? {
        guard let data = defaults?.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(ThreadsWidgetSnapshot.self, from: data)
    }

    /// Writes this snapshot as the whole of ``defaultsKey``.
    func save(to defaults: UserDefaults? = ThreadsWidgetSnapshot.sharedDefaults) {
        guard let defaults, let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    /// Removes the snapshot — what signing out has to do, or the widget goes on showing
    /// the previous identity's number for as long as the phone stays on.
    static func clear(from defaults: UserDefaults? = ThreadsWidgetSnapshot.sharedDefaults) {
        defaults?.removeObject(forKey: defaultsKey)
    }
}
