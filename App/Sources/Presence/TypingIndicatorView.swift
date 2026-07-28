import SwiftUI

/// The "X is typing…" strip shown just above the composer.
///
/// Driven by ``ChannelTypingModel``; hidden entirely when no one is typing, so it
/// takes no vertical space in the common case. Names are resolved by `nameFor` — the
/// timeline supplies known author names and falls back to a short key.
struct TypingIndicatorView: View {
    @State var model: ChannelTypingModel
    let nameFor: (String) -> String

    var body: some View {
        Group {
            if let text = model.indicator(nameFor: nameFor) {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text(text)
                        .font(.hive(.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal)
                .padding(.vertical, 4)
                .transition(.opacity)
            }
        }
        .animation(.default, value: model.typers)
        .task { await model.run() }
    }
}
