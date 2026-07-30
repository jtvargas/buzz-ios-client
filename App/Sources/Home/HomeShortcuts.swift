import SwiftUI
import UIKit

/// The shortcut cards above the conversation list: Threads, Later, and Drafts.
///
/// Slack's shape, and Slack's reason for it. Threads and saved items are not conversations
/// — you do not open "Threads" the way you open a channel — so drawing them as list rows
/// put two things that are not conversations at the top of a list of conversations, in the
/// same metrics, one hairline away from the first channel. As a row of cards they read as
/// what they are: a small set of destinations above the list, rather than the first two
/// entries in it.
///
/// The cards divide the row between them. They sat at a fixed width at the leading edge
/// while there were two of them, for a reason that was right at the time — two cards
/// stretched across the screen read as a banner rather than as shortcuts above a list.
/// Three does not: a third card at 112pt overflows the narrowest phone before Dynamic
/// Type is considered, and at an accessibility size it overflows every phone. Sharing the
/// width is what makes the row fit at every size, and three cards across reads as a set of
/// destinations rather than as a headline.
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
                // `.plain`, so the card's own border is the whole button: any bordered
                // style would draw a second, system background inside a card that is
                // already drawing its own edge.
                .buttonStyle(.plain)
            }
        }
    }

    /// Between adjacent cards.
    private static let betweenCards: CGFloat = 10
}

/// One shortcut card: a bold glyph, the destination's name, and what is waiting in it.
///
/// Bordered, and washed with a light fill of the same colour: the card is a small
/// destination beside a list of conversations, so the fill stays a wash rather than a
/// tile solid enough to compete with the messages below for the eye. Colour is spent on
/// exactly one card at a time, the one that has something in it, so that the one worth
/// looking at is the one carrying the only colour on the screen.
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
        VStack(alignment: .leading, spacing: Self.betweenLines) {
            Image(systemName: shortcut.symbol(hasItems: Self.hasSomethingWaiting(count)))
                // Bold, in the text's own colour: at this size a glyph in the regular
                // weight reads as thinner than the word under it, which is what made the
                // card look assembled out of two different things.
                .font(.hiveSymbol(.title3, weight: .bold))
                .foregroundStyle(.primary)
                .accessibilityHidden(true)
            Spacer(minLength: Self.underGlyph)
            Text(shortcut.title)
                .font(.hive(.subheadline, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(shortcut.countLabel(count))
                .font(.hive(.footnote))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(Self.padding)
        // An equal share of the row, at a height that grows with the type inside it: the
        // height is in `@ScaledMetric` points, so a reader at an accessibility size gets a
        // taller card rather than a clipped word, while the width stays whatever a third
        // of the row is on their phone.
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: height)
        // Behind the border rather than a `ZStack` layer of its own: a `RoundedRectangle`
        // filled in `.clear` still costs a shape, and `background` is the same one line
        // the border already reaches for below.
        .background {
            RoundedRectangle(cornerRadius: Self.cornerRadius)
                .fill(fill)
        }
        // `strokeBorder` and not `stroke`, because `stroke` straddles the path — half its
        // width would fall outside the card and clip against the neighbouring card's edge.
        .overlay {
            RoundedRectangle(cornerRadius: Self.cornerRadius)
                .strokeBorder(border, lineWidth: Self.borderWidth)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.accessibilityLabel(shortcut, count: count))
        .accessibilityAddTraits(.isButton)
    }

    /// The card's edge: the accent when there is something in it, and a hairline otherwise.
    ///
    /// Every card is bordered, because the border is the card — what changes is only the
    /// colour. Swapping a drawn edge for nothing would make an empty card read as absent
    /// rather than empty, which is the question these cards exist to answer.
    private var border: Color {
        Self.hasSomethingWaiting(count) ? .hiveAccent : Self.restingBorder
    }

    /// The card's wash: the same rule the border reads its colour from, so a card never
    /// carries the fill without the border that explains it. `0.18` is the app's own
    /// number for "this is mine, lightly" — the opacity a reacted chip and a sent bubble
    /// already draw the accent at.
    private var fill: Color {
        Self.hasSomethingWaiting(count) ? Color.hiveAccent.opacity(Self.fillOpacity) : .clear
    }

    /// Whether this card is drawn in the accent: whether there is anything in it.
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

    /// The card's size in the reader's own type size. One ratio for both dimensions, so a
    /// card at an accessibility size is the same card, larger — not a wider one holding the
    /// same three lines. Relative to `.subheadline`, the size the title is set in.
    @ScaledMetric(relativeTo: .subheadline) private var typeScale: CGFloat = 1

    private var height: CGFloat { Self.height * typeScale }

    private static let padding: CGFloat = 10
    /// Between the name and the count. Small — they are one statement read together — but
    /// not nothing, which set them as tight as two lines of a wrapped sentence.
    private static let betweenLines: CGFloat = 2
    /// The least distance between the glyph and the title. The `Spacer` takes whatever is
    /// left over above it, which is what puts the glyph at the top of the card and the two
    /// lines of text at the bottom of it rather than spreading all three evenly.
    private static let underGlyph: CGFloat = 8
    /// Three short bands, none of them cramped, and no taller than they need to be: the
    /// cards are a place to go from, and the conversations under them are the screen. The
    /// floor is the content — glyph, title, count, and the padding around them come to
    /// about 78 at default type — so this leaves a little air above the title and no more.
    /// The width is the row's own, divided.
    private static let height: CGFloat = 86
    private static let cornerRadius: CGFloat = 12
    /// One weight for both states, so a card does not change shape when its count does —
    /// only its colour. Thinner than the 2pt a text field draws, which would make a card
    /// read as something to fill in rather than somewhere to go.
    private static let borderWidth: CGFloat = 1
    /// The wash's strength — see ``fill``.
    private static let fillOpacity: CGFloat = 0.18
    /// The edge of a card with nothing in it: present, and quiet enough that the accent on
    /// the card beside it is the only thing on the screen asking to be looked at.
    private static let restingBorder = Color.primary.opacity(0.15)
}

