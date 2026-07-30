import Foundation

// MARK: - Unsent text

/// The channel composer's half of draft persistence: which composer this is, what it
/// opens with, and where every change to it goes.
///
/// The hook is a `didSet` on ``ChannelTimelineModel/mentionDraft`` rather than the
/// composer view's `onChange`, because that property is written from three places — the
/// field's binding, ``ChannelTimelineModel/send()`` clearing it, and the over-ceiling
/// failure putting it back — and a hook anywhere else would have to catch all three.
/// (A `didSet` on an `@Observable` stored property survives the macro: it moves to the
/// backing storage, which is how `isAtBottom` works too.)
///
/// Text only. See ``ComposerDrafts`` for where attachments would attach.
extension ChannelTimelineModel {
    /// The plain-text view of the draft, for the callers that do not deal in mentions.
    var draft: String {
        get { mentionDraft.text }
        set { mentionDraft = MentionDraft(text: newValue) }
    }

    /// This composer's identity in ``ComposerDrafts``: the channel's own, never a
    /// thread's — that is ``ThreadModel/draftKey``.
    var draftKey: ComposerDraftKey { ComposerDraftKey(channel: channel) }

    /// Writes an edit through. Recording a value the store already holds is a no-op on
    /// its side, so ``restoreDraft()`` needs no flag to exempt itself.
    func recordDraft(replacing previous: MentionDraft) {
        guard mentionDraft != previous else { return }
        drafts?.record(mentionDraft, for: draftKey)
    }

    /// Puts this channel's unsent text back in the composer.
    ///
    /// Called from ``primeIfNeeded()``, on the same synchronous pre-layout pass as page
    /// one and for the same reason: a draft restored from a `.task` would show an empty
    /// bar first and fill it in afterwards, which reads exactly like the loss this exists
    /// to prevent.
    ///
    /// Only into an untouched composer. Nothing can have typed into this model yet — it
    /// is one `body` old — but the guard says which of the two wins if that ever changes,
    /// and the answer is never the stored copy.
    func restoreDraft() {
        guard let drafts, mentionDraft.text.isEmpty else { return }
        let restored = drafts.draft(for: draftKey)
        guard !restored.text.isEmpty else { return }
        mentionDraft = restored
    }
}
