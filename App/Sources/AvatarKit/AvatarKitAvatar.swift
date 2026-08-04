import Foundation

/// One built avatar: which option each layer is showing, as an index into the
/// ``AvatarKitCatalog`` array for that layer.
///
/// # Why indices rather than asset names
///
/// A name is the thing that changes when the artwork is re-imported; a position is what a
/// picker actually holds. The strip scrolls positions, the shuffle rolls positions, and both
/// stay correct when a category grows, because nothing here is told how many options there
/// are. Resolution to a name happens once, in ``layers``, which is therefore the only place
/// that can be out of range — and so the only place that has to be careful about it.
///
/// # Why three layers are optional
///
/// Hair, facial hair and an accessory are each *absent* on plenty of faces. Modelling
/// "bald", "clean-shaven" and "no accessory" as an empty asset rolled like any other option
/// would put a drawing step in the path of not drawing. Here absence is `nil`, so the layer
/// simply is not in ``layers``.
struct AvatarKitAvatar: Codable, Equatable, Sendable {
    var outfit: Int
    var head: Int
    var hair: Int?
    var eyes: Int
    var mouth: Int
    var facialHair: Int?
    var accessory: Int?
    var background: AvatarKitBackground
}

// MARK: - Layers

extension AvatarKitAvatar {
    /// The asset names to paint, bottom to top.
    ///
    /// The order is the artwork's own paint order, and two of its steps are not the ones a
    /// reading of the list would guess: the **outfit paints under the head**, so a collar
    /// tucks behind the chin instead of across it, and **hair paints over the head**, so a
    /// fringe falls on the forehead. Swap either and the result reads as a costume rather
    /// than a person.
    ///
    /// An index that no longer names anything is dropped rather than substituted. A saved
    /// recipe outliving the artwork it named should cost the reader one layer, not a
    /// different avatar than the one they built.
    var layers: [String] {
        [
            AvatarKitCatalog.body,
            AvatarKitCatalog.outfits[safe: outfit],
            AvatarKitCatalog.heads[safe: head],
            hair.flatMap { AvatarKitCatalog.hairs[safe: $0] },
            AvatarKitCatalog.eyes[safe: eyes],
            AvatarKitCatalog.mouths[safe: mouth],
            facialHair.flatMap { AvatarKitCatalog.facialHair[safe: $0] },
            accessory.flatMap { AvatarKitCatalog.accessories[safe: $0] },
        ].compactMap(\.self)
    }
}

// MARK: - Rolling one

extension AvatarKitAvatar {
    /// How often a roll of an optional layer comes back empty.
    ///
    /// Treating "none" as one option among that category's own would mean that with nine
    /// beards a rolled avatar is bearded nine times in ten, and with ten accessories it is
    /// wearing something nine times in ten. Twenty shuffles of that read as a dressing-up
    /// box rather than as twenty people, which is the opposite of what a shuffle is for.
    ///
    /// So two of the three are weighted, and the third is not:
    ///
    /// - **Hair** is left as one option among the rest, `1 / (count + 1)`. Bald is genuinely
    ///   uncommon, and one in thirty-three is what that looks like.
    /// - **Facial hair** is a coin toss, because roughly half of faces have none.
    /// - **An accessory** lands about a third of the time absent, which leaves glasses and
    ///   hats frequent enough to be a surprise and rare enough to still be one.
    ///
    /// This costs under a bit out of the twenty-five the whole combination carries — the
    /// entropy lives in hair × eyes × mouth × head × outfit, which is four million on its
    /// own — so the shuffle is no less varied for it, only less costumed.
    private enum NoneShare {
        static let facialHair = 0.5
        static let accessory = 0.35
    }

    /// How many times a shuffle will re-roll rather than hand back what it replaced.
    ///
    /// The space is tens of millions, so a repeat is a lottery win and one re-roll settles
    /// it. The bound is here for the degenerate catalogue — one option per category — where
    /// every roll is the same avatar and an unbounded loop would spin forever rather than
    /// admit there is nothing else to show.
    private static let rerollLimit = 8

