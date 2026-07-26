import SwiftUI

/// A small online indicator: a filled green dot when present, nothing when absent.
///
/// Rendered next to a message author in the timeline so a peer who is online in the
/// workspace reads at a glance. Absence renders as empty space of the same size, so
/// a row's layout does not shift as presence flickers.
struct PresenceDot: View {
    let isOnline: Bool

    var body: some View {
        Circle()
            .fill(isOnline ? Color.green : Color.clear)
            .frame(width: 7, height: 7)
            .accessibilityHidden(!isOnline)
            .accessibilityLabel(isOnline ? "Online" : "")
    }

    /// What presence looks like where absence is *stated* rather than left blank — the
    /// conversation header's second line and the profile sheet, both of which say "Offline"
    /// in words and need a dot to match.
    ///
    /// Here rather than at either call site so the workspace has one answer to "what colour
    /// is online": a row's dot, a header's dot, and a sheet's dot are the same fact about the
    /// same person, and two of them drifting to different greens is the kind of thing nobody
    /// notices until both are on screen at once.
    static func tint(isOnline: Bool) -> Color {
        isOnline ? .green : Color.secondary.opacity(0.5)
    }
}
