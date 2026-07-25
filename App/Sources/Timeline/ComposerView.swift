import SwiftUI

/// The message composer: a Liquid Glass capsule field and a prominent send button
/// in a `GlassEffectContainer` (spec §Liquid Glass). Send is optimistic — the row
/// appears the instant it is queued; an over-ceiling message is refused inline with
/// the text preserved.
struct ComposerView: View {
    @Bindable var model: ChannelTimelineModel
    @FocusState private var isFocused: Bool

    private var canSend: Bool {
        !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message", text: $model.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1 ... 5)
                    .focused($isFocused)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: .capsule)
                    .onChange(of: model.draft) { _, newValue in
                        model.handleTyping(newValue)
                    }

                Button {
                    model.send()
                    isFocused = false
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.body.weight(.semibold))
                        .padding(6)
                }
                .buttonStyle(.glassProminent)
                .clipShape(.circle)
                .disabled(!canSend)
                .accessibilityLabel("Send")
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .animation(.default, value: canSend)
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
