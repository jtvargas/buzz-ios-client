import Foundation
import NostrCore

/// Answers "how many of the reader's threads hold something they have not seen?" from the
/// relay, in one HTTP round trip, with the app not running.
///
/// # The arithmetic, and why it is one comparison
///
/// A thread counts when the newest reply *somebody else* wrote is newer than the reader's
/// cutoff for it. The app folds its two bounds — the channel's read frontier and this
/// device's thread mark — into ``ThreadsWidgetSnapshot/Watched/cutoff`` before writing the
/// snapshot, so nothing about the store's query has to be reproduced here.
///
/// # Three filters, one request
///
/// 1. **replies** — kind 9 carrying any watched root in an `e` tag, since the oldest
///    cutoff. This is the number.
/// 2. **the roots themselves** — because a thread whose *opener* was deleted disappears
///    from the app's count while its replies stay perfectly alive on the relay, which
///    would otherwise be a permanent overcount with no way for the reader to clear it.
///    A watched root absent from the response has been deleted or is no longer readable,
///    and its thread is dropped.
/// 3. **read state** — the reader's own encrypted NIP-RS blobs. The frontier is *synced*,
///    so reading a channel on the desktop moves it on the relay while this device's
///    snapshot goes on saying what it said hours ago. Without this filter the widget keeps
///    counting threads the reader has already dealt with somewhere else.
enum ThreadsCountFetcher {
    /// The relay clamps a page at 1,000; this stays well under it. At the measured density
    /// of this deployment a since-bounded twenty-root query does not approach either number
    /// — but a full page is possible in principle, and a full page means the count is a
    /// floor rather than a total, which is what ``Result/isFloor`` carries to the face.
    static let pageLimit = 500

    /// What one fetch established.
    struct Result: Sendable, Equatable {
        let count: Int
        /// Whether the relay filled the page, making `count` a floor rather than a total.
        let isFloor: Bool
    }

    /// Fetches and counts. Throws only when the request could not be made or completed;
    /// an empty watchlist is a legitimate zero, not a failure.
    static func fetch(
        snapshot: ThreadsWidgetSnapshot,
        transport: any HTTPTransport = URLSessionHTTPTransport()
    ) async throws -> Result {
        guard !snapshot.watched.isEmpty else { return Result(count: 0, isFloor: false) }
        guard let queryURL = URL(string: snapshot.queryURLString) else {
            throw FetchError.malformedEndpoint
        }

        let signer = KeychainSigner(
            account: snapshot.keychainAccount,
            accessGroup: ThreadsWidgetSnapshot.keychainAccessGroup
        )
        let roots = snapshot.watched.map(\.rootID)
        let since = snapshot.watched.map(\.cutoff).min() ?? 0

        let body = try JSONSerialization.data(withJSONObject: [
            [
                "kinds": [EventKind.channelMessage.rawValue],
                "#e": roots,
                "since": since,
                "limit": pageLimit,
            ],
            [
                "kinds": [EventKind.channelMessage.rawValue],
                "ids": roots,
            ],
            [
                "kinds": [EventKind.readState.rawValue],
                "authors": [snapshot.selfPubkeyHex],
                "#t": ["read-state"],
            ],
        ])

        // Freshly signed for this exact URL and body. The relay's window is ±60 seconds and
        // it caches each authorization event against replay, so a header can be neither
        // minted in advance by the app nor reused across a retry.
        let authorization = try await NIP98.authorizationHeader(
            url: queryURL,
            method: "POST",
            body: body,
            signer: signer
        )

        let (data, status) = try await transport.post(
            body: body,
            to: queryURL,
            headers: ["Content-Type": "application/json", "Authorization": authorization]
        )
        guard (200 ... 299).contains(status) else { throw FetchError.httpStatus(status) }
        guard let events = try? JSONDecoder().decode([NostrEvent].self, from: data) else {
            throw FetchError.unreadableResponse
        }

        return count(events: events, snapshot: snapshot, signer: signer, awaiting: roots)
    }

