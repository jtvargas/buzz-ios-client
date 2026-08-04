// The avatar part artwork drawn here is DrawKit's "Notion Style Avatar Creator",
// https://www.drawkit.com/illustrations/notion-style-avatar-creator. It reaches the asset
// catalog through Tools/avatarkit-import.py, which names every layer in ``AvatarKitCatalog``.

import SwiftUI
import UIKit

/// The space the artwork was drawn in, and the one rule for placing a layer in it.
///
/// A plain `enum` rather than anything on the view, because the export reads the same
/// numbers from off the main actor and a constant that lives on a `View` is `@MainActor` by
/// inheritance — which would make "how wide is a layer" a question only the UI can answer.
enum AvatarKitGeometry {
    /// Every layer is drawn 306 units wide, and the composition is square at 306.
    ///
    /// Outfits are the exception that proves it: they are 306 wide and *taller* — up to 399
    /// — and the overflow past the bottom edge is deliberate, because the garment continues
    /// past the frame rather than stopping at it. Anything that fitted an outfit into the
    /// square would shrink the person wearing it.
    static let designSide: CGFloat = 306

    /// How tall `name` is in design units.
    ///
    /// Taken from the asset's own aspect ratio rather than from a table, so a re-import at a
    /// different absolute scale needs no edit here, and so a layer this file has never heard
    /// of still lands correctly. A missing asset answers with the square, which draws
    /// nothing and shifts nothing.
    static func layerHeight(_ name: String) -> CGFloat {
        guard let size = UIImage(named: name)?.size, size.width > 0, size.height > 0 else {
            return designSide
        }
        return designSide * size.height / size.width
    }
}

/// Draws one ``AvatarKitAvatar`` into a square of a requested side.
///
/// No state, no environment, no work that outlives a frame — which is what lets the same
/// view be the 132pt preview, the thumbnail behind a swatch, and the 512pt bitmap that gets
/// uploaded. Everything it needs is in the value it was handed.
///
/// # Why the stack is top-leading
///
/// Every layer shares one origin. The eyes are at their coordinates in the 306 space and
/// nowhere else, and the only thing that puts them on the face is that the head was drawn at
/// the same origin. `.center` would re-centre each layer inside its own box, which for the
/// taller outfits means sliding the garment up by half its overflow — and the person ends up
/// wearing their collar as a hat.
struct AvatarKitCanvas: View {
    let avatar: AvatarKitAvatar
    /// The side of the square to draw into, in points.
    let side: CGFloat

    var body: some View {
        let scale = side / AvatarKitGeometry.designSide
        ZStack(alignment: .topLeading) {
            ground
            ForEach(avatar.layers, id: \.self) { name in
                Image(name)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .frame(
                        width: AvatarKitGeometry.designSide * scale,
                        height: AvatarKitGeometry.layerHeight(name) * scale
                    )
            }
        }
        .frame(width: side, height: side, alignment: .topLeading)
        // The outfit runs past the bottom edge by design; this is the frame it runs past.
        .clipped()
    }

    @ViewBuilder
    private var ground: some View {
        if let hex = avatar.background.hex, let color = Color(avatarHex: hex) {
            color
        } else {
            Color.clear
        }
    }
}

/// The editor's headline: the avatar being built, drawn as the circle every other surface in
/// the app will draw it as.
///
/// Round rather than a rounded rectangle, and that is not a style choice —
/// ``AccountView`` shows this picture at 112pt in a circle, and a preview that promised a
/// square would be lying about the corners it is going to lose.
struct AvatarKitAvatarPreview: View {
    let avatar: AvatarKitAvatar
    let side: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Whether the pop is at its top. Kept here rather than derived, because the animation
    /// is two moves and only the first of them is triggered by the change.
    @State private var isPopped = false

    var body: some View {
        AvatarKitCanvas(avatar: avatar, side: side)
            .clipShape(.circle)
            // The palette runs to white and the transparent ground to nothing, either of
            // which vanishes into a sheet's own background. The hairline is what keeps the
            // circle a circle at both ends of it — the emoji preview's rule, for the same
            // reason.
            .overlay(Circle().strokeBorder(.separator, lineWidth: 1))
            .scaleEffect(isPopped ? Self.popScale : 1)
            .onChange(of: avatar) { _, _ in pop() }
    }

    /// How far the preview swells on a change. Small enough to read as the picture answering
    /// rather than as the picture moving: the shuffle is going to be pressed many times in a
    /// row, and anything larger becomes a bounce the reader is waiting out.
    private static let popScale: CGFloat = 1.045

    private func pop() {
        guard !reduceMotion else { return }
        withAnimation(.spring(response: 0.16, dampingFraction: 0.6)) { isPopped = true }
        withAnimation(.spring(response: 0.26, dampingFraction: 0.8).delay(0.08)) { isPopped = false }
    }
}
