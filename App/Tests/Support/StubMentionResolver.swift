@testable import Hive

/// A controllable ``MentionResolver`` test double: fixed name→match and name→channel
/// tables plus an overridable identity, so the pure parser + entity pass can be
/// tested as values without a store. Keys are normalised on the way in exactly as
/// the production resolver normalises them, so a test can register `"Ada Lovelace"`
/// and the scan's `"ada lovelace"` candidate still matches.
struct StubMentionResolver: MentionResolver {
    private let members: [String: MentionMatch]
    private let channels: [String: String]
    let selfPubkey: String?
    let identity: String

    init(
        members: [String: MentionMatch] = [:],
        channels: [String: String] = [:],
        selfPubkey: String? = nil,
        identity: String = "stub"
    ) {
        self.members = Dictionary(
            members.map { (RichTextName.normalized($0.key), $0.value) },
            uniquingKeysWith: { first, _ in first }
        )
        self.channels = Dictionary(
            channels.map { (RichTextName.normalized($0.key), $0.value) },
            uniquingKeysWith: { first, _ in first }
        )
        self.selfPubkey = selfPubkey
        self.identity = identity
    }

    func mention(forName name: String) -> MentionMatch? {
        members[RichTextName.normalized(name)]
    }

    func channel(forName name: String) -> String? {
        channels[RichTextName.normalized(name)]
    }
}
