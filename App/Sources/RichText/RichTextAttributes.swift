import Foundation

/// The semantic payload of a resolved `@`-mention run. Deliberately carries only
/// identity, never presentation: the renderer maps it to accent + weight at draw
/// time (see ``RichTextStyle``), so the value AST stays free of SwiftUI and fully
/// testable as data.
struct MentionToken: Hashable, Sendable {
    /// The mentioned user's public key, resolved from the message's own `p` tags.
    /// Optional to leave room for a future "styled but unlinked" token; the entity
    /// pass only ever attaches this attribute when resolution succeeded, so it is
    /// populated in practice.
    let pubkey: String?
    /// Whether the mentioned pubkey is the local identity — the stronger-treatment
    /// gate (bolder + stronger accent).
    let isSelf: Bool
    /// Whether the mentioned pubkey is an agent — the gate for drawing the
    /// ``AgentGlyph`` in place of the `@`, matching both official clients.
    ///
    /// Unlike `pubkey` and `isSelf` this is not a fact about the *message*: a `p` tag
    /// says who was mentioned, never what they are. It is resolved from the roster and
    /// the agent directory at the same seam `isSelf` reads the local identity through,
    /// and ``MessageMentionResolver`` folds it into its memo key so a render is not
    /// reused across a change to it.
    let isAgent: Bool

    /// Defaulted because the overwhelming majority of mentions are of people, and
    /// every call site that predates the glyph means exactly that.
    init(pubkey: String?, isSelf: Bool, isAgent: Bool = false) {
        self.pubkey = pubkey
        self.isSelf = isSelf
        self.isAgent = isAgent
    }
}

/// The semantic payload of a resolved `#`-channel run.
struct ChannelToken: Hashable, Sendable {
    /// The referenced channel's group id, resolved from the app-wide name→id map.
    let channelID: String?
}

/// Marks a run as a resolved `@`-mention. A custom `AttributedString` attribute so
/// the token rides inside the same `AttributedString` as the text — one `Text` per
/// block, selectable-adjacent, Dynamic-Type-correct — rather than forcing a custom
/// layout pass.
enum MentionAttribute: AttributedStringKey {
    typealias Value = MentionToken
    static let name = "com.buzz.hive.mention"
}

/// Marks a run as a resolved `#`-channel reference. See ``MentionAttribute``.
enum ChannelAttribute: AttributedStringKey {
    typealias Value = ChannelToken
    static let name = "com.buzz.hive.channel"
}

/// Marks a run that was wrapped in `<u>…</u>`.
///
/// Its own attribute rather than SwiftUI's `underlineStyle` because the parse stage is
/// deliberately free of SwiftUI: the value AST carries what the author *meant* and
/// ``RichTextStyle`` decides what that looks like, exactly as it already does for a
/// mention. `InlinePresentationIntent` cannot carry it — CommonMark has no underline,
/// so there is no intent to reuse.
enum UnderlineAttribute: AttributedStringKey {
    typealias Value = Bool
    static let name = "com.buzz.hive.underline"
}

extension AttributeScopes {
    /// The app's custom attribute scope: mention and channel entity tokens plus the
    /// `<u>` underline, layered beside Foundation's own attributes (inline
    /// presentation intent, link) that the parser also sets.
    struct HiveAttributes: AttributeScope {
        let mention: MentionAttribute
        let channel: ChannelAttribute
        let underline: UnderlineAttribute
    }

    var hive: HiveAttributes.Type { HiveAttributes.self }
}

extension AttributeDynamicLookup {
    /// Enables `run.mention` / `run.channel` and `attributed[range].mention = …`
    /// dynamic-member access for the custom scope, coexisting with Foundation's and
    /// SwiftUI's own attribute subscripts.
    subscript<T: AttributedStringKey>(
        dynamicMember keyPath: KeyPath<AttributeScopes.HiveAttributes, T>
    ) -> T {
        self[T.self]
    }
}
