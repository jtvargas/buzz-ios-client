import BuzzKit
import Foundation

/// A selected mention embedded in an editable draft. The UTF-16 range matches
/// UIKit's text-system coordinates and covers the visible `@Display Name` token
/// (the trailing space is deliberately outside the token).
struct ComposerMentionToken: Hashable, Sendable, Identifiable {
    let pubkey: String
    let displayName: String
    var range: NSRange

    var id: String { "\(pubkey):\(range.location)" }
}

/// Plain wire text plus the identity-bearing mention tokens the composer inserted.
struct MentionDraft: Hashable, Sendable {
    var text: String
    private(set) var tokens: [ComposerMentionToken]

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
    /// whole token. Returns the UTF-16 cursor location after the replacement.
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
        return actualRange.location + replacementLength
    }

    mutating func insert(_ candidate: MentionCandidateProfile, replacing range: NSRange) {
        let visible = "@\(candidate.displayName)"
        replaceCharacters(in: range, with: visible + " ")
        tokens.append(ComposerMentionToken(
            pubkey: candidate.pubkey.lowercased(),
            displayName: candidate.displayName,
            range: NSRange(location: range.location, length: (visible as NSString).length)
        ))
        tokens.sort { $0.range.location < $1.range.location }
    }

    /// The trailing, still-editing `@query`, if one exists. A completed selected
    /// token does not reopen the panel merely because its trailing space remains.
    func trailingMention() -> (range: NSRange, query: String)? {
        let nsText = text as NSString
        guard nsText.length > 0 else { return nil }
        let full = NSRange(location: 0, length: nsText.length)
        let at = nsText.range(of: "@", options: .backwards, range: full)
        guard at.location != NSNotFound else { return nil }

        if at.location > 0 {
            let prior = nsText.substring(with: NSRange(location: at.location - 1, length: 1))
            guard prior.rangeOfCharacter(from: .whitespacesAndNewlines) != nil else { return nil }
        }

        let suffixRange = NSRange(location: at.location, length: nsText.length - at.location)
        let suffix = nsText.substring(with: suffixRange)
        guard !suffix.contains("\n"), !suffix.contains("  ") else { return nil }
        if let selected = tokens.first(where: { $0.range.location == at.location }),
           NSMaxRange(selected.range) <= nsText.length,
           nsText.substring(from: NSMaxRange(selected.range)).allSatisfy(\.isWhitespace) {
            return nil
        }

        return (suffixRange, String(suffix.dropFirst()).trimmingCharacters(in: .whitespaces))
    }

    func mentionedPubkeys(sender: String?) -> [String] {
        let sender = sender?.lowercased()
        var seen = Set<String>()
        var result: [String] = []
        for token in tokens {
            let pubkey = token.pubkey.lowercased()
            guard pubkey != sender, seen.insert(pubkey).inserted else { continue }
            result.append(pubkey)
            if result.count == 50 { break }
        }
        return result
    }
}
