import SwiftUI
import UIKit

/// The six things this app says by touch.
///
/// A closed list, and that is the point: a haptic is only information while it is rare. An
/// app that buzzes on every tap teaches its reader to stop noticing, and then the one that
/// mattered — the message left, the thing is gone — lands as noise. So the vocabulary is
/// named here, once, and a new call site has to be one of these or a decision to add
/// another.
///
/// The patterns are chosen to be told apart by feel alone, which is the only test that
/// matters for a haptic: a light tick, a soft one, a medium knock, a rigid click, a
/// selection click, and the only double-beat in the app.
///
/// ``suggestionPicked`` was the fifth, added 2026-08-04 at the owner's ask. It is worth
/// recording why it was allowed past the paragraph above: picking an `@` or a `#` out of the
/// autocomplete is a *committing* act — text is written into the composer that the reader did
/// not type — and it happens at most a few times per message rather than per tap. That is the
/// bar for a new one.
enum HiveHaptic: Equatable, CaseIterable {
    /// A message left the composer. Light: it is a confirmation, not an event.
    case send
    /// A reaction was added or withdrawn. Soft, and distinct from ``send`` by feel — the
    /// two are the actions a reader repeats most, so they must not be the same tick.
    case reaction
    /// A long press was recognised and something is about to open. The firmest of the
    /// three impacts, because it is the one that reports a *gesture* rather than the
    /// outcome of a tap: it has to arrive before the sheet has drawn a pixel, and be
    /// unmistakable at the moment the finger is still down.
    case longPress
    /// Something was deleted. The one notification pattern in the app, and so the one
    /// feedback with two beats — a destructive act should not feel like a tick.
    case delete
    /// An `@` or a `#` was picked out of the composer's suggestion list.
    ///
    /// The one *selection* generator in the app, which is both why it is allowed to exist
    /// beside ``send`` and what it is for. UIKit's selection feedback is the platform's own
    /// answer to "an item was chosen from a list", and it is a crisper, lighter click than any
    /// of the impacts — so it satisfies the owner's "light" without colliding with ``send``,
    /// which is already `.impact(.light)` and which `everyEventIsDistinct` would have caught.
    case suggestionPicked
    /// Something was disclosed or put away: a sidebar section, the composer's attachment
    /// card.
    ///
    /// The sixth, added 2026-08-06 at the owner's ask, and it clears the same bar
    /// ``suggestionPicked`` did: opening a disclosure is a *deliberate* act on a control the
    /// reader aimed at, and not one anybody performs in a stream. It is also the only answer
    /// either gesture has at the moment of the tap — the sidebar heading draws no press
    /// feedback (`.hiveNoPress`, so the title and the chevron cannot disagree) and its rows
    /// take 0.22s to arrive; the composer's `+` turns into its X over the same 0.22s with
    /// the card not yet drawn.
    ///
    /// Named for the event and not for the sidebar, which is where it started: a second call
    /// site is exactly when a name that describes one screen becomes a lie. The vocabulary is
    /// closed so that a new *feeling* is a decision — reusing one across two controls that
    /// do the same thing is the vocabulary working, not a shortcut around it.
    ///
    /// `.rigid` rather than the literal reading of "light": ``send`` already holds
    /// `.impact(.light)`, and `everyEventIsDistinct` is what would have caught a disclosure
    /// opening feeling exactly like a message leaving. Rigid is the crisper of the two — a
    /// click against a stop, which is what both of these reaching their end is.
    case disclosureToggled

    /// What UIKit is asked to play.
    ///
    /// Split from the playing so the vocabulary is a value: "react and send do not feel the
    /// same" is then a unit test rather than a thing to be checked by hand on a device that
    /// is not the one it broke on.
    enum Pattern: Equatable {
        case impact(UIImpactFeedbackGenerator.FeedbackStyle)
        case notification(UINotificationFeedbackGenerator.FeedbackType)
        /// UIKit's own "an item was selected". Carries no style because it has none to
        /// choose — that is the whole reason it is distinguishable from every impact above.
        case selection
    }

    var pattern: Pattern {
        switch self {
        case .send: .impact(.light)
        case .reaction: .impact(.soft)
        case .longPress: .impact(.medium)
        case .delete: .notification(.warning)
        case .suggestionPicked: .selection
        case .disclosureToggled: .impact(.rigid)
        }
    }
}

/// Plays the app's haptics.
///
/// # Why this is a call and not `sensoryFeedback`
///
/// SwiftUI's `.sensoryFeedback(_:trigger:)` is the modern spelling and it is the wrong shape
/// for three of the four cases here. It fires from a *view*, on a change to a value that
/// view can see, which means every call site needs a counter in `@State` whose only purpose
/// is to be incremented — and, worse, the view has to still be there when the change lands.
/// Two of these four play from a sheet that dismisses itself in the same turn (Delete, and a
/// reaction chosen from the actions sheet), where the view carrying the modifier is on its
/// way out as the trigger changes.
///
/// A generator has neither problem: it plays from the closure that did the thing, at the
/// moment it did it. It is equally respectful of the reader's settings — system haptics are
/// off at the source, and a generator on a device with them disabled plays nothing.
@MainActor
enum HiveHaptics {
    /// Plays `haptic` now.
    static func play(_ haptic: HiveHaptic) {
        switch haptic.pattern {
        case let .impact(style):
            UIImpactFeedbackGenerator(style: style).impactOccurred()
        case let .notification(type):
            UINotificationFeedbackGenerator().notificationOccurred(type)
        case .selection:
            UISelectionFeedbackGenerator().selectionChanged()
        }
    }
}