    /// The pure half: everything the response means, with no I/O in it.
    ///
    /// Separated so the counting rule can be reasoned about — and exercised — without a
    /// relay, a Keychain or a network.
    static func count(
        events: [NostrEvent],
        snapshot: ThreadsWidgetSnapshot,
        signer: KeychainSigner?,
        awaiting roots: [String]
    ) -> Result {
        let rootSet = Set(roots)
        let replyLimitReached = events.count { $0.kind == .channelMessage } >= pageLimit

        // Which watched roots came back alive. Filter 2 asked for all of them by id, so a
        // root missing here is one the relay would not serve — deleted, or in a channel
        // this identity can no longer read.
        let aliveRoots = Set(events.lazy.filter { rootSet.contains($0.id) }.map(\.id))

        // Fresher frontiers than the snapshot's, merged grow-only across every device slot
        // exactly as the store merges them.
        let frontiers = signer.map { mergedFrontiers(from: events, signer: $0) } ?? [:]

        var newestForeignReply: [String: Int64] = [:]
        for event in events where event.kind == .channelMessage && !rootSet.contains(event.id) {
            guard event.pubkey != snapshot.selfPubkeyHex,
                  let rootID = event.threadReference.rootID,
                  rootSet.contains(rootID)
            else { continue }
            newestForeignReply[rootID] = max(newestForeignReply[rootID] ?? 0, event.createdAt)
        }

        let count = snapshot.watched.count { watched in
            guard aliveRoots.contains(watched.rootID) else { return false }
            guard let newest = newestForeignReply[watched.rootID] else { return false }
            return newest > max(watched.cutoff, frontiers[watched.channelID] ?? 0)
        }
        return Result(count: count, isFloor: replyLimitReached)
    }

    /// The reader's per-channel read frontiers as the relay currently holds them.
    ///
    /// Each blob is one device's slot; the effective frontier of a channel is the maximum
    /// across all of them, because read state is a grow-only max register and a stale slot
    /// must never pull a frontier backwards.
    private static func mergedFrontiers(from events: [NostrEvent], signer: KeychainSigner) -> [String: Int64] {
        var merged: [String: Int64] = [:]
        // Synchronous decryption on purpose: `decryptToSelf` is `async` only because the
        // signer protocol is, and a widget timeline has no reason to interleave here.
        for event in events where event.kind == .readState {
            guard let plaintext = try? decryptSynchronously(event.content, with: signer),
                  let parsed = try? JSONSerialization.jsonObject(with: Data(plaintext.utf8)),
                  let record = parsed as? [String: Any],
                  record["v"] as? Int == 1,
                  let contexts = record["contexts"] as? [String: Any]
            else { continue }
            for (channelID, value) in contexts {
                // Integers only. A JSON real is a malformed entry per NIP-RS and is dropped
                // rather than truncated into a plausible-looking timestamp.
                guard let number = value as? NSNumber, !CFNumberIsFloatType(number) else { continue }
                merged[channelID] = max(merged[channelID] ?? 0, number.int64Value)
            }
        }
        return merged
    }

    /// NIP-44 decrypt-to-self without the actor hop `KeychainSigner.decryptToSelf` implies.
    private static func decryptSynchronously(_ ciphertext: String, with signer: KeychainSigner) throws -> String {
        guard let key = try signer.loadPrivateKey() else { throw FetchError.identityUnavailable }
        let conversationKey = try NIP44.conversationKey(privateKey: key, peer: key.publicKey)
        return try NIP44.decrypt(ciphertext, conversationKey: conversationKey)
    }

    enum FetchError: Error, Equatable {
        /// The snapshot's endpoint did not parse as a URL.
        case malformedEndpoint
        /// The relay answered, but not with success. A 401 here is the signal that the
        /// published key copy is missing or the device clock has drifted past NIP-98's
        /// sixty-second window.
        case httpStatus(Int)
        /// A 2xx whose body was not a JSON array of events.
        case unreadableResponse
        /// The shared Keychain group holds no key for this account — the app has not run
        /// since the widget was added, or the reader has signed out.
        case identityUnavailable
    }
}