/// The shortcuts, and everything that differs between them.
///
/// An enum rather than a view each: they differ in a symbol, a word, and what a tap does,
/// and writing them as one card means a second cannot quietly drift to different metrics
/// from the first.
enum HomeShortcut: String, CaseIterable, Hashable, Identifiable {
    /// Recent thread activity across every channel.
    case threads
    /// Saved-for-later items. Not built yet — the card exists so the shape of the home
    /// screen is right, and says so when pressed.
    case later
    /// Conversations holding unsent text. See ``DraftsView``.
    case drafts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .threads: "Threads"
        case .later: "Later"
        case .drafts: "Drafts"
        }
    }

    var symbol: String {
        switch self {
        // The same mark a thread's own heading carries, so the shortcut and the screen
        // it opens are recognisably the same thing.
        case .threads: "text.append"
        case .later: "bookmark"
        // What sending looks like, unsent.
        case .drafts: "paperplane"
        }
    }

    /// The glyph to draw: the outline when the card is empty, the `.fill` cut when it is
    /// not — a second way of saying what the card's border already says in colour.
    ///
    /// A rule about the *card*, not about any one shortcut, which is why it takes the
    /// state rather than being switched on `self`: a `case .drafts` here is a rule the
    /// next destination silently opts out of.
    ///
    /// The filled name is resolved at runtime rather than assumed. Not every SF Symbol
    /// ships a filled counterpart — ``threads``' `text.append` does not — and asking for a
    /// name the system does not have draws nothing at all, silently, which is the exact
    /// trap ``symbol`` is already pinned against in `HomeShortcutTests`. A shortcut
    /// without one simply keeps its outline in both states.
    func symbol(hasItems: Bool) -> String {
        guard hasItems else { return symbol }
        let filled = "\(symbol).fill"
        return UIImage(systemName: filled) != nil ? filled : symbol
    }

    /// What the count counts, singular and plural. Threads counts *new* ones — the
    /// question a shortcut answers is "is there anything for me in there", and `0 new` is
    /// that question answered rather than left to be inferred from a blank line.
    func countLabel(_ count: Int) -> String {
        switch self {
        case .threads: count == 1 ? "1 new" : "\(count) new"
        case .later, .drafts: count == 1 ? "1 item" : "\(count) items"
        }
    }
}
