import BuzzKit
import Foundation

/// The words a ``SystemNotice`` reads as, in the second person where the reader is
/// one of the people involved.
///
/// Split from the view and given no SwiftUI at all, because the interesting part is
/// grammar rather than layout: which name goes first, and what changes when the name
/// is the reader's own. Those are the cases worth a test, and a test should not have
/// to render anything to read them.
///
/// # Where this agrees with Desktop, and where it does not
///
/// The sentences are Desktop's, so the same event reads the same on both clients
/// (`desktop/src/features/messages/ui/SystemMessageRow.tsx`): *joined the channel*,
/// *was added by*, *left the channel*, *removed … from the channel*.
///
/// The second person is where it diverges, deliberately. Desktop substitutes the
/// literal "You" wherever the reader's own key appears, which produces "You was added
/// by JT" and "JT removed You from the channel". This conjugates instead — *You were
/// added by JT* — and uses the object form in object position, because the alternative
/// is a sentence about the reader that is not in their language.
struct SystemNoticeSentence: Hashable {
    /// One stretch of the sentence. Names are marked so the view can give them the
    /// weight Slack gives them, without this file knowing what a font is.
    struct Run: Hashable {
        let text: String
        let isName: Bool

        static func name(_ text: String) -> Run { Run(text: text, isName: true) }
        static func words(_ text: String) -> Run { Run(text: text, isName: false) }
    }

    let runs: [Run]

    /// The whole sentence as one string — what VoiceOver reads, and what a test
    /// asserts.
    var plain: String { runs.map(\.text).joined() }

    /// Builds the sentence for `notice`.
    ///
    /// - Parameters:
    ///   - name: resolves a pubkey to the name to show. The app hands over
    ///     ``EntityNames/name(for:)``, which never returns a raw key.
    ///   - selfPubkey: the reader's own key, or `nil` when there is none — a keyless
    ///     session then reads every notice in the third person, which is true for it.
    init(_ notice: SystemNotice, name: (String) -> String, selfPubkey: String?) {
        // Nested functions rather than closures bound to `let`: a closure value would
        // have to be `@escaping` to capture `name`, and `name` is deliberately not —
        // nothing here outlives the initialiser.
        func isSelf(_ pubkey: String) -> Bool {
            guard let selfPubkey else { return false }
            return pubkey.caseInsensitiveCompare(selfPubkey) == .orderedSame
        }
        // Subject position takes "You"; object position takes "you". Both are names as
        // far as the view is concerned, so the reader is emphasised the same way
        // everybody else is.
        func subject(_ pubkey: String) -> String { isSelf(pubkey) ? "You" : name(pubkey) }
        func object(_ pubkey: String) -> String { isSelf(pubkey) ? "you" : name(pubkey) }

        switch notice {
        case let .memberJoined(actor, target) where actor.caseInsensitiveCompare(target) == .orderedSame:
            runs = [.name(subject(target)), .words(" joined the channel")]
        case let .memberJoined(actor, target):
            // "was" or "were" by who the target is: the verb agrees with the subject,
            // and the subject here is whoever was added.
            let verb = isSelf(target) ? " were added by " : " was added by "
            runs = [.name(subject(target)), .words(verb), .name(object(actor))]
        case let .memberLeft(actor):
            runs = [.name(subject(actor)), .words(" left the channel")]
        case let .memberRemoved(actor, target):
            runs = [
                .name(subject(actor)),
                .words(" removed "),
                .name(object(target)),
                .words(" from the channel"),
            ]
        }
    }
}
