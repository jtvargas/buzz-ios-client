import BuzzKit
import SwiftUI

/// The shared channel/thread composer: the floating bar, and nothing else.
///
/// # One shell, two rows
///
/// A single glass container with the text on the first row and the controls beneath
/// it. The shape it replaced was a field-pill nested inside a bar-pill, which forced
/// the text into a narrow slot between two buttons — and two concentric rounded
/// rectangles a few points apart never stop looking like an accident. There is no
/// opaque fill and no border anywhere: the only surface is the glass.
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
/// Focus is a single piece of state (`autocomplete.isComposerFocused`) that only
/// ``TokenTextView`` reconciles into UIKit, and there is no animation on this
/// subtree: an ambient `.animation` here would catch keyboard-driven layout and run
/// the composer's height on a different clock from the keyboard's.
struct MessageComposerView: View {
    @Binding var document: MentionDraft
    @Bindable var autocomplete: MentionAutocompleteModel
    let placeholder: String
    let sendAccessibilityLabel: String
    var onTextChange: (String) -> Void = { _ in }
    let onSend: () -> Void

    @State private var isShowingWorkInProgress = false
    @State private var wasFocusedBeforeNotice = false

    /// The shell's corner radius. One value, one shape.
    private static var cornerRadius: CGFloat { 24 }
    /// Drawn size of a control glyph, inside a full 44pt hit area.
    private static var controlSize: CGFloat { 32 }
    private static var hitTarget: CGFloat { 44 }

    private var canSend: Bool {
        !document.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        // Read here, in `body`, on purpose. Focus is only *used* inside the binding
        // closure `TokenTextView` invokes, and an observable property read from outside a
        // body registers no dependency — so a programmatic `isComposerFocused = true`
        // (tapping the bar's dead space, restoring focus after the alert) had nothing
        // subscribed to it and could simply never reach `updateUIView`.
        let isFocused = autocomplete.isComposerFocused

        return GlassEffectContainer(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                field(isFocused: isFocused)
                controls
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
            // Plain, not `.interactive()`. The shell is a container, not a control:
            // interactive glass flexes on touch, and on a two-row bar that meant the
            // whole composer reacting to a tap whose only job was to place the caret.
            // The two controls carry their own interactivity through their styles.
            .glassEffect(.regular, in: .rect(cornerRadius: Self.cornerRadius))
        }
        // The float: 12pt in from each side, 8pt clear of the bottom.
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onChange(of: document) { _, newValue in
            autocomplete.update(for: newValue)
            onTextChange(newValue.text)
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

    /// Row one: the editor, full width, with the placeholder drawn over it.
    ///
    /// No tap gesture of its own — the text view handles its own touches natively,
    /// which is what puts the caret where the author actually tapped. A SwiftUI
    /// gesture layered over a `UIViewRepresentable` would swallow that.
    private func field(isFocused: Bool) -> some View {
        TokenTextView(
            document: $document,
            isFocused: Binding(
                get: { isFocused },
                set: { autocomplete.isComposerFocused = $0 }
            ),
            placeholder: placeholder
        )
        .frame(maxWidth: .infinity)
        .overlay(alignment: .topLeading) {
            if document.text.isEmpty {
                Text(placeholder)
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    // Aligned to the text container's own insets, so the placeholder
                    // sits exactly where the first glyph will.
                    .padding(.leading, 11)
                    .padding(.top, 9)
                    .allowsHitTesting(false)
            }
        }
    }

    /// Row two: `+` leading, send trailing, and the dead space between them as a
    /// focus target — most of a two-row bar is not the field, and tapping the bar
    /// should still start a draft.
    private var controls: some View {
        HStack(spacing: 8) {
            Button(action: presentWorkInProgress) {
                Image(systemName: "plus")
                    .font(.body.weight(.semibold))
                    .frame(width: Self.controlSize, height: Self.controlSize)
            }
            .buttonStyle(.glass)
            .clipShape(.circle)
            .accessibilityLabel("More options")

            Spacer(minLength: 0)

            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.body.weight(.semibold))
                    .frame(width: Self.controlSize, height: Self.controlSize)
            }
            .buttonStyle(.glassProminent)
            .clipShape(.circle)
            .disabled(!canSend)
            .accessibilityLabel(sendAccessibilityLabel)
        }
        // Both controls draw at 32 and keep a full 44pt target, so the row stays
        // compact without shrinking what a thumb has to hit.
        .frame(minHeight: Self.hitTarget)
        .padding(.horizontal, 4)
        // Behind the buttons, so they still receive their own taps.
        .background {
            Color.clear
                .contentShape(.rect)
                .onTapGesture { autocomplete.isComposerFocused = true }
        }
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
