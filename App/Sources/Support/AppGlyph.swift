import SwiftUI

/// Where a drawn glyph comes from: the system's library, or the app's own.
///
/// # Why this is a type and not a `String`
///
/// Because the two kinds are asked for by different calls — `Image(systemName:)` and
/// `Image(_:)` — and each one draws **nothing at all** when handed the other's name. No
/// warning, no placeholder, no missing-symbol box: the control keeps its size and its hit
/// area and simply has no picture in it. A `String` cannot say which kind it is, so the
/// mistake is invisible until somebody looks at the screen.
///
/// Shared by the tabs and the home shortcuts rather than written twice, because both now mix
/// system symbols with the owner's own artwork, and the rule about which is which is the same
/// rule in both places.
enum AppGlyph: Equatable {
    /// A name in the system symbol library.
    case symbol(String)
    /// A template image in the app's own asset catalogue. Template, always: it is what lets
    /// the drawing take the tint of whatever is drawing it, exactly as a symbol does.
    case asset(String)
}

extension AppGlyph {
    /// The drawing itself, asked for the right way round.
    ///
    /// Plain: a caller that needs it sized — a card, a toolbar control — adds `resizable()`
    /// and a frame, because an asset takes its size from a frame and a symbol takes its from
    /// a font, and no one modifier serves both. This is the part that is always the same.
    var image: Image {
        switch self {
        case let .symbol(name): Image(systemName: name)
        case let .asset(name): Image(name)
        }
    }
}
