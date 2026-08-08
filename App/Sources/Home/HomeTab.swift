import SwiftUI

/// The app's tabs: conversations, what has happened to you, and search.
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
    /// Messages, people, and channels already known to this community, plus relay reach.
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
    var symbol: String {
        switch self {
        case .home: "house"
        case .activity: "bell"
        case .search: "magnifyingglass"
        }
    }

    /// The symbol for this tab given which tab is selected.
    func symbol(isSelected: Bool) -> String {
        // `magnifyingglass.fill` does not exist. The search role supplies its own selected
        // treatment, so deriving a missing variant would make the detached control blank.
        guard self != .search else { return symbol }
        return isSelected ? "\(symbol).fill" : symbol
    }
}
