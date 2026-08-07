import BuzzKit
import SwiftUI
import UIKit

/// A markdown file, rendered.
///
/// Presented over whatever the reader was doing when they pressed the file. The shared parser
/// still understands its markdown, while a document-only web surface gives headings, tables,
/// code and lists native document layout and one selection range across block boundaries. See
/// ``MarkdownDocumentContent`` for the two message-only stages a document deliberately skips.
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

    /// What the share button hands over.
    ///
    /// The file once there is one, and the document's own URL until then — a share button
    /// that is disabled while the document loads is a button the reader presses and nothing
    /// happens, and the link is always shareable because it is what they pressed to get here.
    private enum Share {
        case file(URL)
        case link(URL)

        var url: URL {
            switch self {
            case let .file(url), let .link(url): url
            }
        }
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
    /// The document written back out as a file, once it has arrived. See
    /// ``MarkdownDocumentFile``.
    @State private var file: URL?
    /// The document's own markdown, held for Copy all. See ``copyButton``.
    @State private var source: String?
    /// Set while the copied confirmation is showing, so the button can say it worked.
    @State private var copied = false

    var body: some View {
        NavigationStack {
            content
                .hiveSheetGround()
                .navigationTitle(document.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    // Leading, where a sheet's root has no back button to compete with, so
                    // Done stays exactly where a reader already found it.
                    ToolbarItem(placement: .topBarLeading) { shareButton }
                    ToolbarItem(placement: .topBarLeading) { copyButton }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .task(id: attempt) { await load() }
    }

    /// Hands the file to the system share sheet, or the link until the file exists.
    @ViewBuilder
    private var shareButton: some View {
        let share: Share = file.map(Share.file) ?? .link(document.url)
        ShareLink(
            item: share.url,
            // The document's name in both states. A file URL previews as its last path
            // component anyway; the link would otherwise preview as the whole raw URL,
            // which is the one place a reader sees `raw.githubusercontent.com` spelled out.
            preview: SharePreview(document.name, image: Image(systemName: "doc.text"))
        )
        .accessibilityLabel("Share")
        .accessibilityIdentifier("markdown-share")
    }

    /// Puts the whole document on the pasteboard.
    ///
    /// # Why a button exists at all when the text is already selectable
    ///
    /// The rendered web document supports selection across blocks, but a one-press lossless
    /// copy is still useful for a long file and preserves syntax the rendered copy omits.
    ///
    /// It copies the markdown *source*, not the rendered prose — the same bytes
    /// ``MarkdownDocumentFile`` writes for the share sheet. Pasting a document that had lost
    /// its own markup would be pasting something the file never said.
    @ViewBuilder
    private var copyButton: some View {
        Button {
            guard let source else { return }
            UIPasteboard.general.string = source
            // No haptic, matching ``RichCodeBlock``'s Copy code — the checkmark below is the
            // confirmation, and every impact style in ``HiveHaptic`` already names a different
            // gesture. Borrowing one would make its name a lie on this surface.
            withAnimation(.easeOut(duration: 0.15)) { copied = true }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.4))
                withAnimation(.easeOut(duration: 0.2)) { copied = false }
            }
        } label: {
            Label("Copy all", systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        .disabled(source == nil)
        .accessibilityIdentifier("markdown-copy-all")
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
            MarkdownDocumentWebView(message: message, baseURL: document.url)
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
        file = nil
        source = nil
        let authorization = environment?.mediaReadAuthorizer
        do {
            let text = try await MarkdownDocumentLoader.text(
                for: document, authorization: authorization
            )
            // The parse and the write are both off the main actor, and both are the same
            // arrival: what the reader sees is a sheet that has already presented, not one
            // that hitches while a few thousand lines are scanned and put on disk.
            let document = document
            let (message, written) = await Task.detached(priority: .userInitiated) {
                (
                    MarkdownDocumentContent.message(for: text),
                    MarkdownDocumentFile.write(text, for: document)
                )
            }.value
            file = written
            source = text
            phase = .loaded(message)
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription
                ?? MarkdownDocumentLoader.Failure.download.errorDescription
            phase = .failed(reason ?? "")
        }
    }
}
