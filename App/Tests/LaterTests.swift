import BuzzKit
import Foundation
@testable import Hive
import Testing

/// The three rules the Later feature rests on that a screenshot cannot check: when the card
/// spends the accent, what a row's due line says and when it turns red, and what the alert
/// says.
@MainActor
struct LaterTests {
    private func reminder(
        dueIn seconds: TimeInterval?,
        from now: Date,
        status: ReminderStatus = .pending
    ) -> ReminderRow {
        ReminderRow(
            id: UUID().uuidString,
            eventID: "",
            createdAt: Int64(now.timeIntervalSince1970),
            notBefore: seconds.map { Int64(now.addingTimeInterval($0).timeIntervalSince1970) },
            status: status,
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

    // MARK: - The due line

    /// The owner's addition: a reminder whose time has passed reads in red, the way Slack's
    /// does. The boundary is the whole of it — a second before, this row is counting down.
    @Test("a reminder reads as overdue the moment its time passes")
    func overdueAtTheBoundary() {
        let now = Date()

        let waiting = ReminderDueLabel.label(for: reminder(dueIn: 30 * 60, from: now), now: now)
        #expect(!waiting.isOverdue)
        #expect(waiting.text == "In 30 minutes")

        // Under a minute out still counts down: rounded up to the smallest unit there is a
        // word for, rather than the formatter's own `0 minutes`.
        let imminent = ReminderDueLabel.label(for: reminder(dueIn: 20, from: now), now: now)
        #expect(!imminent.isOverdue)
        #expect(imminent.text == "In 1 minute")

        // The first minute past due is the moment, not a duration — and already red.
        let justDue = ReminderDueLabel.label(for: reminder(dueIn: -1, from: now), now: now)
        #expect(justDue.isOverdue)
        #expect(justDue.text == "Due now")

        let late = ReminderDueLabel.label(for: reminder(dueIn: -25 * 60, from: now), now: now)
        #expect(late.isOverdue)
        #expect(late.text == "25 minutes ago")

        let veryLate = ReminderDueLabel.label(for: reminder(dueIn: -3 * 3600, from: now), now: now)
        #expect(veryLate.isOverdue)
        #expect(veryLate.text == "3 hours ago")
    }

    /// A finished reminder carries no due time at all — that is what NIP-ER says a done or
    /// cancelled one looks like — so it can never be overdue, whatever tab it is read on.
    @Test("a finished reminder says which it is and is never red")
    func finishedRemindersAreNotOverdue() {
        let now = Date()
        let done = ReminderDueLabel.label(for: reminder(dueIn: nil, from: now, status: .done), now: now)
        #expect(done == ReminderDueLabel.Label(text: "Completed", isOverdue: false))

        let cancelled = ReminderDueLabel.label(
            for: reminder(dueIn: nil, from: now, status: .cancelled),
            now: now
        )
        #expect(cancelled == ReminderDueLabel.Label(text: "Archived", isOverdue: false))
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
