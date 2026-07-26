import Observation
import SwiftUI

/// One clock for every live-updating timestamp on screen.
///
/// A message younger than twenty minutes has to re-render its own timestamp as it
/// ages; nothing else on the row does. So the app keeps a single coarse clock rather
/// than a timer per row, and only leaves observe it — SwiftUI invalidates the views that
/// actually read a property, so a tick re-evaluates a handful of `Text`s instead of the
/// message list.
///
/// Two kinds of leaf read it: ``MessageTimestampView``, and ``DaySeparatorView``, whose
/// `Today` has to become `Yesterday` when the day turns under a screen that stayed open.
/// Both are their own small views for exactly this reason — the row and the conversation
/// they sit in must not be in the dependency.
///
/// The cadence is fifteen seconds: fine enough that `now` becomes `1 min ago`
/// promptly, coarse enough to be free.
@MainActor
@Observable
final class RelativeTimeTicker {
    /// The coarse current time. Read only from timestamp leaves.
    private(set) var now: Date

    private let interval: Duration

    init(now: Date = Date(), interval: Duration = .seconds(15)) {
        self.now = now
        self.interval = interval
    }

    /// Ticks until cancelled. Attach with `.task`, so a screen that goes away stops
    /// its clock.
    func run() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: interval)
            } catch {
                return
            }
            now = Date()
        }
    }
}

extension EnvironmentValues {
    /// The shared clock behind relative timestamps, injected near the channel list.
    ///
    /// Optional, and `nil` by default, for a mundane reason worth recording: an
    /// environment default is constructed off the main actor, and this clock is
    /// main-actor isolated. A surface with no clock injected (a preview, a test host)
    /// formats correctly at first paint and simply never ages.
    @Entry var relativeTimeTicker: RelativeTimeTicker?
}

/// A message's timestamp — the only view that observes the shared clock.
///
/// Kept as its own leaf so a tick invalidates this `Text` and not the row that owns
/// it: the row's avatar, name, rich content, and reaction chips are untouched.
struct MessageTimestampView: View {
    @Environment(\.relativeTimeTicker) private var ticker

    let date: Date
    var font: Font = .caption

    var body: some View {
        Text(MessageTimestamp.label(for: date, now: ticker?.now ?? Date()))
            .font(font)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            // The spoken form stays absolute: "3 min ago" is unhelpful out of order
            // in VoiceOver's reading of a long list.
            .accessibilityLabel(Text(date, format: .dateTime.hour().minute()))
    }
}
