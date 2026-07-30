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
}
