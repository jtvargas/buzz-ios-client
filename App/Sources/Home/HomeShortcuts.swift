import SwiftUI

/// The shortcut cards above the conversation list: Threads, and Later.
///
/// Slack's shape, and Slack's reason for it. Threads and saved items are not conversations
/// — you do not open "Threads" the way you open a channel — so drawing them as list rows
/// put two things that are not conversations at the top of a list of conversations, in the
/// same metrics, one hairline away from the first channel. As a row of cards they read as
/// what they are: a small set of destinations above the list, rather than the first two
/// entries in it.
///
/// The cards share the row equally rather than sitting at a fixed size, so two of them fill
/// the width the list already uses and a third would simply divide it again.
struct HomeShortcutCards: View {
    /// The number on each card, or `nil` for one that should draw none.
    let count: (HomeShortcut) -> Int?
    let press: (HomeShortcut) -> Void

    var body: some View {
        HStack(spacing: Self.betweenCards) {
            ForEach(HomeShortcut.allCases) { shortcut in
                Button { press(shortcut) } label: {
                    HomeShortcutCard(shortcut: shortcut, count: count(shortcut))
                }
                // `.plain`, so the card's own fill is the whole button: any bordered style
                // would draw a second, system background around a card that has one.
                .buttonStyle(.plain)
            }
        }
    }

    /// Between the two cards.
    private static let betweenCards: CGFloat = 10
}

/// One shortcut card: a tinted glyph, the destination's name, and what is waiting in it.
struct HomeShortcutCard: View {
    let shortcut: HomeShortcut
    /// The number under the title, or `nil` to draw none.
    let count: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.accentColor.opacity(0.14))
                .frame(width: Self.glyphSize, height: Self.glyphSize)
                .overlay {
                    Image(systemName: shortcut.symbol)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .accessibilityHidden(true)
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 1) {
                Text(shortcut.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let count {
                    Text(shortcut.countLabel(count))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(Self.padding)
        // Equal widths from the enclosing stack, one height for the row. A fixed minimum
        // rather than a content height: a card whose height depended on whether it had a
        // count would leave the row uneven exactly when one of the two has news.
        .frame(maxWidth: .infinity, minHeight: Self.height, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Self.cornerRadius)
                .fill(Color.secondary.opacity(0.10))
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.accessibilityLabel(shortcut, count: count))
        .accessibilityAddTraits(.isButton)
    }

    /// What a screen reader hears: the destination, then what is in it.
    static func accessibilityLabel(_ shortcut: HomeShortcut, count: Int?) -> String {
        guard let count else { return shortcut.title }
        return "\(shortcut.title), \(shortcut.countLabel(count))"
    }

    private static let glyphSize: CGFloat = 30
    private static let padding: CGFloat = 12
    /// Tall enough that the glyph, the name and the count read as three bands rather than a
    /// cramped stack, and close enough to half the list's width that the pair read as the
    /// square buttons they are meant to be.
    private static let height: CGFloat = 104
    private static let cornerRadius: CGFloat = 14
}

/// The two shortcuts, and everything that differs between them.
///
/// An enum rather than two views: they differ in a symbol, a word, and what a tap does,
/// and writing them as one card means the second cannot quietly drift to different metrics
/// from the first.
enum HomeShortcut: String, CaseIterable, Hashable, Identifiable {
    /// Recent thread activity across every channel.
    case threads
    /// Saved-for-later items. Not built yet — the card exists so the shape of the home
    /// screen is right, and says so when pressed.
    case later

    var id: String { rawValue }

    var title: String {
        switch self {
        case .threads: "Threads"
        case .later: "Later"
        }
    }

    var symbol: String {
        switch self {
        // The same mark a thread's own heading carries, so the shortcut and the screen
        // it opens are recognisably the same thing.
        case .threads: "text.append"
        case .later: "bookmark"
        }
    }

    /// What the count counts, singular and plural. Threads counts *new* ones — the
    /// question a shortcut answers is "is there anything for me in there".
    func countLabel(_ count: Int) -> String {
        switch self {
        case .threads: count == 1 ? "1 new" : "\(count) new"
        case .later: count == 1 ? "1 item" : "\(count) items"
        }
    }

    /// Whether a count is worth drawing at all. `Later` always shows its count, because
    /// `Later · 0 items` is exactly what JT asked for and it is the only thing the card
    /// currently says; `Threads` shows one only when there is something new.
    func showsCount(_ count: Int) -> Bool {
        switch self {
        case .threads: count > 0
        case .later: true
        }
    }
}
