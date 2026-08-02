import BuzzKit
import Foundation
@testable import Hive
import Testing

/// The two rules the Later feature rests on that a screenshot cannot check: when the card
/// spends the accent, and what the alert says.
@MainActor
struct LaterTests {
    private func reminder(dueIn seconds: TimeInterval?, from now: Date) -> ReminderRow {
        ReminderRow(
            id: UUID().uuidString,
            eventID: "",
            createdAt: Int64(now.timeIntervalSince1970),
            notBefore: seconds.map { Int64(now.addingTimeInterval($0).timeIntervalSince1970) },
            status: .pending,
            target: nil,
            note: nil
        )
    }

    // MARK: - The card

    /// The owner's correction: a Later card with three reminders in it is not asking for
    /// anything if all three are due tomorrow. Only a reminder that has actually landed puts
    /// the accent on the card.
    @Test("the Later card calls only once a reminder has come due")
    func dueIsNotTheSameAsPresent() {
        let now = Date()
        #expect(!LaterModel.isDue(among: [], at: now))
        #expect(!LaterModel.isDue(among: [reminder(dueIn: 60, from: now)], at: now))
        #expect(LaterModel.isDue(among: [reminder(dueIn: -1, from: now)], at: now))
        // One overdue among several waiting is still the card asking.
        #expect(LaterModel.isDue(
            among: [reminder(dueIn: 3600, from: now), reminder(dueIn: -30, from: now)],
            at: now
        ))
        // A reminder with no due time at all cannot come due — that is what NIP-ER says a
        // finished one looks like, and a finished one is not on this list anyway.
        #expect(!LaterModel.isDue(among: [reminder(dueIn: nil, from: now)], at: now))
    }

    // MARK: - The alert

    /// The owner's wording, and the owner's number, both kept verbatim.
    @Test("the alert names the author and clips the message at forty characters")
    func alertCopy() {
        #expect(ReminderScheduler.title == "You asked me to remind you")
        #expect(ReminderScheduler.previewLimit == 40)

        let long = String(repeating: "a", count: 60)
        let clipped = String(repeating: "a", count: 40)
        #expect(ReminderScheduler.body(authorName: "Jarvis", preview: long) == "@Jarvis: \(clipped)")
        #expect(ReminderScheduler.body(authorName: "Bumble", preview: "  short  ") == "@Bumble: short")
    }
}
