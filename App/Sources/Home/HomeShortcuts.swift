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
    /// Whether a card is asking for attention *now*, which is the only thing that spends
    /// the accent. For most cards that is simply "something is in it"; Later is the one
    /// where having items and wanting attention are different questions — a reminder due
    /// tomorrow is waiting, not calling.
    let isCalling: (HomeShortcut) -> Bool
    let press: (HomeShortcut) -> Void
    /// Clears every unread thread on this device — see ``ThreadReadMarks/markAllSeen(among:)``.
    /// Reached by holding the Threads card; see ``HomeShortcut/offersMarkAllRead``.
    let markAllThreadsRead: () -> Void

    var body: some View {
        HStack(spacing: Self.betweenCards) {
            ForEach(HomeShortcut.allCases) { shortcut in
                if shortcut.offersMarkAllRead {
                    holdable(shortcut)
                } else {
                    card(shortcut)
                }
            }
        }
    }

    /// The one card with something under a hold. Same card, same place in the scrolling list,
    /// and it is a `Menu` rather than a `Button` for one reason.
    ///
    /// **A `.contextMenu` cannot be bounded to it.** All three cards share one list row, and a
    /// context menu written anywhere inside a row is installed *on the row*: holding Later or
    /// Drafts opened the Threads menu, and the lift took all three cards and dropped them back
    /// together — both measured on the owner's phone. It is the same mechanism that lets
    /// ``ChannelListView`` write a context menu beside `.swipeActions` and mean the whole row
    /// by it, useful there and wrong here. A `Menu` is a *control*, so its hold is bounded by
    /// its own label; `primaryAction` is what keeps the tap, which a menu would otherwise spend
    /// on opening itself.
    ///
    /// Taking the cards out of the list bounds it too, and that is the version the owner
    /// rejected: out of the list they are out of its scroll view, and he does not want them
    /// pinned above the conversations.
    ///
    /// The two modifiers under it are what a menu costs, and both were device-reported:
    ///
    /// - **the tint.** A menu tints its label, and `.primary` is not a colour — it is *the
    ///   primary level of the enclosing foreground style* — so the card's own white and grey
    ///   resolved to the accent and a dimmer accent. Naming a concrete colour is what stops it;
    ///   the card's amber *border* is a `Color` and is untouched.
    /// - **the press treatment.** ``PressFeedbackButtonStyle`` is a `PrimitiveButtonStyle`,
    ///   which reaches a `Button` and nothing else, so the card kept its hold and lost its dip
    ///   and its wash. A menu with a `primaryAction` draws as a button and carries an ordinary
    ///   `ButtonStyle` — see ``PressFeedbackMenuStyle``.
    private func holdable(_ shortcut: HomeShortcut) -> some View {
        Menu {
            // Not destructive, though it takes the row a delete usually occupies in a menu
            // this shape: nothing is removed and nothing is published — a mark is this device
            // saying it has looked.
            Button("Mark All As Read", systemImage: "checkmark.circle") {
                markAllThreadsRead()
            }
            // Offered but inert at zero rather than absent. A menu item that exists only while
            // there is something to clear is one nobody finds the first time they go looking.
            .disabled(count(shortcut) == 0)
        } label: {
            HomeShortcutCard(
                shortcut: shortcut,
                count: count(shortcut),
                isCalling: isCalling(shortcut)
            )
            // The base the card's own `.primary` and `.secondary` resolve against — see above.
            .foregroundStyle(Color.primary)
        } primaryAction: {
            press(shortcut)
        }
        // The menu's label is drawn by the button style, which is how the treatment gets on.
        .menuStyle(.button)
        .buttonStyle(.hiveMenuPress(in: .rect(cornerRadius: HomeShortcutCard.cornerRadius)))
        // The other half of the tint: a button style is free to tint its own label, so the
        // accent is taken out of the environment rather than only overridden inside it.
        .tint(Color.primary)
    }

    /// A card with nothing under a hold: an ordinary button, and the app's press treatment.
    private func card(_ shortcut: HomeShortcut) -> some View {
        Button { press(shortcut) } label: {
            HomeShortcutCard(
                shortcut: shortcut,
                count: count(shortcut),
                isCalling: isCalling(shortcut)
            )
        }
        // The card's own border is still the whole button — any bordered *system*
        // style would draw a second background inside a card already drawing its
        // edge — so the press treatment is the app's, in the card's own shape. The
        // shared radius would put the wash a couple of points inside the drawn
        // corner, which is the one place a mismatch is visible.
        .buttonStyle(.hivePress(.control, in: .rect(cornerRadius: HomeShortcutCard.cornerRadius)))
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
    /// See ``HomeShortcutCards/isCalling``. Passed in rather than derived from ``count``,
    /// because for Later the two differ.
    var isCalling: Bool = false

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

    /// The card's edge: a hairline, and the accent only where the glyph cannot speak.
    ///
    /// Every card is bordered, because the border *is* the card — swapping a drawn edge for
    /// nothing would make an empty card read as absent rather than empty, which is the
    /// question these cards exist to answer. What changes is the colour, and now only for
    /// the cards that need it.
    ///
    /// A card whose symbol has a `.fill` cut already says "there is something here" by
    /// filling, so spending the accent on its edge as well says it twice — the owner called
    /// the Drafts card too loud for exactly that reason. Threads' `text.append` has no
    /// filled counterpart, so its edge is the only thing it can say it with, and it keeps
    /// the accent. Derived from the symbol rather than switched on the case, so a fourth
    /// destination gets the right treatment without anyone remembering this rule.
    private var border: Color {
        Self.spendsAccentOnEdge(shortcut, isCalling: isCalling) ? .hiveAccent : Self.restingBorder
    }

    /// The card's wash — still the accent, still only when something is waiting. The wash is
    /// what the filled glyph explains on a card that has given up its amber edge; taking
    /// both away would leave a card with something in it looking exactly like an empty one
    /// from across the screen. `0.18` is the app's own number for "this is mine, lightly",
    /// the opacity a reacted chip and a sent bubble already draw the accent at.
    private var fill: Color {
        isCalling ? Color.hiveAccent.opacity(Self.fillOpacity) : .clear
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

    /// Whether this card draws its edge in the accent — see ``border``. Pure and exposed
    /// for the same reason ``hasSomethingWaiting(_:)`` is: what a border looks like is not
    /// something a test can read back off a rendered card.
    static func spendsAccentOnEdge(_ shortcut: HomeShortcut, isCalling: Bool) -> Bool {
        isCalling && !shortcut.signalsWithGlyph
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
    /// The card's edge, and so the shape a press is washed in — see ``HomeShortcutCards``.
    /// Reachable from there for that reason alone: a wash drawn on a shape the card does not
    /// have is more visible than no wash at all.
    static let cornerRadius: CGFloat = 12
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
    /// Messages saved to be reminded about. See ``LaterView``. The one card whose contents
    /// carry a time, and so the one whose count and whose *accent* answer different
    /// questions — see ``HomeShortcutCards/isCalling``.
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
        return filledSymbol ?? symbol
    }

    /// Whether this card's glyph can say "there is something here" on its own — whether the
    /// system ships a `.fill` cut of ``symbol``. The ones that can do not also spend the
    /// accent on their edge; see ``HomeShortcutCard/border``.
    var signalsWithGlyph: Bool { filledSymbol != nil }

    /// Whether holding this card offers **Mark All As Read**.
    ///
    /// Threads alone, and this is a fact about the destinations rather than about the menu:
    /// a card can offer to clear its contents only where "read" is something its contents
    /// *have*. Later holds reminders, which are cleared by coming due or being deleted, and
    /// Drafts holds text nobody has sent — neither has a read state to mark, so a menu on
    /// them would be an action with nothing to act on.
    ///
    /// A property here rather than a `case .threads` in the drawing, so the rule is one a
    /// test can read back and a fourth destination has to answer for itself.
    var offersMarkAllRead: Bool { self == .threads }

    /// ``symbol``'s filled counterpart, or `nil` where the system has none. Resolved at
    /// runtime rather than assumed: asking for a name the system does not have draws
    /// nothing at all, silently, which is the exact trap ``symbol`` is pinned against in
    /// `HomeShortcutTests`.
    private var filledSymbol: String? {
        let filled = "\(symbol).fill"
        return UIImage(systemName: filled) != nil ? filled : nil
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
