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
    let isHomeSelected: Bool
    @ViewBuilder let content: () -> Content

    init(
        store: BuzzEventStore,
        engine: SyncEngine,
        selfPubkey: String?,
        isForeground: Bool,
        isHomeSelected: Bool,
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
            visibleLocation: nil,
            isHomeSelected: isHomeSelected,
            onOpen: onOpen
        ))
        self.isForeground = isForeground
        self.isHomeSelected = isHomeSelected
        self.content = content
    }

    var body: some View {
        content()
            // Home reports its location through this stable reference. No view above its
            // navigation stack reads that location, so location changes do not rebuild the tabs.
            .environment(model)
            .background(InAppNotificationScenePresenter(controller: model.window))
            .task { await model.run() }
            .onChange(of: isForeground, initial: true) { _, active in
                model.setForeground(active)
            }
            .onChange(of: isHomeSelected, initial: true) { _, selected in
                model.setHomeSelected(selected)
            }
    }
}
