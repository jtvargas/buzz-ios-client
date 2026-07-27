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
    /// The number on each card. Every card has one — see ``HomeShortcutCard/count``.
    let count: (HomeShortcut) -> Int
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
    /// The number under the title. Always drawn, zero included: the card exists to answer
    /// "is there anything for me in there", and a card that goes quiet at zero makes its
    /// reader infer the answer from an absence instead of reading it.
    ///
    /// Not an `Int?`. Both cards always have a number, so an optional here would be a state
    /// nothing can produce and every reader would still have to unwrap.
    let count: Int

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
                Text(shortcut.countLabel(count))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(Self.padding)
        // Equal widths from the enclosing stack, one height for the row. A fixed minimum
        // rather than a content height: the pair are meant to read as two squares above the
        // list, and a height taken from three short lines of text would draw two letterbox
        // strips instead.
        .frame(maxWidth: .infinity, minHeight: Self.height, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Self.cornerRadius)
                .fill(Color.secondary.opacity(0.10))
        }
        // The border is *added* to that fill rather than swapped for it: the fill is what
        // makes a card a card, and trading it for a line would leave the card reading as
        // less present at exactly the moment it has something in it.
        //
        // `strokeBorder` and not `stroke`, because `stroke` straddles the path — half its
        // width would fall outside the card, growing the row in one state and not the other
        // and clipping against the neighbouring card's edge.
        .overlay {
            if Self.hasSomethingWaiting(count) {
                RoundedRectangle(cornerRadius: Self.cornerRadius)
                    .strokeBorder(Color.accentColor, lineWidth: Self.borderWidth)
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.accessibilityLabel(shortcut, count: count))
        .accessibilityAddTraits(.isButton)
    }

    /// Whether this card is bordered: whether there is anything in it.
    ///
    /// Written off the count and not off the shortcut. "Something is waiting here" is a fact
    /// about a card, not a fact about Threads, so a `case .threads` in the drawing would be a
    /// rule someone has to remember to extend every time a third destination is added — and
    /// would silently do the wrong thing if they did not.
    ///
    /// Pure and exposed so the rule is tested as itself: what a border looks like is not
    /// something a test can read back off a rendered card.
    static func hasSomethingWaiting(_ count: Int) -> Bool {
        count > 0
    }

    /// What a screen reader hears: the destination, then what is in it.
    static func accessibilityLabel(_ shortcut: HomeShortcut, count: Int) -> String {
        "\(shortcut.title), \(shortcut.countLabel(count))"
    }

    private static let glyphSize: CGFloat = 30
    private static let padding: CGFloat = 12
    /// Tall enough that the glyph, the name and the count read as three bands rather than a
    /// cramped stack, and close enough to half the list's width that the pair read as the
    /// square buttons they are meant to be.
    private static let height: CGFloat = 104
    private static let cornerRadius: CGFloat = 14
    /// The accent line around a card with something in it. A hairline all but vanishes at
    /// this radius on a device, and the 2pt a text field draws would make the card read as
    /// something to fill in rather than somewhere to go.
    private static let borderWidth: CGFloat = 1.5
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
    /// question a shortcut answers is "is there anything for me in there", and `0 new` is
    /// that question answered rather than left to be inferred from a blank line.
    func countLabel(_ count: Int) -> String {
        switch self {
        case .threads: count == 1 ? "1 new" : "\(count) new"
        case .later: count == 1 ? "1 item" : "\(count) items"
        }
    }
}
