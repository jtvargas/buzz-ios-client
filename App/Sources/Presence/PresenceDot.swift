import BuzzKit
import SwiftUI

/// A small presence indicator: green when online, amber when away, nothing when absent.
///
/// Rendered next to a message author in the timeline so a peer's presence reads at a
/// glance. Absence renders as empty space of the same size, so a row's layout does not
/// shift as presence flickers.
struct PresenceDot: View {
    /// The peer's announced status, or `nil` when they are not present.
    let status: PresenceStatus?

    var body: some View {
        Circle()
            .fill(Self.fill(status))
            .frame(width: 7, height: 7)
            .accessibilityHidden(status == nil)
            .accessibilityLabel(Self.label(status) ?? "")
    }

    /// The dot's colour where absence is drawn as *nothing* — a row, where a grey dot
    /// would read as a fourth state rather than as "not here".
    static func fill(_ status: PresenceStatus?) -> Color {
        guard let status else { return .clear }
        return tint(status)
    }

    /// What presence looks like where absence is *stated* rather than left blank — the
    /// conversation header's second line and the profile sheet, both of which say "Offline"
    /// in words and need a dot to match.
    ///
    /// Here rather than at either call site so the workspace has one answer to "what colour
    /// is online": a row's dot, a header's dot, and a sheet's dot are the same fact about the
    /// same person, and two of them drifting to different greens is the kind of thing nobody
    /// notices until both are on screen at once.
    ///
    /// An unrecognised status (``PresenceStatus/other(_:)``) is a peer the relay says is
    /// here under a word this build does not know, so it takes the present colour rather
    /// than the absent one — being here is the part that is certain.
    static func tint(_ status: PresenceStatus?) -> Color {
        switch status {
        case .online, .other: .green
        case .away: .orange
        case nil: Color.secondary.opacity(0.5)
        }
    }

    /// The word beside the dot, and the one VoiceOver reads. `nil` for a peer who is not
    /// present, whose word depends on the surface — a row says nothing, a header says
    /// "Offline".
    static func label(_ status: PresenceStatus?) -> String? {
        switch status {
        case .online, .other: "Online"
        case .away: "Away"
        case nil: nil
        }
    }
}
