import BuzzKit
import Foundation
import NostrCore

extension AppEnvironment {
    /// The engine and its collaborators. One HTTP transport is shared by the two signed
    /// query clients — the history windows and the channel directory — because they speak to
    /// the same endpoint with the same credentials.
    ///
    /// The store and signer are passed in rather than read off `self`, because this is
    /// called while the active community's graph is being *built*: taking them as arguments
    /// is what makes it impossible to compose an engine from one community's database and
    /// another's identity.
    func makeEngine(
        store: BuzzEventStore,
        signer: KeychainSigner,
        websocketURL: URL,
        queryURL: URL
    ) -> SyncEngine {
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
    func makeMediaUploader(signer: KeychainSigner, websocketURL: URL) -> (any MediaUploading)? {
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

    /// This session's minter for the signed grant a gated relay requires before it will
    /// serve a blob.
    ///
    /// Built beside ``makeMediaUploader(signer:websocketURL:)`` and dropped beside it, for
    /// the reason that one is: the grant is a signature bearing this identity, and a session
    /// that has ended must not be able to mint another.
    func makeMediaReadAuthorizer(signer: KeychainSigner, websocketURL: URL) -> MediaReadAuthorizer? {
        guard let baseURL = RelayEndpoint.httpBaseURL(for: websocketURL) else { return nil }
        return MediaReadAuthorizer(baseURL: baseURL, signer: signer)
    }

    /// Points the image pipeline at `authorizer`, or takes the last session's away.
    ///
    /// Both loaders, because both fetch from the same host: an avatar is relay media as
    /// much as an attachment is, and a deployment that gates blobs gates faces too. The
    /// export path does not need installing — it is handed the grant per call, from the
    /// environment, because it fetches on its own session.
    func installMediaReadAuthorizer(_ authorizer: MediaReadAuthorizer?) async {
        await RemoteImageLoader.shared.setAuthorization(authorizer)
        await RemoteImageLoader.messageMedia.setAuthorization(authorizer)
    }

    // MARK: - Store location

    /// The directory every community's database sits in: `Application Support/Hive`,
    /// created on first use.
    static func storeDirectory() throws -> URL {
        let directory = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Hive", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Opens one community's database by the filename its record carries
    /// (§ ``Community/storeFilename``) — `store.sqlite` for the install that predates the
    /// community list, `store-<uuid>.sqlite` for every one added since.
    ///
    /// Here rather than in the class body because it is composition, and because it
    /// touches nothing private, so it costs no widening.
    static func makeStore(filename: String) throws -> BuzzEventStore {
        let path = try storeDirectory().appendingPathComponent(filename).path
        return try BuzzEventStore(path: path)
    }

    /// The content-addressed media directory paired with one community database.
    static func makeMediaStagingStore(filename: String) throws -> MediaStagingStore {
        let directory = try storeDirectory()
            .appendingPathComponent("media-staging", isDirectory: true)
            .appendingPathComponent(filename, isDirectory: true)
        return MediaStagingStore(directory: directory)
    }

    /// Deletes a community's database, staged media, and the two files SQLite keeps beside it.
    ///
    /// The WAL and the shared-memory file are not incidental: a WAL holds committed pages
    /// that have not been checkpointed into the main file yet, so deleting `store.sqlite`
    /// alone can leave a `-wal` on disk that a later database of the same name would be
    /// asked to recover from. Best effort — a file that is already gone is the outcome this
    /// wants, and there is nothing a reader could do about a refusal.
    static func deleteStore(filename: String) {
        guard let directory = try? storeDirectory() else { return }
        for suffix in ["", "-wal", "-shm"] {
            let url = directory.appendingPathComponent(filename + suffix)
            try? FileManager.default.removeItem(at: url)
        }
        try? makeMediaStagingStore(filename: filename).removeAll()
    }
}
