import CoreGraphics

/// A layer a reader can browse, in the order the chips offer them.
///
/// Face first because it is the one every other choice sits on, then the choices that change
/// a face most, then what the person is wearing, then the ground behind them. The background
/// is in this list rather than beside it so the row is one control: a chip that behaves
/// differently from the chip next to it is a second control wearing the first one's clothes.
enum AvatarKitPart: CaseIterable, Identifiable, Hashable {
    case head
    case hair
    case eyes
    case mouth
    case facialHair
    case accessory
    case outfit
    case background

    var id: Self { self }

    var title: String {
        switch self {
        case .head: "Face"
        case .hair: "Hair"
        case .eyes: "Eyes"
        case .mouth: "Mouth"
        case .facialHair: "Beard"
        case .accessory: "Extras"
        case .outfit: "Outfit"
        case .background: "Colour"
        }
    }

    /// The artwork this part offers. Empty for ``background``, which is a colour and has no
    /// asset — the strip draws swatches for it rather than thumbnails.
    var options: [String] {
        switch self {
        case .head: AvatarKitCatalog.heads
        case .hair: AvatarKitCatalog.hairs
        case .eyes: AvatarKitCatalog.eyes
        case .mouth: AvatarKitCatalog.mouths
        case .facialHair: AvatarKitCatalog.facialHair
        case .accessory: AvatarKitCatalog.accessories
        case .outfit: AvatarKitCatalog.outfits
        case .background: []
        }
    }

    /// Whether "none" is one of the answers, and so whether the strip opens with a cell that
    /// takes the layer away.
    var allowsNone: Bool {
        switch self {
        case .hair, .facialHair, .accessory: true
        case .head, .eyes, .mouth, .outfit, .background: false
        }
    }

    /// The window of the 306-unit design space a thumbnail shows.
    ///
    /// # Why a thumbnail is not the whole square
    ///
    /// Every layer occupies its own small region of a shared 306 space — a mouth lives in
    /// about 36 by 26 units of it — so a grid of whole squares would be a page of specks with
    /// nothing to tell apart. Cropping is the way out: draw the part at full size and let a
    /// small box clip it, which is a centre crop by another name. These are that crop, per
    /// part, measured from the artwork rather than guessed. The face is a three-quarter view,
    /// which is why the eye and mouth windows sit right of the head's centre rather than on it.
    ///
    /// # Why they are wider than the part they are named for
    ///
    /// They were once exactly the union of every option's own bounds, because a cell drew that
    /// part *alone* and there was nothing else in the picture to give it room. A cell now draws
    /// the whole avatar with one layer swapped, and the window's job changed with it: it has to
    /// hold enough of the neighbouring artwork to make the swap legible. A mouth alone is a
    /// shape; a mouth with the nose above it and the chin below is an expression, and the
    /// expression is what is being chosen. So the three tight ones — eyes, mouth, beard — are
    /// opened out by about a third, and then **re-centred on where the part actually lands in a
    /// composite**, which is not where the union of its own artwork put it. Squaring a wide,
    /// short union about its own centre leaves the part sitting high and left in the tile with a
    /// wedge of background beside it; these three origins were nudged off a photograph of the
    /// grid until the part was in the middle of its own cell. The four that already carried
    /// their context are unchanged.
    ///
    /// The accessories are the one place the union is *not* the window. Eight of the ten sit on
    /// the face, and the two that do not — a cap above it and a bow tie at the collar — drag
    /// the union out to 280 units, at which size a pair of glasses is a smudge. So the window is
    /// drawn around the eight and lets the other two lose an edge, which is the trade that
    /// leaves every cell readable rather than one of them complete.
    ///
    /// The outfit is the other exception, and it moved. It used to be a 309-unit window
    /// starting below the chin, so the garment could be judged whole — including the part of it
    /// that runs past 306 and off the bottom of the avatar. But a composite is the avatar, and
    /// the avatar clips there: a cell showing a hem nobody will ever see is a cell promising a
    /// picture the app does not draw. So it is the whole square, which is also where the collar
    /// and the shoulders are, and those are what separate twenty-five garments from each other.
    ///
    /// The face is the hardest of the eight and its window is cut to suit. The eight heads differ
    /// in the **ear and the jaw** and in nothing else, and photographed at the head's full union
    /// the eight cells were indistinguishable — the top third of every one of them was the same
    /// hair, drawn at the same size. So this window starts below the crown: it drops what every
    /// option shares and spends the tile on the two places they do not.
    var window: CGRect {
        switch self {
        case .head: CGRect(x: 58, y: 88, width: 192, height: 192)
        case .hair: CGRect(x: 3, y: 7, width: 287, height: 287)
        case .eyes: CGRect(x: 102, y: 66, width: 140, height: 140)
        case .mouth: CGRect(x: 120, y: 127, width: 104, height: 104)
        case .facialHair: CGRect(x: 100, y: 115, width: 136, height: 136)
        case .accessory: CGRect(x: 73, y: 77, width: 190, height: 190)
        case .outfit: CGRect(x: 0, y: 0, width: 306, height: 306)
        case .background: CGRect(x: 0, y: 0, width: 306, height: 306)
        }
    }

    /// Which option `avatar` is showing for this part.
    func selection(in avatar: AvatarKitAvatar) -> Int? {
        switch self {
        case .head: avatar.head
        case .hair: avatar.hair
        case .eyes: avatar.eyes
        case .mouth: avatar.mouth
        case .facialHair: avatar.facialHair
        case .accessory: avatar.accessory
        case .outfit: avatar.outfit
        case .background: avatar.background.rawValue
        }
    }

    /// Points this part at `index`, leaving every other layer alone.
    ///
    /// A `nil` for a part that cannot be absent is ignored rather than clamped: the strip
    /// never offers one, so reaching here with one is a caller's bug and quietly picking the
    /// first option would hide it. Split in two so the absence is handled once, at the top,
    /// rather than once per layer that cannot have it.
    func apply(_ index: Int?, to avatar: inout AvatarKitAvatar) {
        switch self {
        case .hair: avatar.hair = index
        case .facialHair: avatar.facialHair = index
        case .accessory: avatar.accessory = index
        case .background:
            if let ground = index.flatMap(AvatarKitBackground.init(rawValue:)) {
                avatar.background = ground
            }
        case .head, .eyes, .mouth, .outfit:
            guard let index else { return }
            applyRequired(index, to: &avatar)
        }
    }

    /// The layers that are always present. Listed exhaustively rather than with a `default`,
    /// so a ninth layer is a compile error here instead of a silent no-op.
    private func applyRequired(_ index: Int, to avatar: inout AvatarKitAvatar) {
        switch self {
        case .head: avatar.head = index
        case .eyes: avatar.eyes = index
        case .mouth: avatar.mouth = index
        case .outfit: avatar.outfit = index
        case .hair, .facialHair, .accessory, .background: break
        }
    }
}
