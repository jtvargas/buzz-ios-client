import Foundation
@testable import NostrCore
import Testing

@Suite("OKReason NIP-01 prefix classification and retry policy")
struct OKReasonTests {
    // MARK: - Prefix parsing

    @Test(
        "Every machine-readable prefix maps to its case with the message stripped",
        arguments: [
            ("duplicate: already have this event", OKReason.duplicate("already have this event")),
            ("pow: difficulty 28 required", .pow("difficulty 28 required")),
            ("rate-limited: slow down, please", .rateLimited("slow down, please")),
            ("invalid: bad signature", .invalid("bad signature")),
            ("restricted: not a member", .restricted("not a member")),
            ("auth-required: please authenticate", .authRequired("please authenticate")),
            ("blocked: banned pubkey", .blocked("banned pubkey")),
            ("error: internal failure", .error("internal failure")),
        ]
    )
    func parsesPrefixes(message: String, expected: OKReason) {
        #expect(OKReason(message: message) == expected)
    }

    @Test("A prefix is recognised with or without a space after the colon")
    func spacingAfterColon() {
        #expect(OKReason(message: "pow: 28") == .pow("28"))
        #expect(OKReason(message: "pow:28") == .pow("28"))
        #expect(OKReason(message: "pow:   28") == .pow("28"))
        #expect(OKReason(message: "auth-required:") == .authRequired(""))
    }

    @Test("A message with no recognised prefix stays unspecified with the raw text")
    func noRecognisedPrefix() {
        #expect(OKReason(message: "try again later") == .unspecified("try again later"))
        // An unknown token before a colon is not a NIP-01 prefix; keep it raw.
        #expect(OKReason(message: "mystery: value") == .unspecified("mystery: value"))
    }

    @Test("An empty message is unspecified and empty")
    func emptyMessage() {
        #expect(OKReason(message: "") == .unspecified(""))
    }

    @Test("The prefix match is exact, not a substring")
    func prefixIsExact() {
        // "powered" starts with "pow" but is not the "pow" prefix.
        #expect(OKReason(message: "powered: down") == .unspecified("powered: down"))
    }

    // MARK: - Retry policy

    @Test(
        "Each reason maps to the retry disposition the outbox expects",
        arguments: [
            (OKReason.invalid("x"), OKReason.Disposition.terminal),
            (.restricted("x"), .terminal),
            (.blocked("x"), .terminal),
            (.pow("x"), .terminal),
            (.authRequired("x"), .reauthThenRetry),
            (.rateLimited("x"), .retryable),
            (.error("x"), .retryable),
            (.unspecified("x"), .retryable),
            (.duplicate("x"), .alreadyAccepted),
        ]
    )
    func dispositionMapping(reason: OKReason, expected: OKReason.Disposition) {
        #expect(reason.disposition == expected)
    }

    // MARK: - RelayMessage bridge

    @Test("A rejected OK exposes its classified reason")
    func okRejectionReason() {
        let message = RelayMessage.ok(eventID: "id", accepted: false, message: "rate-limited: too fast")
        #expect(message.rejectionReason == .rateLimited("too fast"))
        #expect(message.rejectionReason?.disposition == .retryable)
    }

    @Test("An accepted OK has no rejection reason")
    func okAcceptedHasNoReason() {
        let message = RelayMessage.ok(eventID: "id", accepted: true, message: "stored")
        #expect(message.rejectionReason == nil)
    }

    @Test("A CLOSED frame exposes its classified reason")
    func closedRejectionReason() {
        let message = RelayMessage.closed(subscriptionID: "sub-1", message: "auth-required: authenticate first")
        #expect(message.rejectionReason == .authRequired("authenticate first"))
        #expect(message.rejectionReason?.disposition == .reauthThenRetry)
    }

    @Test("Non-verdict frames carry no rejection reason")
    func nonVerdictFramesHaveNoReason() {
        #expect(RelayMessage.eose(subscriptionID: "s").rejectionReason == nil)
        #expect(RelayMessage.notice(message: "hi").rejectionReason == nil)
        #expect(RelayMessage.authChallenge(challenge: "c").rejectionReason == nil)
    }
}
