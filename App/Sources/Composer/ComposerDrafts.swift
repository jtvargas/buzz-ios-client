import BuzzKit
import Foundation

/// Which composer a draft belongs to.
///
/// `rootID` is `nil` for a channel's own composer and the thread's root id inside a
/// thread — the whole requirement in one type. A channel and each of its threads are
/// different keys, so text typed in a thread can never surface in the channel it hangs
/// under, and vice versa.
struct ComposerDraftKey: Hashable, Sendable {
    let channelID: String
    let rootID: String?

    init(channel: String, root: String? = nil) {
        channelID = channel
        rootID = root
    }
}

/// Where drafts are kept. A seam rather than a direct store call so the cache above it
/// is tested without a database, and so a surface reached without persistence (the UI-test
/// fixture host) simply keeps nothing.
///
/// Nothing here throws. A draft that cannot be written is not a failure anybody can act
/// on mid-sentence, and an error thrown up this path would reach the keystroke that
/// caused it.
@MainActor
protocol ComposerDraftPersisting {
    /// Synchronous by design — see ``ComposerDrafts/draft(for:)``.
    func load(_ key: ComposerDraftKey) -> ComposerDraftRecord?
    func save(_ key: ComposerDraftKey, text: String, tokens: String) async
    func delete(_ key: ComposerDraftKey) async
}

/// The store-backed persistence, wired in ``AppEnvironment``.
struct StoredComposerDrafts: ComposerDraftPersisting {
    let store: BuzzEventStore

    func load(_ key: ComposerDraftKey) -> ComposerDraftRecord? {
        try? store.composerDraft(channel: key.channelID, root: key.rootID)
    }

    func save(_ key: ComposerDraftKey, text: String, tokens: String) async {
        try? await store.saveComposerDraft(
            channel: key.channelID,
            root: key.rootID,
            text: text,
            tokens: tokens
        )
    }

    func delete(_ key: ComposerDraftKey) async {
        try? await store.deleteComposerDraft(channel: key.channelID, root: key.rootID)
    }
}

/// Every composer's unsent text, held for the session and written through to the store.
///
/// # Why there is a cache in front of the table at all
///
/// Not speed — the read is a primary-key lookup. It is that a write is `async` and
/// leaving a conversation is not: type a word in a thread, press back, and press straight
/// back in, and the read can overtake its own write. This layer answers from memory, so
/// what a composer shows is decided by what was last *typed*, never by what has last
/// *landed*. The table is durability for the next launch; this is correctness within the
/// session.
///
/// # Coalescing without a timer
///
/// A keystroke queues one change for its composer and starts a drain if one is not
/// already running. Queueing *replaces* whatever that composer was already waiting to
/// have written, so keystrokes arriving during a write collapse into a single further one
/// rather than lining up behind each other. There is no debounce interval to choose:
/// typing fast coalesces on its own, and typing slowly persists every keystroke, which is
/// the behaviour a fixed delay is usually trying to approximate. The window in which a
/// kill loses text is one database write, not one timer period.
///
/// ``flush()`` is the guarantee at the edges of that — the app going to the background,
/// where the process may not come back.
///
/// # Text only
///
/// A draft is `MentionDraft`: wire text plus the identity-bearing mention tokens, which
/// are stored because the visible `@Name` does not carry the pubkey behind it and a
/// restored draft that mentions nobody is worse than one that does not mention at all.
/// Attachments are not part of a draft yet. When they are, they attach in three places
/// and nowhere else: ``ComposerDraftTokens`` gains a sibling payload, the
/// `composer_draft` table gains a column, and the two models' `mentionDraft` gains the
/// attachment beside it.
@MainActor
final class ComposerDrafts {
    private let persistence: any ComposerDraftPersisting
    private let capacity: Int

    /// The live drafts, by composer. A key is absent when its composer is empty.
    private var cache: [ComposerDraftKey: MentionDraft] = [:]
    /// Composers already answered for this session, so a conversation with nothing
    /// stored is read from disk once rather than on every arrival.
    private var consulted: Set<ComposerDraftKey> = []
    /// Least recently touched first — what the memory trim evicts by.
    private var recency: [ComposerDraftKey] = []

