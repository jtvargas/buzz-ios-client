import SwiftUI

/// The shortcut rows above the conversation list: Threads, and Later.
///
/// Slack's shape, and Slack's reason for it. Threads and saved items are not
/// conversations — you do not open "Threads" the way you open a channel — but they are
/// the two things people reach for most often, so they sit above the list rather than
/// inside it. Keeping them in the same `List` and at the same row metrics is what stops
/// them reading as a floating toolbar over a separate thing.
///
/// The count on each is a *shortcut* to knowing whether it is worth opening, so it says
/// nothing when there is nothing: `Threads` rather than `Threads · 0`. A zero someone has
/// to read and dismiss on every launch is worse than an absence.
struct HomeShortcutRow: View {
    let shortcut: HomeShortcut
    /// The number beside the title, or `nil` to draw none.
    let count: Int?

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.accentColor.opacity(0.14))
                .frame(width: Self.glyphSize, height: Self.glyphSize)
                .overlay {
                    Image(systemName: shortcut.symbol)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .accessibilityHidden(true)
            Text(shortcut.title)
                .font(.subheadline.weight(count == nil ? .regular : .semibold))
                .foregroundStyle(.primary)
            if let count {
                Text(Self.separator + shortcut.countLabel(count))
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
        }
        .padding(.vertical, 4)
        .frame(minHeight: 40)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.accessibilityLabel(shortcut, count: count))
    }

    /// The interpunct that joins a title to its count — `Threads · 4`, JT's own notation.
    static let separator = "\u{00B7} "

    /// What a screen reader hears. The interpunct is dropped: it is a visual join, and
    /// spoken it is either silence or a stray "middle dot".
    static func accessibilityLabel(_ shortcut: HomeShortcut, count: Int?) -> String {
        guard let count else { return shortcut.title }
        return "\(shortcut.title), \(shortcut.countLabel(count))"
    }

    /// Matched to ``ChannelRowView``'s glyph, so a shortcut and a conversation sit on the
    /// same left edge and the list reads as one column.
    private static let glyphSize: CGFloat = 30
}

/// The two shortcuts, and everything that differs between them.
///
/// An enum rather than two views: they differ in a symbol, a word, and what a tap does,
/// and writing them as one row means the second cannot quietly drift to different metrics
/// from the first.
enum HomeShortcut: String, CaseIterable, Hashable, Identifiable {
    /// Recent thread activity across every channel.
    case threads
    /// Saved-for-later items. Not built yet — the row exists so the shape of the home
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
    /// `Later · 0 items` is exactly what JT asked for and it is the only thing the row
    /// currently says; `Threads` shows one only when there is something new.
    func showsCount(_ count: Int) -> Bool {
        switch self {
        case .threads: count > 0
        case .later: true
        }
    }
}
