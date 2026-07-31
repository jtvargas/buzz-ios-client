import Foundation

/// Resolves a tap on a message into either the message's own action — open the thread, open
/// the picture — or its actions sheet, by waiting long enough to find out whether a second
/// tap is coming.
///
/// # Why a single tap has to wait
///
/// A double tap is not a gesture the first tap can be told about. The two taps are the same
/// event twice, and the only thing separating "one tap" from "the first half of two" is
/// *time passing without a second one*. So a message's own action cannot run on the first
/// tap — the thread would already be pushed, or the picture already open, by the time the
/// second tap landed, and it would land on whatever replaced the screen.
///
/// That is the whole cost of double-tap-to-react, and it is paid by the most common gesture
/// in the app. It is kept as small as it can be in two ways:
///
/// - ``doubleTapWindow`` is set to the shortest interval a deliberate double tap fits inside
///   rather than to the longest one the system would accept;
/// - a surface with **no** sheet to open — the Threads screen's summaries, a deleted message
///   — passes `nil` for the second action and its taps are not deferred at all. Nothing waits
///   for a gesture that has nowhere to go.
///
/// # Why this is a type and not four lines in the row
///
/// It was four lines in the row, and the four lines are not the risk: the risk is that a
/// single tap silently stops working, which is a defect this surface has now shipped twice
/// and which no reading of the code caught either time. As a type it is exercised directly —
/// *one tap still runs its action*, *two taps run the sheet and never the action* — on the
/// unit-test gate that runs on every pull request, rather than only in the UI suite that is
/// run by hand.
@MainActor
final class MessageTapArbiter {
    /// How long the message's own action waits to find out that no second tap is coming.
    ///
    /// 250ms. The interval between the two taps of a deliberate double tap is around
    /// 120–200ms; UIKit's own recognisers accept a longer gap than that, and every
    /// millisecond of it would be added to opening a thread. So this is deliberately at the
    /// short end: a double tap slower than a quarter of a second opens the thread instead,
    /// which is recoverable, where a quarter-second wait in front of every tap is felt on
    /// every message.
    ///
    /// It is the dial to turn if either half reads wrong — longer for a double tap that is
    /// missed, shorter for a tap that feels slow — and it is the only number here.
    static let doubleTapWindow: TimeInterval = 0.25

    /// How long after a double tap has been answered further taps belonging to *the same
    /// gesture* are dropped.
    ///
    /// A double tap can arrive here by two routes — as two taps counted by this type, or as
    /// one `TapGesture(count: 2)` reported by a control that fires only once for a fast pair
    /// (see ``doubleTapped(_:)``) — and on a real finger both can fire for one gesture. Without
    /// this, the tail of an answered double starts a *fresh* single: the sheet would open and
    /// the picture would open behind it a quarter of a second later.
    ///
    /// Longer than ``doubleTapWindow`` because what it has to outlast is the second tap's own
    /// arrival, not another wait.
    static let settleWindow: TimeInterval = 0.4

    private let window: TimeInterval
    private let settle: TimeInterval
    /// Injected so the settle window can be tested without sleeping through it.
    private let now: () -> Date
    /// When a double tap was last answered, or `nil` if none has been.
    private var resolvedAt: Date?
    /// The first tap's action, waiting out the window. Its presence *is* the record that a
    /// tap is in flight: a second tap arriving while it exists is the second half of a
    /// double, and there is no separate flag that could disagree with it.
    private var pending: Task<Void, Never>?

    init(
        window: TimeInterval = MessageTapArbiter.doubleTapWindow,
        settle: TimeInterval = MessageTapArbiter.settleWindow,
        now: @escaping () -> Date = { .now }
    ) {
        self.window = window
        self.settle = settle
        self.now = now
    }

    /// Whether a tap is still waiting to find out it was single.
    var isWaiting: Bool { pending != nil }

    /// Whether a double tap was answered recently enough that a tap arriving now is more
    /// likely to be its tail than a new gesture. See ``settleWindow``.
    private var isSettling: Bool {
        guard let resolvedAt else { return false }
        return now().timeIntervalSince(resolvedAt) < settle
    }

    /// Resolves one tap.
    ///
    /// - Parameters:
    ///   - single: what this tap means on its own — open the thread, open the picture.
    ///     Runs ``doubleTapWindow`` later, or immediately when there is no `double`.
    ///   - double: what two quick taps mean — the actions sheet. `nil` on a surface that
    ///     presents none, which is what keeps taps there instant.
    func tapped(single: @escaping () -> Void, double: (() -> Void)?) {
        guard let double else {
            cancel()
            single()
            return
        }
        // The tail of a double tap that has already been answered. Dropped rather than
        // treated as a new first tap: see ``settleWindow``.
        guard !isSettling else { return }
        if pending != nil {
            resolve(double)
            return
        }
        pending = Task { [weak self, window] in
            try? await Task.sleep(for: .seconds(window))
            guard !Task.isCancelled else { return }
            self?.pending = nil
            // Deliberately not guarded on `self`: the row may have been recycled out from
            // under the wait, and a tap that has already been paid for must still be
            // honoured. A dropped tap is the failure this surface is repeatedly reported
            // for; a thread opening from a row that has scrolled away is not.
            single()
        }
    }

    /// Answers a double tap the *system* recognised as one, from a control that cannot report
    /// it as two taps.
    ///
    /// A SwiftUI `Button` fires **once** for a pair of taps close enough together to be a
    /// double — which is exactly the pair a reader makes. Measured, not assumed: two taps
    /// spaced ~400ms apart on an inline picture reached ``tapped(single:double:)`` twice and
    /// opened the sheet, while a real double tap on the same picture reached it once and
    /// opened the picture a quarter of a second later. A plain `TapGesture` has no such
    /// coalescing, which is why the message's *text* worked from the first build and the
    /// picture inside it did not.
    ///
    /// So a control whose activation is a `Button` also carries a `TapGesture(count: 2)` and
    /// reports through here. Both routes may fire for one gesture on a real finger; that is
    /// what ``settleWindow`` is for.
    ///
    /// - Parameter double: the actions sheet, or `nil` on a surface presenting none — where a
    ///   double tap means nothing and the pending single is deliberately left alone.
    func doubleTapped(_ double: (() -> Void)?) {
        guard let double, !isSettling else { return }
        resolve(double)
    }

    /// Drops a tap that is still waiting, without running it.
    func cancel() {
        pending?.cancel()
        pending = nil
    }

    /// Answers a double tap: the waiting single never runs, and the tail of the same gesture
    /// is dropped rather than starting another one.
    private func resolve(_ double: () -> Void) {
        cancel()
        resolvedAt = now()
        double()
    }
}
