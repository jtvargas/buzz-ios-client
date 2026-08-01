import SwiftUI

/// The canvas editor, pushed on the details sheet's own navigation stack.
///
/// A push rather than a second sheet, for the reason Part 13 wrote down: a modal
/// presented from inside a modal races the first one's dismissal and UIKit drops it.
/// A push also gives the document the whole sheet, which a Markdown body needs — a
/// canvas is prose, not a field.
struct ChannelCanvasEditor: View {
    @Binding var text: String
    let onSave: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        TextEditor(text: $text)
            .font(.hiveMono(.body))
            // Monospaced deliberately: this is the Markdown *source*, and the reader is
            // about to type `#` and `-` into it. Rendering it here would hide the very
            // characters they are editing.
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 12)
            .focused($isFocused)
            .navigationTitle("Canvas")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: onSave)
                }
            }
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Write the channel’s canvas in Markdown…")
                        .font(.hive(.body))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 17)
                        .padding(.top, 8)
                        .allowsHitTesting(false)
                }
            }
            // Focus on arrival, not on appear: `.task` runs at the start of the push, and
            // focus applied before the view has settled fails silently (see Part 13's
            // 450ms composer note). A push settles faster than a sheet, but not instantly.
            .task {
                try? await Task.sleep(for: .milliseconds(450))
                isFocused = true
            }
    }
}
