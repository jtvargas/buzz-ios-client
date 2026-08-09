import BuzzKit
import SwiftUI

/// Hosts the community-scoped observer above the tab stacks, so one banner can arrive over
/// either tab while navigation remains owned by Home.
struct InAppNotificationHost<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model: InAppNotificationModel

    let isForeground: Bool
    let visibleLocation: InAppNotificationLocation?
    let onOpen: (InAppNotificationRoute) -> Void
    @ViewBuilder let content: () -> Content

    init(
        store: BuzzEventStore,
        engine: SyncEngine,
        selfPubkey: String?,
        isForeground: Bool,
        visibleLocation: InAppNotificationLocation?,
        onOpen: @escaping (InAppNotificationRoute) -> Void,
        @ViewBuilder content: @escaping () -> Content
    ) {
        _model = State(initialValue: InAppNotificationModel(
            store: store,
            engine: engine,
            selfPubkey: selfPubkey,
            isForeground: isForeground,
            visibleLocation: visibleLocation
        ))
        self.isForeground = isForeground
        self.visibleLocation = visibleLocation
        self.onOpen = onOpen
        self.content = content
    }

    var body: some View {
        content()
            .overlay(alignment: .top) {
                if let notification = model.current {
                    InAppNotificationBanner(notification: notification) {
                        onOpen(notification.route)
                        dismiss()
                    } dismiss: {
                        dismiss()
                    }
                    .id(notification.id)
                    .frame(maxWidth: 520)
                    .padding(.horizontal, 12)
                    .safeAreaPadding(.top, 8)
                    .transition(transition)
                    .zIndex(1)
                }
            }
            .animation(animation, value: model.current?.id)
            .task { await model.run() }
            // Keyed on the notification's id, so this is exactly "a banner just became the
            // one on screen" — once per banner, never on a re-render, and never when one is
            // replaced by nothing. Both of the things that belong to that moment live here:
            // the touch that announces it, and the clock that takes it away.
            .task(id: model.current?.id) {
                guard model.current != nil else { return }
                HiveHaptics.play(.messageArrived)
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                dismiss()
            }
            .onChange(of: isForeground, initial: true) { _, active in
                model.setForeground(active)
            }
            .onChange(of: visibleLocation, initial: true) { _, location in
                model.setVisibleLocation(location)
            }
    }

    /// Bounce carries the overshoot: the card travels a little past where it lands and settles
    /// back, which is the system banner's own entrance and the reason it reads as a physical
    /// thing dropping in rather than a rectangle being switched on.
    private var animation: Animation? {
        reduceMotion ? .easeOut(duration: 0.12) : .spring(duration: 0.42, bounce: 0.22)
    }

    /// Insertion also grows the last 3% into place, anchored at the top so the card appears to
    /// come *from* the edge it is sliding out of. Removal deliberately does not shrink — a
    /// dismissal should leave immediately, not perform.
    private var transition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .move(edge: .top)
                .combined(with: .opacity)
                .combined(with: .scale(scale: 0.97, anchor: .top)),
            removal: .move(edge: .top).combined(with: .opacity)
        )
    }

    private func dismiss() {
        withAnimation(animation) { model.dismissCurrent() }
    }
}