    /// What each composer with an unwritten change is waiting to have done to it, and the
    /// value to do it with.
    ///
    /// The intent is carried here rather than re-derived from ``cache`` at write time,
    /// and that is a correctness fix rather than a style one: "absent from the cache"
    /// means both *cleared by its author* and *evicted by ``trim()``*, so a queue of keys
    /// alone turned an eviction into a delete and destroyed a stored draft nobody had
    /// touched. Recorded intent cannot be misread that way. Overwriting the entry is also
    /// what makes a burst of keystrokes cost one write: the last one wins before the
    /// drain ever reaches the key.
    private enum PendingWrite {
        case save(MentionDraft)
        case clear
    }

    private var pending: [ComposerDraftKey: PendingWrite] = [:]
    /// The write loop, while one is running. At most one exists at a time; that is what
    /// makes the writes serial and the coalescing free.
    private var drain: Task<Void, Never>?

    init(persistence: any ComposerDraftPersisting, capacity: Int = ComposerDraftPolicy.capacity) {
        self.persistence = persistence
        self.capacity = max(1, capacity)
    }

    /// What this composer should open with — the cached draft, then the stored one, then
    /// nothing.
    ///
    /// Synchronous, and that is the requirement rather than an optimisation: a
    /// conversation's model reads this on the first `body` pass (see
    /// ``ChannelTimelineModel/primeIfNeeded()``), so the draft is in the bar for the first
    /// frame. An `async` read shows an empty composer and fills it in afterwards, which
    /// reads as the text having been lost and then found.
    func draft(for key: ComposerDraftKey) -> MentionDraft {
        if let cached = cache[key] {
            touch(key)
            return cached
        }
        guard !consulted.contains(key) else { return MentionDraft() }
        consulted.insert(key)
        guard let record = persistence.load(key) else { return MentionDraft() }
        let draft = MentionDraft(
            text: record.text,
            tokens: ComposerDraftTokens.decode(record.tokens, in: record.text)
        )
        cache[key] = draft
        touch(key)
        return draft
    }

    /// Records what a composer now holds. Empty (or whitespace-only) text clears it —
    /// the same predicate the send button uses, so nothing is kept that could not be sent.
    ///
    /// Recording what a composer already held does nothing at all, and that is what lets
    /// a model put a stored draft back into its composer without a flag saying "this one
    /// does not count": the restore hands back exactly the value this object just gave
    /// out. Without it, opening a conversation would count as editing its draft and move
    /// it to the front of the eviction order for having been looked at.
    func record(_ draft: MentionDraft, for key: ComposerDraftKey) {
        // `allSatisfy` rather than trimming: this runs on every keystroke, and trimming
        // copies the whole draft to ask a question the first non-space character answers.
        let isCleared = draft.text.allSatisfy(\.isWhitespace)
        let held = cache[key]
        if isCleared ? (held == nil && consulted.contains(key)) : held == draft { return }
        consulted.insert(key)
        if isCleared {
            cache.removeValue(forKey: key)
            recency.removeAll { $0 == key }
            // Queued even when the cache held nothing: a send clears a composer whose
            // draft may only exist on disk, and a delete nobody needed is a no-op.
            pending[key] = .clear
        } else {
            cache[key] = draft
            touch(key)
            trim()
            pending[key] = .save(draft)
        }
        startDrainIfNeeded()
    }

    /// Waits for every recorded change to reach the store. Called as the app leaves the
    /// foreground — the one moment the process may not be here to finish a write later.
    /// A keystroke landing while a drain is finishing starts another, so this waits until
    /// there is none rather than waiting once.
    func flush() async {
        while let drain {
            await drain.value
        }
    }

    /// Discards these composers' drafts outright — the Drafts screen's delete.
    ///
    /// Goes through this object rather than straight to the store because the cache is
    /// the authority within a session (see ``draft(for:)``): deleting only the row would
    /// leave the text in memory, and the next visit to that conversation would restore a
    /// draft the reader had just thrown away.
    ///
    /// `consulted` keeps each key, so a later visit answers "nothing here" from memory
    /// rather than reading the row back — the delete is queued through the same
    /// coalescing drain as everything else and may not have landed yet.
    func discard(_ keys: [ComposerDraftKey]) {
        for key in keys {
            cache.removeValue(forKey: key)
            recency.removeAll { $0 == key }
            consulted.insert(key)
            pending[key] = .clear
        }
        guard !keys.isEmpty else { return }
        startDrainIfNeeded()
    }

