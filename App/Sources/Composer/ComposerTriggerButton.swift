import SwiftUI

/// One of the composer's two quick actions: `@` to name a person, `#` to reference a
/// channel.
///
/// # What it is for
///
/// Both triggers can be typed, and the panel that answers them is the same one either way.
/// What the buttons add is discoverability: nothing on the bar said that typing `@` opens a
/// roster, so the feature was only ever found by people who already knew it was there. The
/// mobile client puts the same two controls in the same row beside its `+`
/// (`compose_bar/layout.dart`, `LucideIcons.atSign` / `LucideIcons.hash`), and they do
/// exactly what these do — put the character in the draft at the caret and hand the keyboard
/// back, so the author carries on typing into an open panel.
///
/// # Why it is a bare glyph
///
/// It sits on the bar's glass beside the `+`, and glass cannot sample glass (WWDC25 323): a
/// second layer of the material here is the flat grey disc ``ComposerAttachButton`` documents
/// getting rid of. Vibrancy is the treatment WWDC25 219 prescribes for a quiet action, which
/// is what all three of the bar's left-hand controls are — the one fill in the row is
/// reserved for send.
///
/// No disc, so the glyph's box *is* the touch box, and it is sized by the bar so every
/// control in the row agrees.
struct ComposerTriggerButton: View {
    let kind: MentionKind
    /// The touch target, sized by the bar so both its controls agree.
    let hitTarget: CGFloat
    /// Puts the trigger in the draft. The insertion rule itself lives in
    /// ``MentionAutocompleteModel/insertTrigger(_:into:)``, beside the caret it needs.
    let insert: (MentionKind) -> Void

    var body: some View {
        Button { insert(kind) } label: {
            Image(systemName: kind.symbolName)
                .font(.hiveSymbol(.body, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: hitTarget, height: hitTarget)
        }
        // The app's own press treatment, and the `contentShape` that comes with it — without
        // one only the glyph is tappable rather than the whole 44pt frame.
        .buttonStyle(.hivePress)
        .accessibilityLabel(kind.quickActionLabel)
    }
}

extension MentionKind {
    /// The glyph on the button. Named here rather than on the kind's own declaration
    /// because it is a fact about this control, not about what a token means.
    var symbolName: String {
        switch self {
        case .user: "at"
        case .channel: "number"
        }
    }

    /// What a screen reader hears. It says what the button *does* rather than naming the
    /// character it inserts — "at sign" is what VoiceOver would read off the glyph anyway,
    /// and it tells nobody what pressing it is for.
    var quickActionLabel: String {
        switch self {
        case .user: "Mention someone"
        case .channel: "Reference a channel"
        }
    }
}
