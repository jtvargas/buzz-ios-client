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
}
