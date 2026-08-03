import SwiftUI

/// The app's two tabs: the conversations, and what has happened to you.
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

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .activity: "Activity"
        }
    }

    /// The outlined symbol, which is also the stem the filled variant is derived from.
    var symbol: String {
        switch self {
        case .home: "house"
        case .activity: "bell"
        }
    }

    /// The symbol for this tab given which tab is selected.
    func symbol(isSelected: Bool) -> String {
        isSelected ? "\(symbol).fill" : symbol
    }
}
