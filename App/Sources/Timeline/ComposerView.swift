import SwiftUI

/// Channel-specific shell around the shared mention-aware composer.
struct ComposerView: View {
    @Bindable var model: ChannelTimelineModel
    @Environment(AppEnvironment.self) private var appEnvironment: AppEnvironment?
    @Environment(\.entityNames) private var names

    var body: some View {
        MessageComposerView(
            document: $model.mentionDraft,
            autocomplete: model.mentionAutocomplete,
            attachments: model.attachments,
            placeholder: "Message",
            sendAccessibilityLabel: "Send",
            onTextChange: model.handleTyping,
            onSend: {
                model.send { mentions in
                    appEnvironment?.prepareAgentMonitoringForSend(
                        channel: model.channel, mentions: mentions, names: names, sender: model.sender
                    )
                }
            }
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
