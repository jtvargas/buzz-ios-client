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

    /// Puts this thread's unsent reply back in the composer, from the channel's place in
    /// the pass. See ``ChannelTimelineModel/restoreDraft()``.
    func restoreDraft() {
        guard let drafts, mentionDraft.text.isEmpty else { return }
        let restored = drafts.draft(for: draftKey)
        guard !restored.text.isEmpty else { return }
        mentionDraft = restored
    }
}
