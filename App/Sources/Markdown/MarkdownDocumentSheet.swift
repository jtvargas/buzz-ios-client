import BuzzKit
import SwiftUI

/// A markdown file, rendered.
///
/// Presented over whatever the reader was doing when they pressed the file, and drawn by
/// ``RichTextView`` — the same renderer the conversation uses, so the document's headings,
/// tables, code and lists are the ones they already know. See ``MarkdownDocumentContent`` for
/// the two message-only stages a document deliberately skips.
///
/// # Why the parse happens off the main actor
///
/// A README is a few thousand lines and the parse is a linear scan, but it is a scan of a
/// string that has just arrived over the network, on the actor that is also animating the
/// sheet up. Both halves — the fetch and the parse — run in the task; only the finished blocks
/// come back. What the reader sees while that happens is a spinner in a sheet that has already
/// finished presenting, rather than a sheet that hitches on the way in.
struct MarkdownDocumentSheet: View {
    /// What the sheet is showing at any moment. One value rather than three flags: a document
    /// is loading, or it is a document, or it is a reason it is not — never two of those.
    private enum Phase {
        case loading
        case loaded(RichMessage)
        case failed(String)
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    /// The signer a hosted relay's blob store requires on a read. Optional because this sheet
    /// also opens files on the open web, which need none — and because the environment has no
    /// session at all before a community is open.
    @Environment(AppEnvironment.self) private var environment: AppEnvironment?

    let document: MarkdownDocument

    @State private var phase: Phase = .loading
    /// Bumped by Try again, which is what re-runs the `.task`.
    @State private var attempt = 0

    var body: some View {
        NavigationStack {
            content
                .hiveSheetGround()
                .navigationTitle(document.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .task(id: attempt) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            // Centred in the sheet rather than at the top: the sheet is already full height,
            // and a spinner under the navigation bar reads as a document that has started
            // arriving when nothing has.
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .loaded(message):
            ScrollView {
                RichTextView(message)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 40)
                    // A document is read, not skimmed for who said it, so its text is
                    // selectable where a message's deliberately is not — there is no row tap
                    // and no thread underneath for a selection gesture to steal.
                    .textSelection(.enabled)
            }
        case let .failed(reason):
            failure(reason)
        }
    }

    private func failure(_ reason: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.questionmark")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            Text(reason)
                .font(.hive(.subheadline))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("Try again") { attempt += 1 }
                    .buttonStyle(.bordered)
                // The way out that always works: whatever the app could not do with this file,
                // the browser can be handed the same URL.
                Button("Open in browser") { openURL(document.url) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() async {
        phase = .loading
        let authorization = environment?.mediaReadAuthorizer
        do {
            let text = try await MarkdownDocumentLoader.text(
                for: document, authorization: authorization
            )
            let message = await Task.detached(priority: .userInitiated) {
                MarkdownDocumentContent.message(for: text)
            }.value
            phase = .loaded(message)
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription
                ?? MarkdownDocumentLoader.Failure.download.errorDescription
            phase = .failed(reason ?? "")
        }
    }
}
