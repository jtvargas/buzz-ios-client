import BuzzKit
import Foundation

/// A selected mention embedded in an editable draft. The UTF-16 range matches
/// UIKit's text-system coordinates and covers the visible `@Display Name` /
/// `#channel` token (the trailing space is deliberately outside the token).
struct ComposerMentionToken: Hashable, Sendable, Identifiable {
    /// Whether this token names a person or a channel. Only a person tags.
    let kind: MentionKind
    /// The identity the token stands for, kept out of the visible text: a lowercased
    /// hex pubkey for a person, a channel group id for a channel.
    let entityID: String
    /// The name as inserted, without the trigger character.
    let displayName: String
    var range: NSRange

    var id: String { "\(kind.trigger)\(entityID):\(range.location)" }

    /// The mentioned pubkey, or `nil` for a channel token — the one place the
    /// "channels do not tag" rule is expressed.
    var pubkey: String? { kind == .user ? entityID : nil }
}

/// The still-being-typed token the caret sits inside: what the panel is completing,
/// and what an insertion replaces.
struct ActiveMention: Hashable, Sendable {
    /// The UTF-16 range an insertion replaces — the trigger, and everything between it
    /// and the caret. Never anything after the caret.
    let range: NSRange
    /// The typed query without its trigger, trimmed. Empty for a bare trigger, which
    /// opens the full list.
    let query: String
    /// Which trigger opened the token, and therefore which index is searched.
    let kind: MentionKind
}

/// Plain wire text plus the identity-bearing mention tokens the composer inserted.
struct MentionDraft: Hashable, Sendable {
    var text: String
    private(set) var tokens: [ComposerMentionToken]
    /// Where the caret belongs after the edit that produced this draft, in UTF-16
    /// units, or `nil` for a draft nobody has edited (a fresh or restored one).
    ///
    /// The draft carries it because the *editor* cannot recover it: when SwiftUI hands
    /// `TokenTextView` a document whose text it has not rendered yet, the text view's
    /// own `selectedRange` still describes the pre-edit string. Placing the caret from
    /// that stale value is what put it inside a just-inserted mention instead of after
    /// the space following it.
    private(set) var preferredCursor: Int?

    init(text: String = "", tokens: [ComposerMentionToken] = []) {
        self.text = text
        self.tokens = tokens
    }

    /// Whether UIKit must hand this edit back to us instead of applying it
    /// natively. Ordinary typing stays on UITextView's fast path; only an edit
    /// inside or across a selected mention needs expansion to the whole token.
    func requiresAtomicEdit(in editRange: NSRange) -> Bool {
        tokens.contains { token in
            if editRange.length == 0 {
                return editRange.location > token.range.location
                    && editRange.location < NSMaxRange(token.range)
            }
            return NSIntersectionRange(editRange, token.range).length > 0
        }
    }

    /// Reconciles a system-originated whole-text update (for example dictation)
    /// as one minimal UTF-16 edit so mention ranges shift or delete atomically.
    @discardableResult
    mutating func reconcileText(_ updatedText: String) -> Int {
        let old = text as NSString
        let new = updatedText as NSString
        var prefix = 0
        while prefix < old.length, prefix < new.length,
              old.character(at: prefix) == new.character(at: prefix) {
            prefix += 1
        }

        var suffix = 0
        while suffix < old.length - prefix, suffix < new.length - prefix,
              old.character(at: old.length - suffix - 1)
                == new.character(at: new.length - suffix - 1) {
            suffix += 1
        }

        let oldRange = NSRange(location: prefix, length: old.length - prefix - suffix)
        let replacement = new.substring(with: NSRange(
            location: prefix,
            length: new.length - prefix - suffix
        ))
        return replaceCharacters(in: oldRange, with: replacement)
    }

    /// Applies one UIKit edit, expanding any edit that touches a mention to the
    /// whole token. Returns the UTF-16 cursor location after the replacement, and
    /// records it as ``preferredCursor`` so a re-render lands the caret there.
    @discardableResult
    mutating func replaceCharacters(in editRange: NSRange, with replacement: String) -> Int {
        let length = (text as NSString).length
        guard editRange.location <= length, NSMaxRange(editRange) <= length else {
            return min(editRange.location, length)
        }

        let touched = tokens.filter { token in
            if editRange.length == 0 {
                return editRange.location > token.range.location
                    && editRange.location < NSMaxRange(token.range)
            }
            return NSIntersectionRange(editRange, token.range).length > 0
        }
        let actualRange = touched.reduce(editRange) { NSUnionRange($0, $1.range) }
        let replacementLength = (replacement as NSString).length
        let delta = replacementLength - actualRange.length

        text = (text as NSString).replacingCharacters(in: actualRange, with: replacement)
        tokens = tokens.compactMap { token in
            if touched.contains(where: { $0.id == token.id }) { return nil }
            var shifted = token
            if token.range.location >= NSMaxRange(actualRange) {
                shifted.range.location += delta
            }
            return shifted
        }
        let cursor = actualRange.location + replacementLength
        preferredCursor = cursor
        return cursor
    }

