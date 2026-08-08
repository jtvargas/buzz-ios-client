import SwiftUI

/// The app's tabs: conversations, what has happened to you, and message search.
///
/// The symbols follow the platform's own convention rather than the tab bar's default
/// substitution: the tab being read is drawn filled, the others outlined, which is how every
/// system app on the phone says which one you are in. Naming that here — and not at the tab
/// bar — is what lets it be tested, because a `.fill` variant that does not exist renders as
/// nothing at all, silently.
enum HomeTab: String, CaseIterable, Hashable, Identifiable {
    /// Channels, direct messages, and the shortcuts above them.
    case home
    /// Mentions, replies, approvals and agent updates addressed to you, grouped by
    /// conversation.
    case activity
    /// Messages already stored on this device, plus whatever the relay can still reach.
    case search

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .activity: "Activity"
        case .search: "Search"
        }
    }

    /// The outlined symbol, which is also the stem the filled variant is derived from.
    ///
    /// `nil` for a tab drawn from the app's own artwork — see ``icon(isSelected:)``.
    var symbol: String? {
        switch self {
        case .home, .activity: nil
        case .search: "magnifyingglass"
        }
    }

    /// What this tab draws, given whether it is the selected one.
    ///
    /// # Why two of the three are not symbols
    ///
    /// Because the owner's drawings are not in the library. `home` and `home.fill` are not
    /// among the 9,184 names in `CoreGlyphs` — `house` has been there since 2019 and `home`
    /// has never been — and neither is his tray. So that artwork ships with the app, traced to
    /// template assets that take the tab bar's tint exactly as a symbol does.
    ///
    /// The pairs are the same idea as `.fill`: outline when the tab is not selected, solid
    /// when it is. Keeping that rule here rather than at the call site is what stops the
    /// drawn tabs drifting from the symbol beside them.
    func icon(isSelected: Bool) -> AppGlyph {
        guard let symbol else {
            return .asset(isSelected ? Self.filledArtwork[self]! : Self.artwork[self]!)
        }
        // `magnifyingglass.fill` does not exist. The search role supplies its own selected
        // treatment, so deriving a missing variant would make the detached control blank.
        guard self != .search else { return .symbol(symbol) }
        return .symbol(isSelected ? "\(symbol).fill" : symbol)
    }
}

private extension HomeTab {
    /// The app's own artwork for a tab that has no system symbol, unselected.
    ///
    /// A dictionary rather than a `switch` returning a name, because the two halves have to
    /// agree — a tab in one and not the other is a tab that draws nothing in one of its two
    /// states — and two tables sharing a key set is a thing a test can check. It does, in
    /// `HomeNavigationTests`.
    static let artwork: [HomeTab: String] = [.home: "TabHome", .activity: "TabActivity"]
    /// The same, selected.
    static let filledArtwork: [HomeTab: String] = [
        .home: "TabHomeFill",
        .activity: "TabActivityFill",
    ]
}
