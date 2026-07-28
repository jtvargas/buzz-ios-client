import BuzzKit
import SwiftUI

/// The shared channel/thread composer: the floating bar, and nothing else.
///
/// # One glass surface
///
/// The bar keeps the shape it has always had — text on the first row, controls on the
/// second, at the size it has always rested at — and comb's composer is the same two rows
/// with its control row pinned the same way. What changed is the material, because the
/// reported defect was never the layout.
///
/// The defect was glass stacked on glass. The shell drew
/// `glassEffect`, and both controls inside it drew their own — `.glass` on the `+`,
/// `.glassProminent` on send. Sampled out of that build's screenshots: over a white
/// conversation the shell rendered 250 against a 255 background and over dense text 247
/// against 206, so about a twentieth of what sits behind the bar came through; and the `+`
/// disc came out a flat 240 with the disabled send a flat 200 *whatever* was behind them.
/// That is not a tuning problem, it is the documented failure: Liquid Glass lenses by
/// sampling the content behind it, and WWDC25 323 states plainly that *"glass can not sample
/// other glass"* — behind those two discs there was no content, only the shell's own glass,
/// so they had nothing to lens and fell back to flat. WWDC25 219 gives both the rule and the
/// remedy in one place: *"always avoid glass on glass … use fills, transparency, and
/// vibrancy for the top elements to make them feel like a thin overlay that is part of the
/// material."*
///
/// So there is exactly **one** glass surface in this view now. The `+` is a bare glyph on
/// it and send is a tinted disc on it — what comb already does with the same two controls,
/// and what Messages, Slack and Grok draw inside their own fields. Nothing else here draws
/// a fill or a border.
///
/// A one-row bar was built and rejected on the way here. It read as a control immediately,
/// but it cost the bar 44 of its 96 points, and the resting size is a product decision that
/// had already been made: see ``minRowsHeight``, which now declares that floor instead of
/// letting it fall out of the layout.
///
/// # What this view is not responsible for
///
/// Where it sits, and the keyboard. The scaffold attaches it with
/// `safeAreaBar(edge: .bottom)`, which is the *only* bottom inset in the hierarchy.
/// A keyboard-height observer, `ignoresSafeArea(.keyboard)`, or a second safe-area
/// inset here would double-count with SwiftUI's own keyboard avoidance — the
/// mechanism behind a keyboard-sized strip left behind after dismissal. The
/// suggestion panel is likewise hosted over the message list, not in this stack, so a
/// keystroke that changes the result count never re-insets the conversation.
///
/// The bar's *height* is read by the scaffold and becomes the keyboard's dismissal band
/// (``ConversationKeyboardDismissPadding``). That is derived, never declared, so this view
/// is free to be as tall as its content needs and the band follows — and it is also why
/// nothing here may pin the bar to a constant height.
///
/// Focus is a single piece of state (`autocomplete.isComposerFocused`), and
/// ``TokenTextView`` is the only thing that turns it into a first responder. The one
/// other place that touches UIKit's responder is ``ConversationKeyboardRelease``, which
/// hands the keyboard back as the whole surface leaves the screen — a transition this
/// view has no way to see. There is no animation on this subtree either: an ambient
/// `.animation` here would catch keyboard-driven layout and run the composer's height on
/// a different clock from the keyboard's.
struct MessageComposerView: View {
    @Binding var document: MentionDraft
    @Bindable var autocomplete: MentionAutocompleteModel
    let placeholder: String
    let sendAccessibilityLabel: String
    var onTextChange: (String) -> Void = { _ in }
    let onSend: () -> Void

    @State private var isShowingWorkInProgress = false
    @State private var wasFocusedBeforeNotice = false

    /// Drawn diameter of the send disc.
    ///
    /// `@ScaledMetric` rather than a constant, and that is a correctness fix rather than a
    /// polish one: the glyph inside is `.body`, which is around 53pt at AX5, so a disc
    /// pinned at 32 would have had the arrow hanging out of it.
    @ScaledMetric(relativeTo: .body) private var controlDiameter: CGFloat = 32
    /// The touch box around a control: never below 44, and never smaller than what is drawn.
    ///
    /// Computed rather than a second `@ScaledMetric` seeded at 44 — that one would scale
    /// *down* at the small Dynamic Type sizes and land near 36 at `.xSmall`, which is the
    /// one direction a 44pt floor must not move.
    private var hitTarget: CGFloat { max(44, controlDiameter) }
    /// The shell's own inset around its two rows.
    private static var shellPadding: CGFloat { 4 }
    /// The gap between the text and the controls beneath it.
    private static var rowSpacing: CGFloat { 2 }
    /// The shell's corner. One value, one shape — fixed rather than derived, because the
    /// shell's height is a function of the draft and a radius taken from it would inflate
    /// into half-stadiums as the author types. 24 is `Radii.sheet` in comb, which is the bar
    /// this one is modelled on.
    private static var cornerRadius: CGFloat { 24 }

