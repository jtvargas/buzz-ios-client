import BuzzKit
import SwiftUI
import UIKit

/// The picture two quick taps were meant for.
///
/// A wrapper rather than a bare `MessageMedia?` for the reason ``MessageActionTarget`` is one:
/// `sheet(item:)` keys the presentation off it, so double-tapping a second picture while the
/// first sheet is still animating away re-presents for the new one instead of showing the old
/// one's actions.
struct MediaActionsTarget: Identifiable, Equatable {
    let media: MessageMedia
    /// What is already on screen for this attachment, used as the share sheet's thumbnail so
    /// it has something to draw before the original has finished arriving. Not what is
    /// shared — see ``MessageMediaExport``.
    let preview: UIImage?

    var id: String { media.url }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.media == rhs.media }
}

/// What a reader can do with a picture in a conversation: keep it, or pass it on.
///
/// # Why this is not the message's actions sheet
///
/// The owner asked for a double tap on a message to open the reactions, and for a double tap
/// on a *picture inside* one to do the same. It cannot: a picture is a `Button`, and SwiftUI
/// fires a button **once** for a pair of taps close enough together to be a double — which is
/// exactly the pair a reader makes — so the row never sees a second tap to count. Told that,
/// the owner asked for the picture to answer with its own sheet instead: save it, or share it.
///
/// That is the better shape anyway, and not only because it works. The actions on the message
/// sheet are about the *message* — react to it, copy its text, reply in a thread — and every
/// one of them is still one tap away on the text an inch above. Save and Share are about the
/// picture, and there was nowhere in the app to do either.
///
/// The background is deliberately not set, as on ``MessageActionsSheet``: a sheet's default
/// background is the system's Liquid Glass, and nothing inside should draw its own.
struct MediaActionsSheet: View {
    let target: MediaActionsTarget
    /// The session the original is fetched over. Injectable so a test can answer without a
    /// relay; defaults to the one session every export shares.
    var session: URLSession = MessageMediaExport.session

    @Environment(\.dismiss) private var dismiss
    /// The fetched original, on disk. Its presence is what arms both rows: neither action can
    /// run on a picture that has not arrived, and neither is offered as though it could.
    @State private var file: URL?
    @State private var isSaving = false
    @State private var failure: MessageMediaExport.Failure?

    /// The height of one action row. The same 52 the message sheet's rows take, so the two
    /// sheets a message can open read as one family — but *scaled*, because this sheet is
    /// sized to its contents rather than given the slack a five-row sheet has: two rows grown
    /// for a reader at an accessibility text size do not fit inside a fixed 160, and what
    /// would be lost is the second row.
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 52

    /// The two rows, the top padding, and room for the drag indicator above them.
    private var detentHeight: CGFloat { rowHeight * 2 + 44 }

    var body: some View {
        VStack(spacing: 0) {
            saveRow
            shareRow
            Spacer(minLength: 0)
        }
        .padding(.top, 12)
        .presentationDetents([.height(detentHeight)])
        .presentationDragIndicator(.visible)
        .task { await prepare() }
        .alert(
            "Couldn't do that",
            isPresented: .init(get: { failure != nil }, set: { if !$0 { failure = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure?.errorDescription ?? "")
        }
    }

    // MARK: - Rows

    private var saveRow: some View {
        Button(action: save) {
            label("Save Image", symbol: "square.and.arrow.down", isBusy: isSaving)
        }
        .buttonStyle(.hivePress(.row))
        .disabled(file == nil || isSaving)
    }

    /// The system share sheet, over the file rather than over the picture's URL.
    ///
    /// The URL would be the cheaper item and it is the wrong one: this deployment's media host
    /// is tailnet-only, so a link passed to anybody resolves to nothing for them. The file is
    /// the picture itself, and it carries its own name and type — see ``MessageMediaExport``.
    @ViewBuilder
    private var shareRow: some View {
        if let file {
            ShareLink(item: file, preview: sharePreview) {
                label("Share", symbol: "square.and.arrow.up", isBusy: false)
            }
            .buttonStyle(.hivePress(.row))
        } else {
            // The same row, inert. Drawn rather than omitted so the sheet does not change
            // height or reorder under the reader's thumb the moment the download lands.
            label("Share", symbol: "square.and.arrow.up", isBusy: false)
                .opacity(0.4)
        }
    }

    /// What the share sheet draws at the top of itself while the reader chooses where the
    /// picture is going. Always carries an image — a symbol where the row has no bitmap in
    /// hand — because a preview without one collapses the sheet's header to a bare filename.
    private var sharePreview: SharePreview<Image, Never> {
        let title = target.media.alt ?? "Picture"
        let image = target.preview.map { Image(uiImage: $0) } ?? Image(systemName: "photo")
        return SharePreview(title, image: image)
    }

    /// One row of this sheet, matching ``MessageActionsSheet``'s exactly — same gutter, same
    /// height, same insets — because both open from the same gesture on the same message.
    private func label(_ title: String, symbol: String, isBusy: Bool) -> some View {
        HStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.hiveSymbol(.body))
                .frame(width: 24)
            Text(title)
                .font(.hive(.body))
            Spacer(minLength: 0)
            if isBusy {
                ProgressView()
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 20)
        .frame(minHeight: rowHeight)
        .contentShape(.rect)
    }

    // MARK: - Doing

    /// Fetches the original as the sheet arrives, so both rows are armed by the time a thumb
    /// has travelled to one.
    ///
    /// A failure here leaves the rows disabled and says nothing: the reader has not asked for
    /// anything yet, and an alert over a sheet they only just opened would be answering a
    /// question nobody put. Pressing Save then reports it, which is the moment it matters.
    private func prepare() async {
        guard file == nil else { return }
        file = try? await MessageMediaExport.fetch(target.media, session: session)
    }

    private func save() {
        guard let file, !isSaving else { return }
        isSaving = true
        Task {
            do {
                try await MessageMediaExport.addToPhotoLibrary(file)
                // The app's confirmation tick, not a new one: a light impact is what ``send``
                // already means — *the thing you asked for has happened* — and the haptic
                // vocabulary is closed on purpose. See ``HiveHaptic``.
                HiveHaptics.play(.send)
                dismiss()
            } catch let error as MessageMediaExport.Failure {
                failure = error
                isSaving = false
            } catch {
                failure = .save
                isSaving = false
            }
        }
    }
}
