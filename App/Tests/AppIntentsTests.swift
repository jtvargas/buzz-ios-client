import AppIntents
import Testing
@testable import Hive

/// The routing vocabulary, and the one asymmetry worth failing a build over.
@Suite struct AppDestinationTests {
    /// Every shortcut card has a destination, and every destination has a card.
    ///
    /// The point of the test is the *next* card. A fourth destination added to
    /// ``HomeShortcut`` without one here is a screen a person can reach with a finger and
    /// not with their voice — a gap that shows up as nothing at all, since a Siri phrase
    /// that matches no intent simply does not exist.
    @Test func everyShortcutCardHasADestination() {
        for shortcut in HomeShortcut.allCases {
            #expect(AppDestination(shortcut).shortcut == shortcut)
        }
        #expect(AppDestination.allCases.count == HomeShortcut.allCases.count)
    }

    /// The words the system shows are the words the app shows.
    ///
    /// The Shortcuts parameter picker and the card in the sidebar name the same screen, so a
    /// rename in one place that misses the other is a person choosing "Saved" in Shortcuts
    /// and landing on a screen headed "Later".
    @Test func displayNamesMatchTheCards() {
        for destination in AppDestination.allCases {
            let shown = AppDestination.caseDisplayRepresentations[destination]
            #expect(shown != nil)
            guard let shown else { continue }
            #expect(String(localized: shown.title) == destination.shortcut.title)
        }
    }

    /// The symbol the Siri tile is drawn with, pinned from the card's side.
    ///
    /// ``HiveShortcuts`` cannot be read back — `AppShortcut` publishes initialisers and no
    /// properties — and `systemImageName` is declared `_const`, so the literal there cannot
    /// be replaced by a reference to this value. Pinning the *card* to the same literal is
    /// the half that can be asserted: change ``HomeShortcut/symbol`` and this fails, naming
    /// the file that has to change with it.
    @Test func theCardsStillCarryTheShortcutSymbols() {
        #expect(HomeShortcut.threads.symbol == "text.append")
        #expect(HomeShortcut.later.symbol == "bookmark")
        #expect(HomeShortcut.drafts.symbol == "paperplane")
    }
}

/// The queue that makes a cold launch work.
@MainActor
@Suite struct AppNavigatorTests {
    @Test func startsWithNothingPending() {
        #expect(AppNavigator().pending == nil)
    }

    /// The case the whole design exists for: the request is made while nothing is there to
    /// hear it, and it is still there when the navigation surface finally appears.
    @Test func holdsARequestUntilItIsConsumed() {
        let navigator = AppNavigator()
        navigator.request(.threads)
        // No consumer yet — this stands in for the app still being at the identity gate or
        // bootstrapping, which is exactly when Siri launches it.
        #expect(navigator.pending == .threads)
        #expect(navigator.pending == .threads)  // reading does not clear it
        navigator.consume()
        #expect(navigator.pending == nil)
    }

    /// A consumed request does not come back. This is what stops an unrelated body pass from
    /// re-pushing a screen the reader has already navigated away from.
    @Test func aConsumedRequestDoesNotReturn() {
        let navigator = AppNavigator()
        navigator.request(.later)
        navigator.consume()
        navigator.consume()
        #expect(navigator.pending == nil)
    }

    /// Two commands in a row mean the person changed their mind — the app owes them the
    /// second screen, not a stop at the first on the way.
    @Test func aLaterRequestReplacesAnUnconsumedOne() {
        let navigator = AppNavigator()
        navigator.request(.threads)
        navigator.request(.drafts)
        #expect(navigator.pending == .drafts)
    }
}
