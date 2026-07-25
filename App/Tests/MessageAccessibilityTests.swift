import BuzzKit
@testable import Hive
import Testing

/// The VoiceOver status phrasing for a message: presence, edited, and delivery folded
/// into one clause, with the common case (delivered, offline author, unedited) empty.
@Suite("Message accessibility status")
struct MessageAccessibilityTests {
    @Test("a delivered message from an offline author has no status")
    func plainDeliveredIsEmpty() {
        #expect(MessageAccessibility.status(isOnline: false, isEdited: false, delivery: .sent).isEmpty)
    }

    @Test("an online author is announced")
    func onlineAnnounced() {
        #expect(MessageAccessibility.status(isOnline: true, isEdited: false, delivery: .sent) == "Online")
    }

    @Test("a pending send is announced as sending")
    func pendingAnnounced() {
        #expect(MessageAccessibility.status(isOnline: false, isEdited: false, delivery: .pending) == "Sending")
    }

    @Test("a failed send is announced as not delivered")
    func failedAnnounced() {
        #expect(
            MessageAccessibility.status(isOnline: false, isEdited: false, delivery: .failed("nope"))
                == "Not delivered"
        )
    }

    @Test("presence, edited, and delivery combine in order")
    func combined() {
        #expect(
            MessageAccessibility.status(isOnline: true, isEdited: true, delivery: .pending)
                == "Online, Edited, Sending"
        )
    }
}
