import SwiftUI

/// What the composer's `+` can attach.
///
/// A list rather than a switch, because the remaining entry is already known: the
/// mobile client's own menu is Camera, Photos, Video, Files, and this one is the
/// same menu without Video. Adding one is a case here and a branch in
/// ``ComposerAttachButton``'s handler — not a new surface.
enum ComposerAttachmentSource: String, CaseIterable, Identifiable {
    case photos
    case camera
    case files

    var id: String { rawValue }

    var title: String {
        switch self {
        case .photos: "Photos"
        case .camera: "Camera"
        case .files: "Files"
        }
    }

    /// SF Symbols rather than the mobile client's Lucide set — the rest of this app
    /// draws system symbols, and a second icon family in one bar would show.
    var systemImage: String {
        switch self {
        case .photos: "photo.on.rectangle"
        case .camera: "camera"
        // `doc` rather than `folder`: what is attached is a document, and the folder
        // is only the place it was found. It is also the glyph the file tile draws,
        // so the menu row and the thing it produces are the same picture.
        case .files: "doc"
        }
    }

    /// Whether choosing this does the thing it says. Kept with the source vocabulary so a
    /// future menu item cannot silently present a route that has not been built yet.
    var isBuilt: Bool {
        switch self {
        case .photos, .camera, .files: true
        }
    }
}

/// The little card above the composer's `+`.
///
/// Presented as a popover rather than a sheet — see the presentation in
/// ``MessageComposerView`` — so it sits over the conversation with an arrow at the
/// control that opened it, which is what the owner's reference shows and what
/// keeps the keyboard up underneath.
struct ComposerAttachmentMenu: View {
    let choose: (ComposerAttachmentSource) -> Void

    /// The card's width. 216 in the mobile client; the same here, because the
    /// widest label it will ever hold is a single short word and the card should
    /// not grow to the width of the screen for it.
    private static let width: CGFloat = 216
    /// A row's floor, above the 44pt touch minimum so the two rows do not read as
    /// a cramped list.
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 52
    /// The icon column, so the labels line up whatever glyph is beside them.
    @ScaledMetric(relativeTo: .body) private var iconColumn: CGFloat = 28

    var body: some View {
        VStack(spacing: 2) {
            ForEach(ComposerAttachmentSource.allCases) { source in
                // A row rather than a control: these are the rows of a list, and the card
                // is narrow enough that one shrinking away from both its edges would read
                // as lifting off the card rather than as being pressed. The wash is the
                // whole feedback here, which is what a system menu does with this gesture.
                Button { choose(source) } label: { row(for: source) }
                    .buttonStyle(.hivePress(.row))
            }
        }
        .padding(4)
        .frame(width: Self.width)
    }

    private func row(for source: ComposerAttachmentSource) -> some View {
        HStack(spacing: 8) {
            Image(systemName: source.systemImage)
                .font(.hiveSymbol(.body))
                .foregroundStyle(.secondary)
                .frame(width: iconColumn)
            Text(source.title)
                .font(.hive(.body))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(minHeight: rowHeight)
        .contentShape(.rect)
    }
}