    /// The floor under the two rows, and the reason it is written down.
    ///
    /// The bar has always rested at one line of text over a 44pt control row, and the owner
    /// asked for that size to be *fixed* rather than incidental — comb pins its own control
    /// row the same way (`Sizing.hitTarget`). Measured off the shipping build on iPhone 17
    /// Pro / iOS 26: text row 40, gap 2, controls 44. So this is the height the layout
    /// already produces, declared, and it scales with Dynamic Type rather than pinning the
    /// bar to a constant the text can outgrow.
    @ScaledMetric(relativeTo: .body) private var minRowsHeight: CGFloat = 86

    /// The glyph on the filled send disc: black, and measured rather than picked.
    ///
    /// `AccentColor` is a bright amber — sRGB (0.961, 0.659, 0.129) light and
    /// (1.000, 0.729, 0.220) dark, relative luminance 0.476 and 0.566. A white arrow on it
    /// measures **2.0:1** and **1.7:1**, under the 3:1 WCAG 1.4.11 asks of a graphical
    /// object; black measures **10.5:1** and **12.3:1**. Deriving a legible label colour was
    /// the one thing `.buttonStyle(.glassProminent)` did for free, so it is written down
    /// here rather than left to `.white`, which is the reflex and is wrong for this accent.
    /// If the accent ever becomes a dark colour this constant flips, and the arithmetic
    /// above is the check.
    private static var onAccent: Color { .black }

    private var canSend: Bool {
        !document.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        // Discarded, and load-bearing. The field's binding reads the flag *live* (see
        // `field()`), and Observation only records reads made during a `body` pass — so
        // without this read a programmatic `isComposerFocused = true` (tapping the bar's
        // dead space, restoring focus after the alert) has nothing subscribed to it and
        // never reaches `updateUIView`.
        _ = autocomplete.isComposerFocused

        return GlassEffectContainer {
            VStack(alignment: .leading, spacing: Self.rowSpacing) {
                field()
                controls
            }
            // The floor the owner asked for: the bar rests at one line over a control row
            // and cannot come up shorter. See ``minRowsHeight``.
            .frame(minHeight: minRowsHeight, alignment: .top)
            .padding(Self.shellPadding)
            // The *only* glass in this view, now that the two controls have given theirs
            // up — see the note at the top.
            .glassEffect(.clear.interactive(), in: .rect(cornerRadius: Self.cornerRadius))
        }
        // The float: 12pt in from each side, 8pt clear of the bottom.
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onChange(of: document) { _, newValue in
            autocomplete.update(for: newValue)
            onTextChange(newValue.text)
        }
        // The panel is already hidden while the composer is unfocused, but hidden is not
        // closed: the query behind it stayed active, so dismissing the keyboard with its
        // own hide key and bringing it back re-opened the panel on a mention the author
        // had walked away from.
        .onChange(of: autocomplete.isComposerFocused) { _, isFocused in
            guard !isFocused else { return }
            autocomplete.dismiss()
        }
        .task {
            autocomplete.update(for: document)
            await autocomplete.run()
        }
        .alert("WIP", isPresented: $isShowingWorkInProgress) {
            Button("OK", role: .cancel) {}
        }
        // Restored on *dismissal*, not from the OK action: an alert dismissed any other
        // way (a hardware Escape, a programmatic dismissal) would otherwise leave the
        // author mid-draft with no keyboard, and restoring after the alert's own window
        // has gone is also the moment `becomeFirstResponder` can actually succeed.
        .onChange(of: isShowingWorkInProgress) { _, isPresented in
            guard !isPresented, wasFocusedBeforeNotice else { return }
            wasFocusedBeforeNotice = false
            autocomplete.isComposerFocused = true
        }
    }

    /// The editor, filling everything the two controls leave.
    ///
    /// No tap gesture of its own — the text view handles its own touches natively,
    /// which is what puts the caret where the author actually tapped. A SwiftUI
    /// gesture layered over a `UIViewRepresentable` would swallow that.
    ///
    /// `$autocomplete.isComposerFocused` rather than a `Bool` captured in `body`: a
    /// captured value is a snapshot, and `updateUIView` runs on layout passes as well as
    /// on body passes. Measured in the navigation harness — a layout pass between the flag
    /// being cleared and the next `body` re-applied the stale `true` and called
    /// `becomeFirstResponder` again mid-transition, which is a keyboard raised for a
    /// composer that is on its way off the screen.
    private func field() -> some View {
        TokenTextView(
            document: $document,
            isFocused: $autocomplete.isComposerFocused,
            placeholder: placeholder,
            onSelectionChange: autocomplete.updateSelection
        )
        .frame(maxWidth: .infinity)
        .overlay(alignment: .topLeading) {
            if document.text.isEmpty {
                Text(placeholder)
                    .font(.hive(.body))
                    .foregroundStyle(.tertiary)
                    // Aligned to the text container's own insets, so the placeholder
                    // sits exactly where the first glyph will.
                    .padding(.leading, 11)
                    .padding(.top, 9)
                    .allowsHitTesting(false)
            }
        }
    }

