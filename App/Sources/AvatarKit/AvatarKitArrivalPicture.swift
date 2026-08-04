import SwiftUI

/// The picture an arrival walk came out with, in the form the publisher takes it in.
///
/// # Why a recipe travels rather than a picture
///
/// ``JoinCommunityProfileStep`` runs before there is a committed key or a running engine, and
/// that is the reason it was emoji-only: an emoji avatar is a `data:` URI made of a glyph and a
/// colour (§ ``EmojiAvatar``), so it needs nothing, while a photo would have to be held
/// somewhere and uploaded after the join — a second failure path on a screen whose entire
/// content is optional.
///
/// A built avatar keeps the emoji's property for exactly as long as it stays a *recipe*:
/// ``AvatarKitAvatar`` is eight integers and a background, and it costs nothing to carry. It
/// stops being free at the moment something draws it. So the walk carries the recipe and
/// ``AppEnvironment/announceArrivalProfile(displayName:picture:)`` does the drawing, on the far
/// side of the join where an engine exists — which is the first moment there is anywhere to put
/// a picture at all. Nothing is uploaded from the step.
enum ArrivalPicture: Equatable, Sendable {
    /// An avatar the reader shuffled to, still unrendered.
    case built(AvatarKitAvatar)
    /// A glyph on a colour, which is what this step has always published.
    case emoji(String, color: String)
}

// MARK: - What the step is showing

/// The picture half of a profile step: which of the three answers the reader is on, and the
/// avatar the shuffle has landed on.
///
/// # Why the kind is stored rather than inferred
///
/// It used to be inferable, because there were two answers and one value: a glyph meant a
/// picture and no glyph meant none. With three, the two that matter most are indistinguishable
/// by their values — *no picture at all* and *an emoji not chosen yet* are both an absent
/// glyph, and at the end of the walk they mean opposite things.
///
/// # Why the avatar is rolled here rather than when the step appears
///
/// The step's whole claim is that a face is **already** there. A `.task` runs after the frame it
/// is attached to, so rolling there costs one frame of empty circle — on a step that is entered
/// by pressing Next, which is precisely when a frame of nothing gets seen. Rolling in the value
/// the step is handed means the first frame drawn is the finished one.
struct ArrivalPictureChoice: Equatable, Sendable {
    /// The three answers, in the order they are offered.
    enum Kind: String, CaseIterable, Identifiable, Sendable {
        /// A shuffled avatar — the default. See ``JoinCommunityProfileStep`` for why a rolled
        /// default is not the same proposition as a default glyph, which was refused.
        case built
        /// The glyph-and-colour avatar, unchanged from when it was the only answer here.
        case emoji
        /// No picture.
        ///
        /// Named for what it leaves rather than spelled `none`, which `Optional` already owns:
        /// `choice == .none` against an optional choice would compile and quietly mean the
        /// other thing.
        case nothing

        var id: String { rawValue }

        /// The word on the segment.
        ///
        /// `AvatarKit` rather than something softer, because it is the same word the account
        /// screen's editor puts on its own tab (``ProfileAvatarEditorModel/Tab``) — and the
        /// footnote under Shuffle sends the reader there. A step that promised `Avatar` and
        /// delivered them to a tab called something else would be sending them looking.
        var title: String {
            switch self {
            case .built: "AvatarKit"
            case .emoji: "Emoji"
            case .nothing: "None"
            }
        }
    }

    var kind: Kind = .built
    /// The avatar the Shuffle button rolls. Kept across a visit to another kind and back: a
    /// reader who looked at the emoji row has not thrown away the face they liked.
    var avatar: AvatarKitAvatar = .random()

    /// What this answer publishes as, or `nil` for no picture at all.
    ///
    /// The glyph and its colour stay outside this value rather than inside it, because they are
    /// two properties the walks have always held and the emoji path is deliberately untouched.
    func resolved(emoji: String?, color: String) -> ArrivalPicture? {
        switch kind {
        case .built: .built(avatar)
        // Still `nil` while no glyph has been chosen — an emoji avatar with no emoji is not an
        // answer, and never was.
        case .emoji: emoji.map { .emoji($0, color: color) }
        case .nothing: nil
        }
    }
}

// MARK: - The recap mark

/// The reader's answer at recap size.
///
/// Both walks draw one on their last step, under the community they are about to join. It is
/// here rather than in either of them so that the two cannot drift: the confirmation and the
/// step that asked have to agree about what was chosen, and they were two copies of the same
/// circle before there was anything to disagree about.
struct ArrivalPictureMark: View {
    let picture: ArrivalPicture?
    /// The diameter. 34pt is what both recap rows drew before there was a third answer.
    var size: CGFloat = 34

    var body: some View {
        switch picture {
        case let .built(avatar)?:
            AvatarKitCanvas(avatar: avatar, side: size)
                .clipShape(.circle)
                .overlay(hairline)
                // The canvas is a stack of `Image`s named after asset files, so combined into
                // the row above it VoiceOver would read the artwork's filenames out. One
                // element with one label instead.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("The avatar you built")
        case let .emoji(glyph, color)?:
            Circle()
                .fill(Color(avatarHex: color) ?? .white)
                .frame(width: size, height: size)
                // Half the circle, which is where the stored document puts the glyph.
                .overlay { Text(glyph).font(.hive(fixedSize: size * 0.5, relativeTo: .body)) }
                .overlay(hairline)
        case nil:
            EmptyView()
        }
    }

    /// The palette runs to white and the built grounds are all pale, either of which vanishes
    /// into the card behind them. A hairline is what keeps the circle a circle.
    private var hairline: some View {
        Circle().strokeBorder(.white.opacity(0.22), lineWidth: 1)
    }
}
