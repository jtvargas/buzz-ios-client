import BuzzKit
import SwiftUI

/// Every conversation holding unsent text, in one place: what you were writing, where it
/// would go, and a way back to it.
///
/// # Why a row's tap opens the composer rather than the conversation
///
/// A draft is unfinished writing, so the only reason to come here is to finish it. The
/// row lands in the conversation *with the keyboard already up and the text in the bar* —
/// the same arrival the actions sheet's "Reply in thread" produces. Opening the
/// conversation and leaving the reader to tap the composer would make this screen a
/// slower way to reach something they could already reach from the sidebar.
///
/// # Deleting
///
/// Two ways, because they answer different questions. A swipe throws away one draft you
/// have decided against; Select turns the list into a multiple choice for clearing out
/// several at once. Delete All confirms first — it is the one action here that can
/// destroy writing the reader has not looked at.
struct DraftsView: View {
    @Environment(\.entityNames) private var names

    let model: DraftsModel
    /// Opens a draft's conversation with its composer focused. Held by the sidebar,
    /// because the push belongs to that stack — the same reason ``ThreadsView`` takes its
    /// opened thread as a binding.
    let open: (ComposerDraftSummary) -> Void

    @State private var isSelecting = false
    @State private var selection: Set<String> = []
    @State private var confirmsDeleteAll = false

    var body: some View {
        List(selection: $selection) {
            ForEach(model.summaries) { summary in
                row(summary)
            }
        }
        .listStyle(.plain)
        .environment(\.editMode, .constant(isSelecting ? .active : .inactive))
        .navigationTitle("Drafts")
        .navigationBarTitleDisplayMode(.inline)
        .overlay { emptyState }
        .toolbar { toolbar }
        .confirmationDialog(
            "Delete all drafts?",
            isPresented: $confirmsDeleteAll,
            titleVisibility: .visible
        ) {
            Button("Delete All", role: .destructive) {
                HiveHaptics.play(.delete)
                model.deleteAll()
                endSelecting()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(Self.deleteAllWarning(count: model.summaries.count))
        }
        // The list is only re-read while somebody is looking at it: the table behind it is
        // written on every keystroke, anywhere in the app.
        .task { await model.runList() }
        // A list that empties itself has nothing left to select from, and leaving the bar
        // in Select mode over an empty screen strands the Done button as the only control.
        .onChange(of: model.summaries.isEmpty) { _, isEmpty in
            if isEmpty { endSelecting() }
        }
    }

    // MARK: - Rows

    /// While selecting, the row is **not** a button.
    ///
    /// A `List` in edit mode turns a tap into a selection, but only for a row that does not
    /// already own its touches: a `Button` swallows the tap and the circle beside it never
    /// fills. So the press is built conditionally — the same shape the message row's long
    /// press needed for the same reason.
    @ViewBuilder
    private func row(_ summary: ComposerDraftSummary) -> some View {
        let content = DraftRow(summary: summary, conversation: names.conversation(for: summary.channelID))
        if isSelecting {
            content
                .listRowSeparator(.hidden)
        } else {
            Button { open(summary) } label: { content }
                // The sidebar's press treatment in the sidebar's own emphasis, and the reason
                // it is a `Button` at all: a `NavigationLink` inside a `List` draws a
                // disclosure chevron no modifier declines, and these rows do not push from
                // here — the sidebar's stack does. A row washes and does not shrink; these
                // sit in a list beside a swipe action, and a row that pulled in from both
                // edges under a finger would read as the swipe starting.
                .buttonStyle(.hivePress(.row))
                .listRowSeparator(.hidden)
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        // A swipe action gets no feedback from the system, and this one
                        // destroys something with no confirmation in front of it.
                        HiveHaptics.play(.delete)
                        model.delete([summary.id])
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.hasLoaded, model.summaries.isEmpty {
            ContentUnavailableView {
                Label("No drafts", systemImage: HomeShortcut.drafts.symbol)
            } description: {
                Text("Messages you start and don't send will wait here.")
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if isSelecting {
            ToolbarItem(placement: .topBarLeading) {
                Button("Done") { endSelecting() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Delete", role: .destructive) {
                    HiveHaptics.play(.delete)
                    model.delete(selection)
                    endSelecting()
                }
                .disabled(selection.isEmpty)
            }
        } else if !model.summaries.isEmpty {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Select") { isSelecting = true }
                    Button("Delete All", role: .destructive) { confirmsDeleteAll = true }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
    }

    private func endSelecting() {
        isSelecting = false
        selection = []
    }

    /// What Delete All is about to destroy, counted. Static and pure so the plural is
    /// pinned by a test rather than by reading the dialog.
    static func deleteAllWarning(count: Int) -> String {
        "This throws away \(count) unsent \(count == 1 ? "message" : "messages")."
    }
}
