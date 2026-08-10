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
/// # Subject and predicate, not one string
///
/// The row draws the subject's name in a header — beside their face and the time, where
/// a message's author goes — and the predicate on the line under it. So this splits the
/// sentence the same way: ``title`` is the name, ``action`` is what happened, and the
/// action never repeats the name. ``plain`` puts them back together for VoiceOver.
///
/// # Where this agrees with Desktop, and where it does not
///
/// The sentences are Desktop's, so the same event reads the same on both clients
/// (`desktop/src/features/messages/ui/SystemMessageRow.tsx`): *joined the channel*,
/// *was added by*, *left the channel*, *removed … from the channel*, *changed the topic
/// to …*, *created this channel*, *archived*/*unarchived this channel*.
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

    /// The name the row's header carries: whoever the notice is *about*
    /// (``SystemNotice/subject``), in the reader's own person.
    let title: String

    /// The predicate, drawn on the line under the header. It does not repeat the
    /// subject — "was added by JT", not "Echo was added by JT" — because the header
    /// above it has already said who.
    let action: [Run]

    /// The whole sentence as one string — what VoiceOver reads, and what a test
    /// asserts. Subject and predicate rejoined, because a reader by ear has no header
    /// to look up at.
    var plain: String { title + " " + action.map(\.text).joined() }

    /// How many of the people in a collapsed arrival are named before the rest become a
    /// count. Three, the reference clients' number: four names is a sentence a reader
    /// still parses, and the fifth is where it becomes a list.
    static let maxNamedArrivals = 3

    /// Builds the sentence for `notice`.
    ///
    /// - Parameters:
    ///   - alsoJoined: the other people who arrived in the same breath, when
    ///     ``ConversationGrouping`` collapsed a run of arrivals into one row. Empty for
    ///     every other notice — only an arrival can be shared.
    ///   - name: resolves a pubkey to the name to show. The app hands over
    ///     ``EntityNames/name(for:)``, which never returns a raw key.
    ///   - selfPubkey: the reader's own key, or `nil` when there is none — a keyless
    ///     session then reads every notice in the third person, which is true for it.
    init(_ notice: SystemNotice, alsoJoined: [String] = [], name: (String) -> String, selfPubkey: String?) {
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

        title = subject(notice.subject)

        func alongWith(lead: String) -> [Run] {
            Self.alongWith(alsoJoined, lead: lead, object: object)
        }

        switch notice {
        case let .memberJoined(actor, target) where actor.caseInsensitiveCompare(target) == .orderedSame:
            action = [.words("joined the channel")] + alongWith(lead: " along with ")
        case let .memberJoined(actor, target):
            // "was" or "were" by who the target is: the verb agrees with the subject,
            // and the subject here is whoever was added.
            let verb = isSelf(target) ? "were added by " : "was added by "
            action = [.words(verb), .name(object(actor))] + alongWith(lead: ", along with ")
        case let .memberRemoved(_, target):
            action = [
                .words("removed "),
                .name(object(target)),
                .words(" from the channel"),
            ]
        default:
            action = Self.unaccompaniedAction(for: notice)
        }
    }

    /// Every notice whose predicate names nobody but its own subject — which is all of
    /// them except an arrival, which can be shared, and a removal, which points at the
    /// person removed.
    ///
    /// Split out because the initialiser is a switch over every notice the app has, so it
    /// is the thing that grows: three notices ago it was under the complexity ceiling and
    /// the huddle pair took it over. Cases that need no name resolution have no business
    /// being in there.
    private static func unaccompaniedAction(for notice: SystemNotice) -> [Run] {
        switch notice {
        case .memberLeft:
            [.words("left the channel")]
        case let .topicChanged(_, topic):
            // Curly quotes, and the topic is not a name: it is the thing said, not
            // somebody said it, so it takes the body weight the rest of the predicate
            // has rather than the emphasis a person's name gets.
            [.words("changed the topic to \u{201C}\(topic)\u{201D}")]
        case let .purposeChanged(_, purpose):
            [.words("changed the purpose to \u{201C}\(purpose)\u{201D}")]
        case .channelCreated:
            [.words("created this channel")]
        case .channelArchived:
            [.words("archived this channel")]
        case .channelUnarchived:
            [.words("unarchived this channel")]
        case .huddleStarted:
            // The Flutter client's wording, matched exactly
            // (`mobile/lib/features/channels/timeline_message.dart:111`): the same event
            // read on two clients should read the same, and neither should have to guess
            // what the other says.
            [.words("started a huddle")]
        case .huddleEnded:
            // "the huddle" rather than "a huddle" — by the time one ends there is a
            // particular one to point at.
            [.words("ended the huddle")]
        case .memberJoined, .memberRemoved:
            // Handled by the initialiser, which has the name resolution these two need.
            // Listed rather than defaulted so a notice added later fails to compile here
            // instead of silently rendering as an empty predicate.
            []
        }
    }

    /// The others, as *", along with A, B and 2 others"* — or nothing at all when this
    /// arrival was not shared. `lead` is the punctuation that joins it to the clause
    /// before, which differs between the two arrival sentences.
    ///
    /// Lifted out of the initialiser rather than nested in it: a nested function's
    /// branches count towards the enclosing one, and the initialiser is a switch over
    /// every notice the app has, so it is the thing that grows.
    private static func alongWith(_ alsoJoined: [String], lead: String, object: (String) -> String) -> [Run] {
        guard !alsoJoined.isEmpty else { return [] }
        let named = alsoJoined.prefix(maxNamedArrivals)
        let hidden = alsoJoined.count - named.count
        var runs: [Run] = [.words(lead)]
        for (index, pubkey) in named.enumerated() {
            if index > 0 {
                // "A and B" for a pair, "A, B, and C" for more — and always a comma
                // before a trailing "and N others", which is not one of the names.
                let isLast = index == named.count - 1 && hidden == 0
                runs.append(.words(isLast ? (named.count == 2 ? " and " : ", and ") : ", "))
            }
            runs.append(.name(object(pubkey)))
        }
        if hidden > 0 {
            // A count, not a name: nobody is being pointed at, so it takes body weight
            // like the rest of the predicate. Singular at one, which both reference
            // clients skip — they print "1 others" — and which costs nothing to get right.
            runs.append(.words(", and \(hidden) \(hidden == 1 ? "other" : "others")"))
        }
        return runs
    }
}
