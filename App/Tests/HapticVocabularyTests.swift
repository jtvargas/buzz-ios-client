@testable import Hive
import Testing
import UIKit

/// The haptic vocabulary.
///
/// A haptic cannot be asserted by playing it, so what is held here is the thing that
/// actually goes wrong: two different events settling on the same pattern. A reader learns
/// these by feel and by feel alone — there is no label on a buzz — so "sending and reacting
/// are told apart" is the whole contract, and it is one a later hand can break by adding a
/// fifth case that reaches for `.light` because it was the obvious one.
@Suite("Haptic vocabulary")
struct HapticVocabularyTests {
    @Test("no two events feel the same")
    func everyEventIsDistinct() {
        let patterns = HiveHaptic.allCases.map(\.pattern)
        for (index, pattern) in patterns.enumerated() {
            for other in patterns[(index + 1)...] {
                #expect(pattern != other, "two events share \(pattern)")
            }
        }
    }

    @Test("every event keeps the weight it was chosen for")
    func patternsAreTheOnesChosen() {
        // Light for a confirmation, soft for the action a reader repeats most, medium for
        // the gesture that reports itself while the finger is still down.
        #expect(HiveHaptic.send.pattern == .impact(.light))
        #expect(HiveHaptic.reaction.pattern == .impact(.soft))
        #expect(HiveHaptic.longPress.pattern == .impact(.medium))
        #expect(HiveHaptic.delete.pattern == .notification(.warning))
        // The fifth, and the reason it is a `selection` rather than another impact: `send` is
        // already `.impact(.light)`, so the owner's "light haptic" spelled literally would have
        // been indistinguishable from a message leaving — which `everyEventIsDistinct` forbids.
        #expect(HiveHaptic.suggestionPicked.pattern == .selection)
    }

    @Test("only the destructive event plays a notification")
    func deletionIsTheOnlyNotification() {
        let notifications = HiveHaptic.allCases.filter {
            if case .notification = $0.pattern { return true }
            return false
        }
        // The one two-beat feedback in the app, and the reason it is legible: everything
        // else is a single tick, so the double reads as "that was not a tap".
        #expect(notifications == [.delete])
    }

    @Test("the vocabulary stays closed")
    func vocabularyIsSmall() {
        // Not a style rule. A haptic is information only while it is rare, and the way an
        // app stops meaning anything by touch is one case at a time. A fifth is a decision,
        // and this is where it gets made rather than noticed.
        // Five since 2026-08-04. The number is asserted rather than the list so that adding one
        // is a deliberate edit here with the paragraph on `HiveHaptic` in front of it.
        #expect(HiveHaptic.allCases.count == 5)
    }
}
