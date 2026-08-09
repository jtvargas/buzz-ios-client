import SwiftUI
import WidgetKit

/// The Threads shortcut card, at widget size.
///
/// The card's own rules are reproduced rather than shared, because `HomeShortcutCard` is
/// App-target code that reads the app's theme, its type stack and its press treatment —
/// none of which exist in an extension. What is reproduced is the part that carries
/// meaning: the artwork, the two lines, and the accent spent only when something is
/// actually waiting. The Threads glyph has no filled cut, so on this card the edge and the
/// wash are the *only* way "there is something here" can be said — see
/// `HomeShortcutCard.border`.
struct ThreadsWidgetView: View {
    let entry: ThreadsEntry

    var body: some View {
        VStack(alignment: .leading, spacing: Self.betweenLines) {
            Image(Self.glyph)
                .resizable()
                .scaledToFit()
                .frame(height: Self.glyphHeight)
                .foregroundStyle(.primary)
                .accessibilityHidden(true)
            Spacer(minLength: Self.underGlyph)
            Text("Threads")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(countLabel)
                .font(.footnote)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(footnote)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(Self.padding)
        .background {
            RoundedRectangle(cornerRadius: Self.cornerRadius).fill(fill)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Self.cornerRadius)
                .strokeBorder(border, lineWidth: Self.borderWidth)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: - What the states say

    private var count: Int? {
        guard case let .counted(counted) = entry.state else { return nil }
        return counted.count
    }

    /// The card's own phrasing — `HomeShortcut.countLabel` — with the relay's one extra
    /// state on top. A page the relay filled makes the number a floor, and `12+` says that
    /// where a bare `12` would quietly claim to be the whole answer.
    private var countLabel: String {
        guard case let .counted(counted) = entry.state else { return "Open Hive" }
        let suffix = counted.isFloor ? "+" : ""
        return counted.count == 1 && !counted.isFloor ? "1 new" : "\(counted.count)\(suffix) new"
    }

    /// The line that stops a stale number from lying. Always present, because the reader
    /// cannot otherwise tell a count taken thirty seconds ago from one taken this morning
    /// — and on a widget those are routinely both on offer.
    private var footnote: String {
        switch entry.state {
        case .needsApp:
            "Open Hive to set up"
        case let .counted(counted):
            "\(counted.communityName) · \(counted.isStale ? "as of " : "")\(Self.time.string(from: counted.asOf))"
        }
    }

    private var accessibilityLabel: String {
        switch entry.state {
        case .needsApp: "Threads. Open Hive to set up."
        case let .counted(counted): "Threads, \(countLabel), \(counted.communityName)"
        }
    }

    // MARK: - Treatment

    /// The accent goes on the edge only when something is actually waiting, exactly as on
    /// the card. `needsApp` is deliberately quiet: an unconfigured widget is not calling
    /// for attention, it is waiting for a launch.
    private var isCalling: Bool { (count ?? 0) > 0 }

    private var border: Color { isCalling ? Self.accent : Self.restingBorder }

    private var fill: Color { isCalling ? Self.accent.opacity(Self.fillOpacity) : .clear }

    // MARK: - Metrics, matched to `HomeShortcutCard`

    private static let glyph = "ThreadsGlyph"
    private static let glyphHeight: CGFloat = 20
    private static let padding: CGFloat = 10
    private static let betweenLines: CGFloat = 2
    private static let underGlyph: CGFloat = 8
    private static let cornerRadius: CGFloat = 12
    private static let borderWidth: CGFloat = 1
    private static let fillOpacity: CGFloat = 0.18
    private static let restingBorder = Color.primary.opacity(0.15)
    /// The catalogue's `AccentColor`, which is the app's default theme accent. Read by name
    /// so the widget and the app draw one amber.
    private static let accent = Color("AccentColor")

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()
}
