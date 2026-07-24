import NostrCore

/// Buzz domain layer: Buzz kinds and tags, channel/thread/reaction/profile
/// models, NIP-CW window client, SyncEngine, Outbox, GRDB persistence.
///
/// Boundary rule: this package never touches the socket or URLSession
/// directly — transport comes from NostrCore.
public enum BuzzKit {
    public static let version = NostrCore.version
}
