import BuzzKit
import SwiftUI

/// A generic file attachment, placed where its explicit markdown link was authored.
struct FileAttachmentCard: View {
    @Environment(AppEnvironment.self) private var environment: AppEnvironment?

    let file: MessageMedia

    @State private var isLoading = false
    /// The downloaded file, once it is on disk. Non-`nil` is what raises the preview, and
    /// Quick Look clears it again when it closes.
    @State private var previewURL: URL?
    @State private var showsFailure = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.secondary.opacity(0.12))
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "doc.text")
                            .font(.hiveSymbol(.body, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: 1) {
                    Text(filename)
                        .font(.hive(.subheadline, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let size = Self.formatByteCount(file.byteCount) {
                        Text(size)
                            .font(.hive(.caption))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(MessageMediaFrame.fill)
            .clipShape(MessageMediaFrame.shape)
            .overlay {
                MessageMediaFrame.shape.strokeBorder(MessageMediaFrame.border, lineWidth: 1)
            }
        }
        .buttonStyle(.hivePress(.control, in: MessageMediaFrame.shape))
        .disabled(isLoading)
        .frame(maxWidth: MessageMediaLayout.maximumWidth, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Opens a preview")
        .accessibilityAddTraits(.isButton)
        .accessibilityActions {
            Button("Preview file", action: open)
        }
        // Deliberately not a `.sheet`. Quick Look draws its close, search and share controls
        // only when it is *presented*; a sheet embeds it as a child, where it decides it is
        // not modal and renders the document bare. See ``FileQuickLookPresenter``.
        .background {
            FileQuickLookPresenter(url: $previewURL)
                .allowsHitTesting(false)
        }
        .alert("Couldn't Open File", isPresented: $showsFailure) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Hive couldn't download this attachment. Check your connection and try again.")
        }
    }
}

extension FileAttachmentCard {
    static func formatByteCount(_ byteCount: Int?) -> String? {
        guard var size = byteCount.map(Double.init), size >= 0 else { return nil }
        guard size >= 1024 else { return "\(Int(size)) B" }
        let units = ["KB", "MB", "GB", "TB"]
        var unit = 0
        size /= 1024
        while size >= 1024, unit < units.count - 1 {
            size /= 1024
            unit += 1
        }
        let number = size < 10
            ? size.formatted(.number.precision(.fractionLength(1)))
            : size.formatted(.number.precision(.fractionLength(0)))
        return "\(number) \(units[unit])"
    }

    private var filename: String {
        let name = file.filename?.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.flatMap { $0.isEmpty ? nil : $0 } ?? "File"
    }

    private var accessibilityLabel: String {
        [filename, Self.formatByteCount(file.byteCount)]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    private func open() {
        guard !isLoading else { return }
        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                let url = try await MessageMediaExport.fetch(
                    file,
                    session: MessageMediaExport.session,
                    authorization: environment?.mediaReadAuthorizer
                )
                guard !Task.isCancelled else { return }
                previewURL = url
            } catch {
                guard !Task.isCancelled else { return }
                showsFailure = true
            }
        }
    }
}