    /// Inserts `suggestion` over the token being typed: the visible label, then
    /// exactly one space, with the caret left after that space.
    ///
    /// Only the token's own range is replaced, so everything before and after it
    /// survives — a mention completed in the middle of a sentence leaves the rest of the
    /// sentence alone. **Exactly one** space follows the label: when the text already
    /// carries one at the insertion point, which is the everyday case for a mention
    /// completed mid-sentence, that space is the one, and appending a second would leave
    /// the author a gap to go back and delete.
    ///
    /// Identical for every kind — the label goes in the text, the identity goes in
    /// ``tokens`` — so a channel reference and a person reference are the same edit
    /// with a different trigger. Returns the caret location.
    @discardableResult
    mutating func insert(_ suggestion: MentionSuggestion, replacing range: NSRange) -> Int {
        let visible = suggestion.insertionLabel
        let visibleLength = (visible as NSString).length
        let before = text
        let labelEnd = replaceCharacters(in: range, with: visible)
        // `replaceCharacters` refuses an out-of-bounds range and leaves the text alone.
        // Appending a token then would claim a label the text does not contain — and, for
        // a person, tag someone the message never names. Nothing reachable does this
        // today; the guard is here so a future caller cannot make it reachable silently.
        guard text != before else { return labelEnd }
        // Located back from the caret rather than from `range`: `replaceCharacters`
        // widens an edit that touched an existing token, so the inserted run may not
        // start where the caller asked.
        let start = max(0, labelEnd - visibleLength)
        tokens.append(ComposerMentionToken(
            kind: suggestion.kind,
            entityID: suggestion.entityID,
            displayName: suggestion.label,
            range: NSRange(location: start, length: visibleLength)
        ))
        tokens.sort { $0.range.location < $1.range.location }

        // Read back from the text rather than from the caller's range, so a widened
        // replacement cannot leave the decision resting on a character that moved.
        let nsText = text as NSString
        let followedBySpace = labelEnd < nsText.length && nsText.character(at: labelEnd) == Self.space
        // Appending at the label's end shifts nothing: the edit is empty and sits *at*
        // the token's upper bound, which is outside it.
        let cursor = followedBySpace
            ? labelEnd + 1
            : replaceCharacters(in: NSRange(location: labelEnd, length: 0), with: " ")
        preferredCursor = cursor
        return cursor
    }

    /// The `@query` or `#query` the caret is inside, if any.
    ///
    /// Anchored to the caret and not to the end of the draft, which is the whole
    /// difference between a mention that only works on the last word of the last line
    /// and one that works anywhere. The token starts at the nearest trigger *before*
    /// `cursor` and ends *at* `cursor`, so text after the caret — more words, more
    /// lines, another mention — cannot affect the query or close the panel.
    ///
    /// Scanning backwards is also what makes it cheap enough to run on every keystroke:
    /// it stops at the first delimiter instead of searching the whole draft, and gives
    /// up entirely past ``maxTokenLength`` so a long line cannot turn a keypress into a
    /// walk over the draft on the main actor.
    ///
    /// Five rules stop the panel from opening over text that is not a mention: a
    /// trigger must open a word (`mail@test` and `C#` are not mentions, and neither is
    /// anything further back — the word the caret is in is already spoken for); a query
    /// may not *start* with a space, so the markdown heading `# Title` is a heading (a
    /// bare trigger still opens the full list); a line break or a tab ends the token;
    /// **two consecutive spaces** end it — one internal space is allowed so a
    /// multi-word display name can still be completed, but a double space means the
    /// author moved on; and an already-inserted token is never re-completed.
    func activeMention(at cursor: Int) -> ActiveMention? {
        let nsText = text as NSString
        let caret = min(max(cursor, 0), nsText.length)
        let floor = max(0, caret - Self.maxTokenLength)

        var index = caret - 1
        while index >= floor {
            let unit = nsText.character(at: index)
            if let kind = MentionKind(utf16Unit: unit) {
                return mention(kind: kind, triggerAt: index, caret: caret, in: nsText)
            }
            // A tab and a line break both end a token. Both arrive from a hardware
            // keyboard and from a paste, and a token that swallowed one would offer to
            // complete a query spanning two fields of pasted text.
            if Self.endsToken(unit) { return nil }
            // One internal space is allowed; the second means the author moved on.
            if unit == Self.space, index > 0, nsText.character(at: index - 1) == Self.space {
                return nil
            }
            index -= 1
        }
        return nil
    }

