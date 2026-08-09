import BuzzKit
import Foundation
import NostrCore
import WidgetKit

/// Writes the App Group handoff the Threads widget reads, and publishes the identity key
/// the widget signs its relay request with.
///
/// # When this runs, and why those moments
///
/// On leaving the foreground, and on entering it. Leaving is the important one: it is the
/// last moment this process is guaranteed to still exist, and it is also — not by
/// coincidence — the moment the reader is about to be looking at their Home Screen. Both
/// writes reload the widget's timeline, which is free of the widget's own daily budget
/// only while the app is in the foreground; the one on the way out is a single budgeted
/// reload, spent deliberately.
///
/// # What it deliberately does not do
///
/// It does not compute a number for a community other than the active one. The app opens
/// one store at a time (§ ``Community/storeFilename``), so a snapshot per community would
/// mean opening each one in turn — real work, and the thing a configurable widget will
/// need. Until then the widget covers exactly the community the app has open, and says so
/// on its face.
@MainActor
enum ThreadsWidgetSnapshotWriter {
    /// Recomputes the snapshot for the active community and reloads the widget.
    ///
    /// Silent on every failure. A snapshot that cannot be built is not an error the reader
    /// can act on, and the widget already has a defined answer for a missing or stale one
    /// — last-good with a timestamp, or an invitation to open the app.
    static func write(store: BuzzEventStore, selfPubkeyHex: String, community: Community) async {
        guard let relayURL = URL(string: community.relayURLString),
              let queryURL = RelayEndpoint.queryURL(for: relayURL)
        else { return }

        // Read fresh rather than taking the view's copy: this runs from the scene-phase
        // hook, which is above every screen that owns one, and the marks are a plain
        // `UserDefaults` read.
        let marks = ThreadReadMarks()

        // The watchlist is the PARTICIPATION list, not the currently-unread one. A thread
        // the reader has already read is exactly the thread the next reply arrives in, and
        // a watchlist built from unread threads would be blind to it — the widget would
        // only ever confirm numbers the app had already computed.
        guard let threads = try? store.threadActivity(selfPubkey: selfPubkeyHex, limit: ThreadsWidgetSnapshot.watchlistLimit),
              !threads.isEmpty
        else {
            // No participation, no watchlist — but still write, so the widget can draw a
            // truthful zero instead of the previous identity's number.
            await save(
                snapshot: ThreadsWidgetSnapshot(
                    communityName: community.name,
                    queryURLString: queryURL.absoluteString,
                    keychainAccount: community.keychainAccount,
                    selfPubkeyHex: selfPubkeyHex,
                    watched: [],
                    localCount: 0,
                    capturedAt: Date()
                ),
                keychainAccount: community.keychainAccount
            )
            return
        }

        // One frontier read per distinct channel rather than per thread: twenty threads
        // routinely live in a handful of channels.
        var frontiers: [String: Int64] = [:]
        for channelID in Set(threads.map(\.channelID)) {
            frontiers[channelID] = (try? await store.effectiveReadFrontier(context: channelID)) ?? 0
        }

        let watched = threads.map { thread in
            ThreadsWidgetSnapshot.Watched(
                rootID: thread.rootID,
                channelID: thread.channelID,
                cutoff: max(frontiers[thread.channelID] ?? 0, marks.marks[thread.rootID] ?? 0)
            )
        }

        let unread = (try? store.unreadThreads(selfPubkey: selfPubkeyHex)) ?? []

        await save(
            snapshot: ThreadsWidgetSnapshot(
                communityName: community.name,
                queryURLString: queryURL.absoluteString,
                keychainAccount: community.keychainAccount,
                selfPubkeyHex: selfPubkeyHex,
                watched: watched,
                localCount: marks.unseenCount(among: unread),
                capturedAt: Date()
            ),
            keychainAccount: community.keychainAccount
        )
    }

    /// Removes the snapshot and reloads, so a signed-out phone stops showing the number
    /// the signed-in one had.
    ///
    /// The published key copy goes with it. Sign-out deletes the original
    /// (`AppEnvironment.signOut`); leaving the copy behind would mean an identity key
    /// surviving the act that exists to remove it.
    static func clear(keychainAccount: String?) {
        ThreadsWidgetSnapshot.clear()
        if let keychainAccount {
            try? KeychainSigner(
                account: keychainAccount,
                accessGroup: ThreadsWidgetSnapshot.keychainAccessGroup
            ).delete()
        }
        WidgetCenter.shared.reloadAllTimelines()
    }

    private static func save(snapshot: ThreadsWidgetSnapshot, keychainAccount: String) async {
        // The key first: a snapshot the widget can read but cannot sign against produces a
        // 401 loop that looks exactly like a relay problem.
        try? KeychainSigner(account: keychainAccount)
            .copyKey(toAccessGroup: ThreadsWidgetSnapshot.keychainAccessGroup)
        snapshot.save()
        WidgetCenter.shared.reloadAllTimelines()
    }
}