    /// Forgets every draft held in memory, on sign-out.
    ///
    /// This object outlives a session — it is built once in ``AppEnvironment`` — so
    /// without this, a channel two identities share would open for the second one holding
    /// the first one's unsent words. The stored rows are not touched here: whether they
    /// survive is the store's existing rule (a same-key re-login keeps its history, a
    /// different key wipes it, drafts included), and this cache has no business
    /// overriding it.
    ///
    /// `pending` is emptied too, so a queued change never lands against the next
    /// identity's session; a write already in flight finishes against the store this one
    /// was signed into, which the login that follows then wipes or keeps by its own rule.
    func reset() {
        pending.removeAll()
        cache.removeAll()
        consulted.removeAll()
        recency.removeAll()
    }

    // MARK: - Internals

    private func touch(_ key: ComposerDraftKey) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }

    /// Drops the least recently touched drafts past ``capacity``, so this cache is bounded
    /// by the same number the table is.
    ///
    /// The two evict in slightly different orders — this one by last touch, the table by
    /// last edit — and that difference costs nothing: an eviction here is forgetting a
    /// copy, not a draft. `consulted` is cleared with it so the next visit reads the row
    /// back off disk if it is still there.
    private func trim() {
        while recency.count > capacity {
            let evicted = recency.removeFirst()
            cache.removeValue(forKey: evicted)
            // Deliberately *not* marked dirty. Nothing was withdrawn — the table applies
            // its own bound when it is written to, and a delete from here would be this
            // cache deciding to destroy stored text on a rule it does not own.
            consulted.remove(evicted)
        }
    }

    private func startDrainIfNeeded() {
        guard drain == nil else { return }
        drain = Task { [weak self] in
            await self?.drainPending()
        }
    }

    /// Applies each queued change, one at a time, until none are left. Serial on purpose:
    /// two writes for one composer in flight together have no defined winner.
    private func drainPending() async {
        defer { drain = nil }
        while let (key, write) = pending.popFirst() {
            switch write {
            case let .save(draft):
                await persistence.save(
                    key,
                    text: draft.text,
                    tokens: ComposerDraftTokens.encode(draft.tokens)
                )
            case .clear:
                await persistence.delete(key)
            }
        }
    }
}

/// The stored form of a draft's mention tokens.
///
/// Written out by hand rather than derived from ``ComposerMentionToken`` because this is
/// an on-disk format: it has to survive that type being renamed or gaining a field, and
/// `NSRange` is not `Codable` anyway. Unreadable JSON costs the mentions and keeps the
/// text — never the other way round.
enum ComposerDraftTokens {
    private struct Stored: Codable {
        let kind: String
        let entity: String
        let name: String
        let location: Int
        let length: Int
    }

    static func encode(_ tokens: [ComposerMentionToken]) -> String {
        guard !tokens.isEmpty else { return "" }
        let stored = tokens.map {
            Stored(
                kind: String($0.kind.trigger),
                entity: $0.entityID,
                name: $0.displayName,
                location: $0.range.location,
                length: $0.range.length
            )
        }
        guard let data = try? JSONEncoder().encode(stored),
              let payload = String(data: data, encoding: .utf8)
        else { return "" }
        return payload
    }

    /// Decodes the tokens that still describe `text`.
    ///
    /// A token whose range runs past the restored text is dropped rather than trusted:
    /// these ranges are handed to UIKit's text system, and the only thing keeping them
    /// meaningful is that they were computed against this exact string. Everything that
    /// writes here writes both together, so this is a boundary check on a file, not a
    /// path with a known cause.
    static func decode(_ payload: String, in text: String) -> [ComposerMentionToken] {
        guard !payload.isEmpty,
              let stored = try? JSONDecoder().decode([Stored].self, from: Data(payload.utf8))
        else { return [] }
        let length = (text as NSString).length
        return stored.compactMap { token in
            guard let trigger = token.kind.first, let kind = MentionKind(rawValue: trigger),
                  token.location >= 0, token.length > 0, token.location + token.length <= length
            else { return nil }
            return ComposerMentionToken(
                kind: kind,
                entityID: token.entity,
                displayName: token.name,
                range: NSRange(location: token.location, length: token.length)
            )
        }
    }
}
