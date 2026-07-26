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

/// The still-being-typed token at the end of a draft: what the panel is completing,
/// and what an insertion replaces.
struct TrailingMention: Hashable, Sendable {
    /// The UTF-16 range an insertion replaces — the trigger plus everything typed
    /// after it.
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
    /// Identical for every kind — the label goes in the text, the identity goes in
    /// ``tokens`` — so a channel reference and a person reference are the same edit
    /// with a different trigger. Returns the caret location.
    @discardableResult
    mutating func insert(_ suggestion: MentionSuggestion, replacing range: NSRange) -> Int {
        let visible = suggestion.insertionLabel
        let visibleLength = (visible as NSString).length
        let before = text
        let cursor = replaceCharacters(in: range, with: visible + " ")
        // `replaceCharacters` refuses an out-of-bounds range and leaves the text alone.
        // Appending a token then would claim a label the text does not contain — and, for
        // a person, tag someone the message never names. Nothing reachable does this
        // today; the guard is here so a future caller cannot make it reachable silently.
        guard text != before else { return cursor }
        // Located back from the caret rather than from `range`: `replaceCharacters`
        // widens an edit that touched an existing token, so the inserted run may not
        // start where the caller asked. Back off the label and its one space.
        let start = max(0, cursor - visibleLength - 1)
        tokens.append(ComposerMentionToken(
            kind: suggestion.kind,
            entityID: suggestion.entityID,
            displayName: suggestion.label,
            range: NSRange(location: start, length: visibleLength)
        ))
        tokens.sort { $0.range.location < $1.range.location }
        return cursor
    }

    /// The trailing, still-editing `@query` or `#query`, if one exists.
    ///
    /// The *latest* trigger wins, so `@ada #gen` is completing a channel and not a
    /// person. Four rules stop the panel from opening over text that is not a
    /// mention: a trigger must open a word (`mail@test` and `C#` are not mentions);
    /// a query may not *start* with a space, so the markdown heading `# Title` is a
    /// heading (a bare trigger with nothing after it still opens the full list); a
    /// newline ends the token; and **two consecutive spaces** end it — one internal
    /// space is allowed so a multi-word name can still be completed, but a double
    /// space means the author moved on. A completed token does not reopen the panel
    /// merely because its own trailing space remains.
    func trailingMention() -> TrailingMention? {
        let nsText = text as NSString
        guard nsText.length > 0 else { return nil }
        let full = NSRange(location: 0, length: nsText.length)

        var latest: (location: Int, kind: MentionKind)?
        for kind in MentionKind.allCases {
            let hit = nsText.range(of: String(kind.trigger), options: .backwards, range: full)
            guard hit.location != NSNotFound else { continue }
            if let latest, latest.location >= hit.location { continue }
            latest = (hit.location, kind)
        }
        guard let trigger = latest else { return nil }

        if trigger.location > 0 {
            let prior = nsText.substring(with: NSRange(location: trigger.location - 1, length: 1))
            guard prior.rangeOfCharacter(from: .whitespacesAndNewlines) != nil else { return nil }
        }

        let suffixRange = NSRange(
            location: trigger.location,
            length: nsText.length - trigger.location
        )
        let suffix = nsText.substring(with: suffixRange)
        guard !suffix.contains("\n"), !suffix.contains("\t"), !suffix.contains("  ") else { return nil }
        let query = String(suffix.dropFirst())
        guard query.first?.isWhitespace != true else { return nil }

        // An already-inserted token is never re-completed. This is a *range* test, not
        // a comparison against the token's start, because both of the ways it used to be
        // wrong were reachable: a display name or channel name containing a trigger
        // (`@Ada @ Acme`, `#design #2`) put the trigger *inside* a token and offered to
        // complete a fragment of it, and one more typed word after a finished `@Ada`
        // re-opened the panel on `Ada Lovelace` — and selecting from either rewrote the
        // token, silently swapping which person the message tags.
        let touchesToken = tokens.contains { token in
            NSLocationInRange(trigger.location, token.range)
                || NSIntersectionRange(suffixRange, token.range).length > 0
        }
        guard !touchesToken else { return nil }

        return TrailingMention(
            range: suffixRange,
            query: query.trimmingCharacters(in: .whitespaces),
            kind: trigger.kind
        )
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
}
