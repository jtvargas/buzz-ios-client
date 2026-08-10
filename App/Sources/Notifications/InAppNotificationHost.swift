import BuzzKit
import SwiftUI

/// Hosts the community-scoped observer above the tab stacks, so one banner can arrive over
/// either tab while navigation remains owned by Home.
///
/// # What this view does and does not do
///
/// It does **not** draw the card, announce it, or take it away. All three belong to
/// ``InAppNotificationModel`` now, because a view cannot be relied upon to do any of them: the
/// case the banner exists for — a message arriving while the reader has a file open — is
/// precisely the case where SwiftUI has stopped updating this tree. The measurement is in
/// ``InAppNotificationWindowController``.
///
/// What is left here is what genuinely needs a view: owning the model for the lifetime of a
/// signed-in community, feeding it the two things only the view tree knows (whether the app is
/// frontmost and what the reader is looking at), and being somewhere in the scene so the
/// overlay window can find it.
struct InAppNotificationHost<Content: View>: View {
    @State private var model: InAppNotificationModel

    let isForeground: Bool
    let visibleLocation: InAppNotificationLocation?
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
        // `onOpen` goes into the model rather than being re-supplied on every body pass, for
        // the same reason everything else moved: when the card is tapped over a preview there
        // has been no body pass for as long as that preview has been up. It captures state
        // whose setters are stable for the life of the scene, which is longer than this model.
        _model = State(initialValue: InAppNotificationModel(
            store: store,
            engine: engine,
            selfPubkey: selfPubkey,
            isForeground: isForeground,
            visibleLocation: visibleLocation,
            onOpen: onOpen
        ))
        self.isForeground = isForeground
        self.visibleLocation = visibleLocation
        self.content = content
    }

    var body: some View {
        content()
            .background(InAppNotificationScenePresenter(controller: model.window))
            .task { await model.run() }
            .onChange(of: isForeground, initial: true) { _, active in
                model.setForeground(active)
            }
            .onChange(of: visibleLocation, initial: true) { _, location in
                model.setVisibleLocation(location)
            }
    }
}
