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

extension AttributeScopes {
    /// The app's custom attribute scope: mention and channel entity tokens, layered
    /// beside Foundation's own attributes (inline presentation intent, link) that
    /// the parser also sets.
    struct HiveAttributes: AttributeScope {
        let mention: MentionAttribute
        let channel: ChannelAttribute
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
