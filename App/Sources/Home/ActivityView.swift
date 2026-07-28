import SwiftUI

/// The Activity tab: everything addressed to you, once it exists.
///
/// A deliberate placeholder rather than a hidden tab. The tab bar's shape is the thing being
/// built here — two destinations, one of them not yet written — and a bar that grew a second
/// item later would move the first one under the reader's thumb after they had learned where
/// it was.
struct ActivityView: View {
    var body: some View {
        NavigationStack {
            Text("WIP")
                .font(.hive(.title3, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // The same heading as every other screen, and the one place it is a label
                // rather than a control: there is no conversation behind this name and
                // nowhere for a tap to go.
                .conversationTitle(mark: .symbol(Self.symbol), title: HomeTab.activity.title)
        }
    }

    /// The mark on the heading — the tab's own symbol, so the bar and the bar's screen say
    /// the same thing. Named here so a test can check the system actually has it.
    static let symbol = "bell"
}