    /// Row two: `+` leading, send trailing, and the dead space between them as a focus
    /// target — most of a two-row bar is not the field, and tapping the bar should still
    /// start a draft.
    ///
    /// Neither control draws glass any more. What is left is the two treatments WWDC25 219
    /// permits on top of the material — vibrancy for the quiet action, a fill for the loud
    /// one — which is also exactly what comb does with the same two controls.
    private var controls: some View {
        HStack(spacing: 8) {
            attachButton
            Spacer(minLength: 0)
            sendButton
        }
        // Both controls draw at `controlDiameter` and keep a full 44pt target, so the row
        // stays compact without shrinking what a thumb has to hit.
        .frame(minHeight: hitTarget)
        .padding(.horizontal, 4)
        // Behind the buttons, so they still receive their own taps.
        .background {
            Color.clear
                .contentShape(.rect)
                .onTapGesture { autocomplete.isComposerFocused = true }
        }
    }

    /// A bare glyph on the shell's glass — not a glass button. It sits *on* glass, and a
    /// second layer of the material there is the flat grey disc this replaced. Vibrancy is
    /// the treatment WWDC25 219 prescribes for exactly this, and it carries its own
    /// contrast: symbols over the regular variant flip light-to-dark with the material.
    ///
    /// No disc, so the glyph's box *is* the touch box.
    private var attachButton: some View {
        Button(action: presentWorkInProgress) {
            Image(systemName: "plus")
                .font(.hiveSymbol(.body, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: hitTarget, height: hitTarget)
        }
        // The app's own press treatment rather than a new one — and safe under this file's
        // no-animation rule, because the `.animation` inside it is bound to
        // `configuration.isPressed` and scoped to the label, so it cannot reach the
        // composer's height or catch a keyboard-driven layout pass. It also supplies the
        // `contentShape` that makes the whole frame tappable rather than just the glyph.
        .buttonStyle(PressFeedbackButtonStyle())
        .accessibilityLabel("More options")
    }

    /// A tinted disc drawn at ``controlDiameter`` inside a full ``hitTarget``.
    ///
    /// The one deliberate fill in the view, and the only thing on the bar carrying the
    /// accent: it is what tells an author at a glance whether the draft will go. A fill is
    /// the other treatment 219 allows on top of glass, and it is reserved for the single
    /// primary action. Quiet while there is nothing to send rather than absent, so the row
    /// does not change its metrics on the first keystroke.
    private var sendButton: some View {
        Button(action: send) {
            Image(systemName: "arrow.up")
                .font(.hiveSymbol(.body, weight: .semibold))
                .foregroundStyle(canSend ? Self.onAccent : Color.secondary)
                .frame(width: controlDiameter, height: controlDiameter)
                .background(sendDisc, in: .circle)
                // The target sits outside the disc: the disc stays at `controlDiameter`
                // while what a thumb has to hit stays at 44, or larger at accessibility
                // sizes.
                .frame(width: hitTarget, height: hitTarget)
        }
        .buttonStyle(PressFeedbackButtonStyle())
        .disabled(!canSend)
        .accessibilityLabel(sendAccessibilityLabel)
    }

    /// The accent while there is something to send, a quiet system fill while there is not.
    /// A fill either way, so the shell stays the only glass — and driven off ``canSend``
    /// rather than `\.isEnabled`, because a custom `ButtonStyle` gets no automatic disabled
    /// treatment and the view already computes the predicate.
    private var sendDisc: AnyShapeStyle {
        canSend ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary)
    }

    /// Sends, and leaves the keyboard up.
    ///
    /// Resigning focus here — which the previous version did one run-loop turn later,
    /// mid-animation of this subtree — is what left an empty keyboard-sized area
    /// behind with the composer floating above it. Slack keeps the keyboard up after
    /// a send, and so does this.
    private func send() {
        onSend()
        autocomplete.dismiss()
    }

    private func presentWorkInProgress() {
        wasFocusedBeforeNotice = autocomplete.isComposerFocused
        isShowingWorkInProgress = true
    }

}
