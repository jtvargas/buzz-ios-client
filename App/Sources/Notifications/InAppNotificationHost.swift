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
            .task(id: model.current?.id) {
                guard model.current != nil else { return }
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

    private var animation: Animation? {
        reduceMotion ? .easeOut(duration: 0.12) : .spring(duration: 0.42, bounce: 0.16)
    }

    private var transition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .move(edge: .top).combined(with: .opacity),
            removal: .move(edge: .top).combined(with: .opacity)
        )
    }

    private func dismiss() {
        withAnimation(animation) { model.dismissCurrent() }
    }
}
