import SwiftUI

/// Channel-specific shell around the shared mention-aware composer.
struct ComposerView: View {
    @Bindable var model: ChannelTimelineModel

    var body: some View {
        MessageComposerView(
            document: $model.mentionDraft,
            autocomplete: model.mentionAutocomplete,
            attachments: model.attachments,
            placeholder: "Message",
            sendAccessibilityLabel: "Send",
            onTextChange: model.handleTyping,
            onSend: model.send
        )
        .alert(
            "Message not sent",
            isPresented: Binding(
                get: { model.sendError != nil },
                set: { if !$0 { model.sendError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { model.sendError = nil }
        } message: {
            Text(model.sendError ?? "")
        }
    }
}
