@testable import BuzzKit
import Testing

/// Who may edit or delete a message.
///
/// Every expectation here is a rule read out of the relay, not a preference: delete is
/// `side_effects.rs`'s `9005` arm, edit is `ingest.rs`'s `validate_edit_ownership`. If one
/// of these fails after a relay change, the relay is right and this is stale.
@Suite("Message authority", .timeLimit(.minutes(1)))
struct MessageAuthorityTests {
    @Test("An author may do both to their own message")
    func author() {
        let authority = MessageAuthority.resolve(isAuthor: true, ownsAuthor: false, isChannelAdmin: false)
        #expect(authority.canEdit)
        #expect(authority.canDelete)
    }

    @Test("A channel admin may delete somebody's message but may NOT rewrite it")
    func adminCanDeleteButNotEdit() {
        // The asymmetry is the whole reason these are two answers. Taking something down is
        // moderation; putting different words in somebody's mouth is not, and the relay
        // refuses a 40003 from an admin who did not write the message.
        let authority = MessageAuthority.resolve(isAuthor: false, ownsAuthor: false, isChannelAdmin: true)
        #expect(authority.canDelete)
        #expect(authority.canEdit == false)
    }

    @Test("The human who owns the agent may do both, which is how a person manages what their agents said")
    func agentOwner() {
        let authority = MessageAuthority.resolve(isAuthor: false, ownsAuthor: true, isChannelAdmin: false)
        #expect(authority.canEdit)
        #expect(authority.canDelete)
    }

    @Test("A reader who is none of the three may do neither")
    func bystander() {
        let authority = MessageAuthority.resolve(isAuthor: false, ownsAuthor: false, isChannelAdmin: false)
        #expect(authority.canEdit == false)
        #expect(authority.canDelete == false)
        #expect(authority == .none)
    }

    @Test("Owning the agent still grants the edit an admin would be refused")
    func ownerOfAgentWhoIsAlsoAdmin() {
        // The two paths are independent: being an admin does not take away the edit that
        // owning the author grants. Worth pinning because a single `canManage` flag — the
        // shape the reference mobile client uses — cannot express it.
        let authority = MessageAuthority.resolve(isAuthor: false, ownsAuthor: true, isChannelAdmin: true)
        #expect(authority.canEdit)
        #expect(authority.canDelete)
    }
}
