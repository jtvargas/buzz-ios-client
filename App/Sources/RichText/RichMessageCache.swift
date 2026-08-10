import BuzzKit
import Foundation

extension RichMessage {
    /// Parses `text` into blocks, lifts out the pictures it places, links what it
    /// contains, resolves its entities against `resolver`, and appends a card for each
    /// link it points at. The full pipeline, done as one value transform: parse (pure) →
    /// media (pure) → autolink (pure) → entity pass (pure) → link previews (pure).
    ///
    /// `media` is what the message's `imeta` tags describe, and it *describes* rather
    /// than contributes: an entry naming a URL the text never places draws nothing. See
    /// ``RichTextMedia``.
    ///
    /// The media stage runs before autolinking so an image node's characters are gone
    /// before anything can make a second, tappable copy of the picture out of them.
    /// Autolinking then runs before the entity pass, not after, so a detected URL or
    /// email is already a link by the time `@`/`#` are scanned — which is what stops
    /// `https://host/#anchor` resolving an anchor as a channel reference.
    ///
    /// The card pass runs last, over the finished blocks, because it reads *links* rather
    /// than text: by then every URL the message contains is a link run and every one it
    /// only appears to contain — inside a code span, inside a fence, under a picture — is
    /// not. See ``RichTextLinkPreview``.
    static func make(_ text: String, media: [MessageMedia] = [], resolver: MentionResolver) -> RichMessage {
        let parsed = RichTextMedia.lift(RichTextParser.parse(text), describedBy: media)
        let blocks = parsed.mapInlines(RichTextAutolink.apply)
        let resolved = RichTextEntities.resolve(blocks, with: resolver)
        return RichMessage(blocks: RichTextLinkPreview.append(to: resolved))
    }
}

/// A bounded main-actor memo over ``RichMessage/make(_:resolver:)`` so scrolling a
/// long timeline never re-parses or re-resolves the same content: a row that leaves
/// and re-enters the viewport reuses the message it produced before.
///
/// Keyed on `(resolverIdentity, text, media)`, not text alone — every input to
/// ``RichMessage/make(_:media:resolver:)`` is in the key, because the memo is only sound
/// if the key names the whole function's domain.
///
/// - A profile/roster change or an identity switch changes the resolver's identity, so
///   the same text re-resolves instead of serving a stale render. Cheap to get wrong (a
///   text-only key would freeze a mention's name at first sight).
/// - The attachments belong in it for a sharper reason: they come from the message's
///   *tags*, and two different messages routinely share their text. `![image](url)` is
///   what a composer writes for every upload, so two photos posted with no caption have
///   byte-identical bodies and different pictures. On a text-only key the second would
///   be served the first one's — the same wrong picture, from cache, on the surface
///   where it is least likely to be noticed as a bug and most likely to be somebody
///   else's photograph.
@MainActor
enum RichMessageCache {
    /// A structured cache key keeps every field separate. Message text, profile and
    /// channel names, and an attachment's URL and alt are all untrusted and may contain
    /// any scalar, so a delimiter-joined string cannot represent the tuple without
    /// collisions.
    private final class Key: NSObject {
        let resolverIdentity: String
        let text: String
        let media: [MessageMedia]

        init(resolverIdentity: String, text: String, media: [MessageMedia]) {
            self.resolverIdentity = resolverIdentity
            self.text = text
            self.media = media
        }

        override var hash: Int {
            var hasher = Hasher()
            hasher.combine(resolverIdentity)
            hasher.combine(text)
            hasher.combine(media)
            return hasher.finalize()
        }

        override func isEqual(_ object: Any?) -> Bool {
            guard let other = object as? Key else { return false }
            return resolverIdentity == other.resolverIdentity
                && text == other.text
                && media == other.media
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

    static func message(
        for text: String,
        media: [MessageMedia] = [],
        resolver: MentionResolver
    ) -> RichMessage {
        let key = Key(resolverIdentity: resolver.identity, text: text, media: media)
        if let cached = cache.object(forKey: key) { return cached.message }
        let message = RichMessage.make(text, media: media, resolver: resolver)
        cache.setObject(Box(message), forKey: key)
        return message
    }

    /// Drops every cached message.
    ///
    /// Said from ``AppCaches`` when the app backgrounds and when a session ends, and by tests
    /// that assert re-resolution without relying on key distinctness. Rendering is a pure
    /// function of the text and the resolver, so an emptied cache costs a re-parse and can
    /// never cost a wrong answer.
    static func removeAll() {
        cache.removeAllObjects()
    }
}
