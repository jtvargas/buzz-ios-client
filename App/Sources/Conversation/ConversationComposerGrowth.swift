import SwiftUI

extension View {
    /// Runs `perform` once on the first bar-height reading that follows a *declared* change to
    /// the composer's height.
    ///
    /// # What this is for
    ///
    /// The composer is attached to the conversation with `safeAreaBar`, so its height is the
    /// message list's only bottom inset. A picture attached to a draft puts a 72-point strip
    /// above the text field, which takes that much room off the bottom of the scrollable
    /// region — exactly what a rising keyboard does, and with the same consequence if nothing
    /// answers it: the newest message ends up behind the pictures.
    ///
    /// Most conversations answer it for free. A scroll view already resting against its bottom
    /// has its offset clamped up when an inset takes room there. The ones that do not are those
    /// whose content landed *after* the first layout — which is how every real thread in this
    /// app opens. Measured on iPhone 17 Pro / iOS 26 against a 72-point strip
    /// (`ComposerGrowthTests`, before this existed): `thread-8-longlast` moved 73 points and
    /// `channel-50-plain` 73, while `thread-8-longlast-primed` — the same content delivered one
    /// relay round trip later — moved **0**, leaving 60 points of the newest message under the
    /// strip.
    ///
    /// # Why it takes both a declaration and a measurement
    ///
    /// Neither one alone is enough, and each covers the other's gap.
    ///
    /// The **declaration** arrives in the update pass that adds the strip, which is *before*
    /// the bar has been laid out. A scroll issued there aims at the inset the conversation is
    /// about to stop having.
    ///
    /// The **measurement** — the bar's own height, which ``ConversationScaffold`` already reads
    /// for the accessory and the keyboard's dismissal band — is written after layout, so it is
    /// the first moment the new inset exists. But it also moves every time a draft gains a
    /// line, and acting on that reading is what turned the composer-growth suite into a runner
    /// the harness killed as unresponsive, twice, with the diagnosis still open. A keystroke
    /// declares nothing, so an armed flag is what keeps this off that path entirely.
    ///
    /// So: the declaration says *whether*, the measurement says *when*.
    ///
    /// - Parameters:
    ///   - revision: any value the owner changes when the bar is about to be a different
    ///     height. Its value means nothing — only that it changed.
    ///   - barHeight: the bar's measured height, read after layout.
    func onComposerHeightChange(
        declaredBy revision: Int,
        measuredBy barHeight: CGFloat,
        perform: @escaping () -> Void
    ) -> some View {
        modifier(ConversationComposerGrowth(revision: revision, barHeight: barHeight, perform: perform))
    }
}

/// The arming behind ``SwiftUI/View/onComposerHeightChange(declaredBy:measuredBy:perform:)``.
///
/// Its own type so the flag is state nothing else can reach: the whole safety of this path is
/// that a bar-height reading does nothing unless a declaration armed it, and a flag living
/// beside the scaffold's other state is one `if` away from being read by something else.
private struct ConversationComposerGrowth: ViewModifier {
    let revision: Int
    let barHeight: CGFloat
    let perform: () -> Void

    @State private var isArmed = false

    func body(content: Content) -> some View {
        content
            .onChange(of: revision) { isArmed = true }
            .onChange(of: barHeight) {
                guard isArmed else { return }
                isArmed = false
                perform()
            }
    }
}
