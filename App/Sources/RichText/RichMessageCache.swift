import Foundation

extension RichMessage {
    /// Parses `text` into blocks and resolves its entities against `resolver`. The
    /// full pipeline, done as one value transform: parse (pure) → entity pass (pure).
    static func make(_ text: String, resolver: MentionResolver) -> RichMessage {
        let blocks = RichTextParser.parse(text)
        let resolved = RichTextEntities.resolve(blocks, with: resolver)
        return RichMessage(blocks: resolved)
    }
}

/// A bounded main-actor memo over ``RichMessage/make(_:resolver:)`` so scrolling a
/// long timeline never re-parses or re-resolves the same content: a row that leaves
/// and re-enters the viewport reuses the message it produced before.
///
/// Keyed on `(resolverIdentity, text)`, not text alone — a profile/roster change or
/// an identity switch changes the resolver's identity, so the same text re-resolves
/// instead of serving a stale render. Cheap to get wrong (a text-only key would
/// freeze a mention's name at first sight); this gets it right.
@MainActor
enum RichMessageCache {
    /// A structured cache key keeps identity and content as separate fields. Message
    /// text and profile/channel names are untrusted and may contain any scalar, so a
    /// delimiter-joined string cannot represent the pair without collisions.
    private final class Key: NSObject {
        let resolverIdentity: String
        let text: String

        init(resolverIdentity: String, text: String) {
            self.resolverIdentity = resolverIdentity
            self.text = text
        }

        override var hash: Int {
            var hasher = Hasher()
            hasher.combine(resolverIdentity)
            hasher.combine(text)
            return hasher.finalize()
        }

        override func isEqual(_ object: Any?) -> Bool {
            guard let other = object as? Key else { return false }
            return resolverIdentity == other.resolverIdentity && text == other.text
        }
    }

    private final class Box {
        let message: RichMessage
        init(_ message: RichMessage) { self.message = message }
    }

    private static let cache: NSCache<Key, Box> = {
        let cache = NSCache<Key, Box>()
        cache.countLimit = 256
        return cache
    }()

    static func message(for text: String, resolver: MentionResolver) -> RichMessage {
        let key = Key(resolverIdentity: resolver.identity, text: text)
        if let cached = cache.object(forKey: key) { return cached.message }
        let message = RichMessage.make(text, resolver: resolver)
        cache.setObject(Box(message), forKey: key)
        return message
    }

    /// Drops every cached message. For tests that assert re-resolution without
    /// relying on key distinctness.
    static func removeAll() {
        cache.removeAllObjects()
    }
}
