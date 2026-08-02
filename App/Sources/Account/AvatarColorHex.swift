import SwiftUI
import UIKit

/// The conversion between the `#RRGGBB` strings an emoji avatar is stored with and the
/// `Color` a swatch is drawn in.
///
/// Kept apart from ``EmojiAvatar`` because that type is deliberately Foundation-only: the
/// document it writes is text, and the colour inside it is round-tripped verbatim rather
/// than parsed. This is the view layer's side of the same value.
extension Color {
    /// The colour a `#RRGGBB` (or `#RGB`) string names, or `nil` when it names none.
    ///
    /// Only the hex forms are understood, because those are the only forms this app
    /// *writes*. A profile edited by some other client could hold `red` or `rgb(…)`; that
    /// is not a failure to show a swatch for, it is an avatar whose colour the editor
    /// leaves alone.
    init?(avatarHex hex: String) {
        var digits = Substring(hex)
        guard digits.first == "#" else { return nil }
        digits = digits.dropFirst()

        // `#RGB` is the shorthand where each digit is doubled — accepted on the way in
        // because CSS writes it, never produced on the way out.
        if digits.count == 3 {
            digits = Substring(digits.flatMap { [$0, $0] })
        }
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }

        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    /// This colour as an uppercase `#RRGGBB` string.
    ///
    /// Resolved through `UIColor` in the extended sRGB space, then clamped: the system
    /// colour well can return a wide-gamut colour whose components fall outside 0…1, and
    /// `#FF00FF` is the nearest thing an SVG `fill` can say about one. Alpha is dropped
    /// because the document has nowhere to put it — an avatar background is opaque.
    var avatarHex: String {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        UIColor(self).getRed(&red, green: &green, blue: &blue, alpha: &alpha)

        func channel(_ value: CGFloat) -> Int {
            Int((min(max(value, 0), 1) * 255).rounded())
        }
        return String(format: "#%02X%02X%02X", channel(red), channel(green), channel(blue))
    }
}
