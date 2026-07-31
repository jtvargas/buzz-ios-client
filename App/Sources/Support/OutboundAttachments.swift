import BuzzKit

/// How a message carries the pictures attached to it.
///
/// # Twice, on purpose
///
/// Every attachment goes out in two places: an `imeta` **tag** describing it
/// (NIP-92 — type, hash, size, dimensions, blurhash, thumbnail) and a markdown
/// **reference** in the body. Neither is redundant. The tag is what lets a client
/// reserve the right space before a byte of the picture has arrived — the reason
/// ``BuzzKit/MessageMedia`` cares about `dim` at all — and the body reference is
/// what a client that has never heard of `imeta` still renders, and what decides
/// *where* in the message the picture sits.
///
/// This is the mobile client's `_ComposeDraftPayload.fromDraft`
/// (`buzz/mobile/lib/features/channels/compose_bar/attachments.dart`), which both
/// clients' messages are read against.
///
/// # One deliberate difference
///
/// The mobile client appends `"\n" + reference` per attachment unconditionally, so
/// a picture sent with no words leaves a newline at the start of the body. Here
/// the parts are joined instead, so that message is just the reference. The
/// rendered result is the same and the wire format is tidier; nothing downstream
/// distinguishes them.
enum OutboundAttachments {
    /// The message body: the author's text, then one markdown reference per
    /// attachment, each on its own line.
    static func content(_ text: String, attaching descriptors: [BlobDescriptor]) -> String {
        ([text] + descriptors.map { $0.markdownReference() })
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// The `imeta` tags to hang on the event, in the order the pictures were
    /// picked — the same order their references appear in the body, which is what
    /// lets a reader match one to the other.
    static func tags(attaching descriptors: [BlobDescriptor]) -> [[String]] {
        descriptors.map { $0.imetaTag() }
    }
}