    /// A fresh avatar with every layer rolled independently and uniformly.
    ///
    /// The background is rolled out of ``AvatarKitBackground/opaque`` rather than out of
    /// every case: see that property for why the transparent one is not in a shuffle.
    static func random(using generator: inout some RandomNumberGenerator) -> Self {
        Self(
            outfit: index(in: AvatarKitCatalog.outfits.count, using: &generator),
            head: index(in: AvatarKitCatalog.heads.count, using: &generator),
            hair: index(
                in: AvatarKitCatalog.hairs.count,
                noneShare: 1 / Double(AvatarKitCatalog.hairs.count + 1),
                using: &generator
            ),
            eyes: index(in: AvatarKitCatalog.eyes.count, using: &generator),
            mouth: index(in: AvatarKitCatalog.mouths.count, using: &generator),
            facialHair: index(
                in: AvatarKitCatalog.facialHair.count,
                noneShare: NoneShare.facialHair,
                using: &generator
            ),
            accessory: index(
                in: AvatarKitCatalog.accessories.count,
                noneShare: NoneShare.accessory,
                using: &generator
            ),
            background: AvatarKitBackground.opaque.randomElement(using: &generator) ?? .white
        )
    }

    /// A fresh avatar, from the system's own randomness.
    static func random() -> Self {
        var generator = SystemRandomNumberGenerator()
        return random(using: &generator)
    }

    /// A fresh avatar that is not this one.
    ///
    /// The guarantee is what makes the button feel like a button: a shuffle that hands back
    /// what was already on screen is indistinguishable from a tap that did not register, and
    /// a reader's next move after one of those is to tap harder rather than to look.
    func shuffled(using generator: inout some RandomNumberGenerator) -> Self {
        var next = Self.random(using: &generator)
        var attempts = 0
        while next == self, attempts < Self.rerollLimit {
            next = Self.random(using: &generator)
            attempts += 1
        }
        return next
    }

    /// A fresh avatar that is not this one, from the system's own randomness.
    func shuffled() -> Self {
        var generator = SystemRandomNumberGenerator()
        return shuffled(using: &generator)
    }

    /// A position in a category of `count` options. Zero for an empty category, which
    /// ``layers`` then drops — an avatar missing a layer, rather than a crash.
    private static func index(
        in count: Int,
        using generator: inout some RandomNumberGenerator
    ) -> Int {
        count > 0 ? Int.random(in: 0 ..< count, using: &generator) : 0
    }

    /// The same for a category that can be absent, where `noneShare` is the probability of
    /// coming back empty.
    private static func index(
        in count: Int,
        noneShare: Double,
        using generator: inout some RandomNumberGenerator
    ) -> Int? {
        guard count > 0 else { return nil }
        guard Double.random(in: 0 ..< 1, using: &generator) >= noneShare else { return nil }
        return Int.random(in: 0 ..< count, using: &generator)
    }
}

// MARK: - Backgrounds

/// The nine grounds, in the order the swatch row offers them.
///
/// Tailwind's 300-weight ramp, resolved to hex once rather than approximated: these are the
/// colours the artwork was drawn against, and the line art is black, so a ground any darker
/// than this ramp stops being a background and starts competing with the drawing.
enum AvatarKitBackground: Int, CaseIterable, Codable, Sendable {
    case transparent
    case white
    case red
    case yellow
    case green
    case blue
    case indigo
    case purple
    case pink

    /// The `#RRGGBB` this ground fills with, or `nil` for the transparent one.
    var hex: String? {
        switch self {
        case .transparent: nil
        case .white: "#FFFFFF"
        case .red: "#FCA5A5"
        case .yellow: "#FDE047"
        case .green: "#86EFAC"
        case .blue: "#93C5FD"
        case .indigo: "#A5B4FC"
        case .purple: "#D8B4FE"
        case .pink: "#F9A8D4"
        }
    }

    var title: String {
        switch self {
        case .transparent: "No background"
        case .white: "White"
        case .red: "Red"
        case .yellow: "Yellow"
        case .green: "Green"
        case .blue: "Blue"
        case .indigo: "Indigo"
        case .purple: "Purple"
        case .pink: "Pink"
        }
    }

    /// Everything a shuffle will land on.
    ///
    /// Rolling the transparent ground like any other would be harmless on a page that is
    /// always white. Here the avatar is published, and every surface that
    /// draws it afterwards supplies its own ground: a transparent avatar is a head floating
    /// on a sheet in light mode and a head floating on ink in dark. One shuffle in nine
    /// producing that would read as a bug rather than as a choice, so it is a choice —
    /// reachable from the swatch row, never from the button.
    static let opaque = allCases.filter { $0 != .transparent }
}

private extension Array {
    /// The element at `index`, or `nil` past the end. Used by ``AvatarKitAvatar/layers``,
    /// where a saved recipe can name a position the artwork no longer has.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
