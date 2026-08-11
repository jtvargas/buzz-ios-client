import Foundation

// MARK: - Unsent text

/// The thread composer's half of draft persistence — the channel's rules, applied to a
/// different key. See `ChannelTimelineModel+Drafts.swift` for why the hook is a `didSet`.
extension ThreadModel {
    /// The plain-text view of the draft, for the callers that do not deal in mentions.
    var draft: String {
        get { mentionDraft.text }
        set { mentionDraft = MentionDraft(text: newValue) }
    }

    /// This composer's identity in ``ComposerDrafts``. Carrying the channel *and* the
    /// root — rather than the root alone, which is already unique — keeps the key
    /// readable as "the thread under this channel" and lets the table be read by channel
    /// later without a join.
    var draftKey: ComposerDraftKey { ComposerDraftKey(channel: channel, root: root) }

    func recordDraft(replacing previous: MentionDraft) {
        guard mentionDraft != previous else { return }
        drafts?.record(mentionDraft, for: draftKey)
    }

    /// Puts something in the composer that is *not* the author's unsent text: the agents a
    /// just-sent reply keeps mentioned, or nothing at all when the setting is off.
    ///
    /// The second `record` is the point of this method and is not redundant. A refill goes
    /// through ``ThreadModel/mentionDraft`` so the composer redraws, which means the `didSet`
    /// files it as a draft — and a mention with no words after it is not one. Left alone,
    /// every thread the reader had ever replied to would appear on the Drafts screen holding
    /// `@Name`, and the shortcut card would count each of them as unsent work. Recording the
    /// clear immediately after replaces that queued write before any of it reaches the store
    /// (see ``ComposerDrafts/record(_:for:)``), which is also exactly what a send *should*
    /// leave behind: the words went out, so there is nothing left to finish.
    ///
    /// The cost, and it is a real one: the kept mention lives for as long as the composer
    /// does. Leave the thread and come back and it is gone, because nothing was stored.
    func refillComposer(with draft: MentionDraft) {
        // Text where a clear would have left none, which is the case ``handleTyping(_:)``'s
        // empty guard has always relied on to keep a send from announcing more typing.
        isRefillingComposer = !draft.text.isEmpty
        mentionDraft = draft
        drafts?.record(MentionDraft(), for: draftKey)
    }

    /// Puts this thread's unsent reply back in the composer, from the channel's place in
    /// the pass. See ``ChannelTimelineModel/restoreDraft()``.
    func restoreDraft() {
        guard let drafts, mentionDraft.text.isEmpty else { return }
        let restored = drafts.draft(for: draftKey)
        guard !restored.text.isEmpty else { return }
        mentionDraft = restored
    }
}
