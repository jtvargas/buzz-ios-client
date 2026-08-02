import Foundation
@testable import Hive
import Testing

/// What holding a link card copies.
///
/// # What this suite can and cannot hold
///
/// It pins the **value** — that the clipboard gets the link's target and never the words drawn
/// on the card. That is the whole point of the feature for a reader holding a link *because*
/// they want to know where it actually goes, and it is the half that a pure function can be
/// asked about.
///
/// It does not pin the **arbitration**, and no unit test here can: which of the card's hold and
/// the message row's hold wins is SwiftUI resolving two recognisers over one touch, and a
/// `LongPressGesture` is not something a test can press — the same limit ``RichTextRoute`` names
/// about `OpenURLAction`. That rule is stated where it is implemented, in
/// ``LinkPreviewCardView``, and it is verified on a device.
@Suite("Link copy")
struct LinkCopyTests {
    private func card(_ string: String) throws -> LinkPreview {
        try #require(URL(string: string).flatMap { LinkPreview(url: $0) })
    }

    @Test("copies the target, not the provider title drawn on the card")
    func copiesHrefNotProviderTitle() throws {
        let preview = try card("https://github.com/jtvargas/buzz-ios-client/pull/61")

        // The card reads "jtvargas/buzz-ios-client #61" — pasteable nowhere.
        #expect(preview.title == "jtvargas/buzz-ios-client #61")
        #expect(LinkCopy.value(for: preview) == "https://github.com/jtvargas/buzz-ios-client/pull/61")
    }

    /// The case the feature exists for: an author's label that says something entirely
    /// different from where the link goes. `[The scroll fix](…/pull/61)` draws the author's
    /// words, and a reader holding it is asking the one question the label refuses to answer.
    @Test("copies the target, not an authored label that masks it")
    func copiesHrefNotAuthoredLabel() throws {
        let target = try #require(URL(string: "https://github.com/o/r/pull/61"))
        let preview = LinkPreview(
            kind: .githubPullRequest,
            url: target,
            provider: "GitHub",
            typeLabel: "PR",
            title: "The scroll fix"
        )

        #expect(LinkCopy.value(for: preview) == "https://github.com/o/r/pull/61")
        #expect(LinkCopy.value(for: preview) != preview.title)
    }

    /// Copy and open must agree, exactly. The card's tap hands ``LinkPreview/url`` to
    /// `openURL`; the hold has to produce that same link or the two halves of one card
    /// disagree about where it goes.
    ///
    /// Query and fragment are the part worth pinning rather than the scheme: they are what a
    /// "tidied" copy would be tempted to drop, and they are frequently the whole address —
    /// `?tab=readme` and `#section` are which page and which paragraph. A card only exists for
    /// an `http(s)` URL at all, because ``LinkPreview/init(url:)`` refuses every other scheme,
    /// so what is copied is always something a paste can resolve.
    @Test("copies exactly the link a tap would open, query and fragment included")
    func copyAgreesWithOpen() throws {
        let preview = try card("https://example.com/docs/a?tab=readme&x=1#section")

        #expect(LinkCopy.value(for: preview) == preview.url.absoluteString)
        #expect(LinkCopy.value(for: preview) == "https://example.com/docs/a?tab=readme&x=1#section")
    }

    /// One hold time per message. The card's constant is duplicated from the row's rather than
    /// read across a layer this renderer deliberately does not depend on — so this is the thing
    /// that fails if the two ever drift apart.
    @MainActor
    @Test("the card answers a hold at the same moment the message around it does")
    func holdMatchesTheRow() {
        #expect(LinkCopy.longPressDuration == TimelineRowView.longPressDuration)
    }
}