    /// The active mention with the caret at the very end of the draft — the state a
    /// draft nobody has edited is in (a fresh one, or one restored after a failed send),
    /// and the caret ``TokenTextView`` places when it first renders one.
    func trailingMention() -> ActiveMention? {
        activeMention(at: (text as NSString).length)
    }

    /// Validates a candidate trigger the backward scan reached, and builds the token.
    private func mention(
        kind: MentionKind,
        triggerAt trigger: Int,
        caret: Int,
        in nsText: NSString
    ) -> ActiveMention? {
        if trigger > 0 {
            let prior = nsText.substring(with: NSRange(location: trigger - 1, length: 1))
            guard prior.rangeOfCharacter(from: .whitespacesAndNewlines) != nil else { return nil }
        }

        let range = NSRange(location: trigger, length: caret - trigger)
        let query = nsText.substring(with: NSRange(
            location: trigger + 1,
            length: caret - trigger - 1
        ))
        guard query.first?.isWhitespace != true else { return nil }

        // An already-inserted token is never re-completed. This is a *range* test, not
        // a comparison against the token's start, because both of the ways it used to be
        // wrong were reachable: a display name or channel name containing a trigger
        // (`@Ada @ Acme`, `#design #2`) put the trigger *inside* a token and offered to
        // complete a fragment of it, and one more typed word after a finished `@Ada`
        // re-opened the panel on `Ada Lovelace` — and selecting from either rewrote the
        // token, silently swapping which person the message tags. The trigger itself
        // needs no separate check: the range starts there and is never empty.
        let touchesToken = tokens.contains { token in
            NSIntersectionRange(range, token.range).length > 0
        }
        guard !touchesToken else { return nil }

        return ActiveMention(
            range: range,
            query: query.trimmingCharacters(in: .whitespaces),
            kind: kind
        )
    }

    /// How far back the scan looks for a trigger, in UTF-16 units. A query longer than
    /// this matches nothing anyway, and the bound is what keeps the per-keystroke cost
    /// independent of how long the draft has grown.
    static let maxTokenLength = 128

    private static let space: unichar = 0x20

    /// Whether this unit ends a token outright — any line break, or a tab.
    private static func endsToken(_ unit: unichar) -> Bool {
        if unit == 0x09 { return true }
        guard let scalar = UnicodeScalar(unit) else { return false }
        return CharacterSet.newlines.contains(scalar)
    }

    /// The `p`-tag recipients this draft mentions: **people only**. A channel token
    /// contributes nothing here — it is a reference in the text, not a notification.
    func mentionedPubkeys(sender: String?) -> [String] {
        let sender = sender?.lowercased()
        var seen = Set<String>()
        var result: [String] = []
        for token in tokens {
            guard let pubkey = token.pubkey?.lowercased(),
                  pubkey != sender, seen.insert(pubkey).inserted else { continue }
            result.append(pubkey)
            if result.count == 50 { break }
        }
        return result
    }

    /// A fresh draft carrying this one's agent mentions and nothing else — what the composer
    /// refills with after a send when "Keep agents mentioned" is on.
    ///
    /// Built from ``tokens`` rather than by re-parsing ``text``, so the identity behind each
    /// `@Name` is the one the author actually picked. The label is re-emitted from the token's
    /// own `displayName`, which means a name that has since changed on the relay is reproduced
    /// as it was typed: the token carries the pubkey, so the tag is right either way, and
    /// rewriting the visible text under the author is the worse of the two.
    ///
    /// Agents only. Keeping a *person* mentioned would turn one deliberate ping into one per
    /// reply for the rest of the thread, which is a notification they did not agree to.
    ///
    /// Order and duplicates follow ``mentionedPubkeys(sender:)``: first appearance wins, and a
    /// pubkey named twice seeds once.
    func agentSeed(where isAgent: (String) -> Bool) -> MentionDraft {
        var text = ""
        var seeded: [ComposerMentionToken] = []
        var seen = Set<String>()
        for token in tokens {
            guard token.kind == .user,
                  let pubkey = token.pubkey?.lowercased(),
                  isAgent(pubkey),
                  seen.insert(pubkey).inserted
            else { continue }
            let label = "\(MentionKind.user.trigger)\(token.displayName)"
            let location = (text as NSString).length
            text += label + " "
            seeded.append(ComposerMentionToken(
                kind: .user,
                entityID: token.entityID,
                displayName: token.displayName,
                range: NSRange(location: location, length: (label as NSString).length)
            ))
        }
        return MentionDraft(text: text, tokens: seeded)
    }
}
