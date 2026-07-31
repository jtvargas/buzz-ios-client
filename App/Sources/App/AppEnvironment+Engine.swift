import BuzzKit
import Foundation
import NostrCore

extension AppEnvironment {
    /// The engine and its collaborators. One HTTP transport is shared by the two signed
    /// query clients — the history windows and the channel directory — because they speak to
    /// the same endpoint with the same credentials.
    func makeEngine(websocketURL: URL, queryURL: URL) -> SyncEngine {
        let connection = RelayConnection(url: websocketURL, signer: signer)
        let subscriptions = SubscriptionManager(connection: connection, signer: signer)
        let httpTransport = URLSessionHTTPTransport()
        return SyncEngine(
            connection: connection,
            subscriptions: subscriptions,
            store: store,
            presence: PresenceStore(),
            windowClient: WindowClient(
                transport: httpTransport,
                queryURL: queryURL,
                signer: signer
            ),
            directoryClient: AnyChannelDirectoryFetcher(
                ChannelDirectoryClient(
                    transport: httpTransport,
                    queryURL: queryURL,
                    signer: signer
                )
            ),
            signer: signer
        )
    }

    /// The blob-store client for the same relay, or `nil` if that URL has no HTTP
    /// form — in which case the composer's `+` reports having nowhere to upload to
    /// rather than failing on the request.
    ///
    /// **Not part of the engine, deliberately.** This is an HTTP `PUT` to the relay's
    /// blob store; the engine is the socket and the store. Handed to a conversation
    /// alongside `drafts` instead, which keeps that boundary and keeps a conversation
    /// testable without either. It is built beside the engine and dropped with it
    /// because both are bound to one relay URL and one key — an uploader outliving a
    /// sign-out would sign an upload for an identity that no longer exists.
    ///
    /// Its own `URLSessionHTTPTransport` rather than the engine's: this one does
    /// `PUT`s of whole photographs, and sharing a session with the signed query
    /// clients would put a multi-megabyte body in the same connection pool as the
    /// history windows.
    ///
    /// # Why it builds a session rather than taking `.shared`
    ///
    /// It used to take the default, which is `URLSession.shared`, and the comment above
    /// claimed a separation the code did not have. That mattered for one reason:
    /// `timeoutIntervalForResource` on the default configuration is **seven days**, and
    /// `timeoutIntervalForRequest` only fires when a connection goes completely silent — so an
    /// upload that trickled, or a relay that accepted the body and never answered, spun the
    /// tile indefinitely. The owner reported exactly that with several pictures attached at
    /// once.
    ///
    /// # Why these two numbers, and why the second one is large
    ///
    /// They do different jobs, and picking them by feel gets one of them wrong.
    /// `timeoutIntervalForRequest` is a **stall** detector — it is reset by activity, so it
    /// catches the case that actually hangs a phone: a relay that took the connection and then
    /// went quiet. `timeoutIntervalForResource` is an absolute ceiling on the whole transfer,
    /// and it does not care that bytes are still moving.
    ///
    /// So the ceiling is deliberately generous. A still is re-encoded at quality 1.0
    /// (``ComposerImagePreparation/conversionQuality``, matched to the mobile client), and the
    /// relay will take an image up to 50 MB, so a full-resolution photograph on a weak
    /// connection is legitimately a minutes-long upload. A tight ceiling would turn those into
    /// failures — and a picture that would have arrived being refused is a worse bug than the
    /// one this is fixing, because the author cannot tell it from a broken app. A trickle that
    /// runs out the ceiling is still recoverable by hand: the tile has an X on it.
    ///
    /// ``ComposerAttachmentsModel/uploadDeadline`` sits just outside this, so a well-behaved
    /// failure comes back as a network error naming itself rather than as the composer giving
    /// up on it.
    func makeMediaUploader(websocketURL: URL) -> (any MediaUploading)? {
        guard let baseURL = RelayEndpoint.httpBaseURL(for: websocketURL) else { return nil }
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 240
        return MediaUploadClient(
            transport: URLSessionHTTPTransport(session: URLSession(configuration: configuration)),
            baseURL: baseURL,
            signer: signer
        )
    }

    // MARK: - Store location

    /// Where the database lives: `Application Support/Hive/store.sqlite`, created on
    /// first launch. Here rather than in the class body because it is composition —
    /// it is what ``AppEnvironment/init()`` opens before there is an identity to open
    /// it for — and because it touches nothing private, so it costs no widening.
    static func makeStore() throws -> BuzzEventStore {
        let directory = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Hive", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("store.sqlite").path
        return try BuzzEventStore(path: path)
    }
}
