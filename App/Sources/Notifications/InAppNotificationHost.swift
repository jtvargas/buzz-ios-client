import BuzzKit
import SwiftUI

/// Hosts the community-scoped observer above the tab stacks, so one banner can arrive over
/// either tab while navigation remains owned by Home.
///
/// The card itself is not drawn here — it is drawn in its own window, because an overlay
/// anywhere in this tree is underneath any sheet the app presents. See
/// ``InAppNotificationWindowController``. What stays here is everything that is not drawing:
/// the observer, the visibility rules, the auto-dismiss clock and the arrival haptic.
struct InAppNotificationHost<Content: View>: View {
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
            .background(
                InAppNotificationWindowPresenter(
                    notification: model.current,
                    open: { notification in
                        onOpen(notification.route)
                        dismiss()
                    },
                    dismiss: dismiss
                )
            )
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

    /// Unanimated here on purpose: the card's entrance and exit are animated inside the
    /// overlay window, which is the only place that can see them.
    private func dismiss() {
        model.dismissCurrent()
    }
}
