import Foundation
import SwiftUI

/// The conversation's heading, as the navigation bar's own leading item: a mark — a `#`,
/// a thread glyph, or the peer's own face — the name in bold, and one quiet line under it.
///
/// # Why the system bar draws this and the app does not
///
/// The heading has been in three places. It began as a `ToolbarItem` that came out "a little
/// bubble", which was read as a 44pt navigation bar compressing a two-line item; it moved to
/// its own row under an empty system bar, which cost a second band of chrome; and then to a
/// row of capsules the app drew itself with the system bar hidden, which cost the real back
/// button and the interactive drag-back with it.
///
/// The diagnosis behind all three was wrong. A leading toolbar item holds two lines at the
/// default text size perfectly well — what did not fit was the *old* pill, which carried its
/// own `glassEffect` capsule and 6pt of vertical padding inside the item, so it asked the bar
/// for ~46pt where its text needed ~34pt. Handing the capsule back to the bar — a plain
/// `Button` label, glass drawn by iOS 26 — fits, and everything the hand-drawn row had to
/// reproduce (the back button, the material, the metrics, capping type growth in the bar)
/// comes from the system for free and cannot drift out of proportion with itself.
///
/// # Two things the bar does that have to be defended against
///
/// **A toolbar item that does not fit is not truncated — it is moved into the `…` overflow
/// menu**, so the entire heading disappears rather than the name shortening. A long channel
/// name does exactly that. The defence is to bound the text column so the item's *ideal*
/// width stays inside what the bar has: ``labelWidth(forSurfaceWidth:mark:)``. Measured on
/// the iOS 26 simulator with a 66-character channel name, the item survives up to about a
/// 245pt column on a 402pt-wide iPhone 17 Pro (250 collapses, 240 does not) and past 220 on a
/// 375pt iPhone SE — the reserve is ~155pt and does not scale with the screen, because it is
/// the back button, the bar's margins, the mark, and the capsule's own padding. So the bound
/// is the surface's width less ``reservedChrome(for:)``, verified at 375pt, 402pt, and 440pt
/// and at the largest accessibility size by screenshot rather than by arithmetic.
///
/// **A bare label in a toolbar item is squeezed to its minimum where a `Button`'s label is
/// sized to its ideal.** A thread's heading had no action and came out as `Th…` over
/// `#gen…`, jammed against the glass on all four sides beside a full-width back button. That
/// is why ``action`` is not optional: every heading is a control, so every heading is given
/// the room the bar gives a control. The alternative — `fixedSize` on a bare label — restores
/// the width but not the capsule's horizontal padding, which is the part that reads as tight.
struct ConversationTitleBar: ViewModifier {
    /// The mark before the name: what this conversation *is*, in one glyph or one face.
    ///
    /// An enum rather than an optional symbol name because the four cases are not variations
    /// on one drawing — a face is a different width, a different shape, and a different
    /// reserve against the overflow rule than a glyph is.
    enum Mark: Equatable {
        /// No mark; the name stands on its own.
        case none
        /// One glyph — `number` for a channel, the app's own drawing for a thread.
        ///
        /// `accented` spends the app's colour on the glyph, and is off everywhere but the
        /// workspace's own heading: the accent marks the one heading that names *this app's*
        /// community, where a `#` or a thread glyph names a conversation inside it. A colour
        /// that appeared on every heading would say nothing about any of them.
        case glyph(AppGlyph, accented: Bool = false)

        /// A system symbol, spelled the short way. Most marks are one, and
        /// `.glyph(.symbol("number"))` says the word twice.
        static func symbol(_ name: String, accented: Bool = false) -> Mark {
            .glyph(.symbol(name), accented: accented)
        }
        /// The peer's picture, falling back to their monogram. A person is recognised by
        /// their face before their name, which a glyph cannot do.
        case avatar(url: URL?, seed: String, initials: String)
        /// The active community's persisted mark. Unlike a remote avatar, its bytes are
        /// already on this device and can be drawn in the first header frame.
        case community(name: String, iconData: Data?)
        /// How many people are in a group direct message. Drawn where a face would be, and
        /// costed as a glyph: it is a digit or two, not a 26-point picture.
        case count(Int)
    }

    /// The line beneath the name, and whether it carries a presence dot.
    ///
    /// A type rather than a `String` because a DM's second line is not a sentence about a
    /// person — it is their presence, and presence is a colour before it is a word.
    struct Subtitle: Equatable {
        let text: String
        /// `nil` for a line that says nothing about a person's presence.
        let presence: Bool?

        /// A plain line — a channel's member counts, or a thread's parent conversation.
        static func text(_ text: String) -> Subtitle {
            Subtitle(text: text, presence: nil)
        }

        /// A peer's presence: a green or grey dot, and the word beside it. The same two
        /// words the profile sheet uses, so the header and the sheet cannot disagree about
        /// the same person.
        static func presence(_ isOnline: Bool) -> Subtitle {
            Subtitle(text: isOnline ? "Online" : "Offline", presence: isOnline)
        }
    }

    /// What this conversation is, before its name. See ``Mark``.
    var mark: Mark = .none
    /// The conversation's name — a channel's, a DM peer's, or the literal `Thread`.
    let title: String
    /// The line beneath it, absent when there is nothing true to put there.
    var subtitle: Subtitle?
    /// What tapping the heading does. Not optional — see the type comment.
    let action: () -> Void
    /// What VoiceOver says the tap does.
    var actionHint: String?
    /// Whether the heading is a label rather than a control.
    ///
    /// A `Button` either way — the sizing this whole file is about belongs to the button,
    /// not to the action — but hit testing is off, so it neither highlights nor pretends to
    /// lead somewhere. The one heading that has nowhere to go is the Activity tab's, which
    /// names a screen instead of a conversation.
    var isInert = false
    /// What the trailing `⋮` does, or `nil` for a surface with nothing to manage — a
    /// thread, the Activity tab, the sidebar.
    ///
    /// It leads to the same sheet the heading does. Two doors to one room, on purpose: a
    /// heading you have to already know is tappable is not an affordance, and a second
    /// sheet holding the same channel's topic in slightly different words is how a UI
    /// starts contradicting itself.
    var manageAction: (() -> Void)?
    /// What the trailing `person.3.fill` does, or `nil` for a surface with nobody to list.
    ///
    /// Absent on a one-to-one direct message on purpose: the heading there is already the
    /// person and their presence dot, so a button offering to list the two of you is a
    /// control that can only tell you what you are looking at.
    var peopleAction: (() -> Void)?
    /// How visible the heading is, for a surface that is being covered by something else.
    ///
    /// One `Double` rather than a `Bool`, because the only caller that spends it is the
    /// sidebar's communities panel, and there the heading has to leave *at the speed of the
    /// finger* — a heading that vanished the moment a drag began would be the jump the owner
    /// asked me to remove. Defaults to fully visible, which is every other surface.
    var opacity: Double = 1

    /// The bound on the text column, kept in step with the surface's width so the pill can
    /// be as wide as the bar allows in landscape without risking the overflow menu in
    /// portrait. Seeded at the floor rather than left unbounded: an unbounded first frame is
    /// the one case that *would* collapse into the `…` menu, and a heading that flashes away
    /// and comes back is worse than one that starts narrow and grows.
    @State private var labelWidth: CGFloat = ConversationTitleBar.minimumLabelWidth

    /// The face's point size. Fixed rather than `@ScaledMetric`: the bar caps its own type
    /// growth, so an avatar that kept growing would be the one thing left in the item still
    /// pushing it towards the overflow menu at an accessibility size.
    ///
    /// The rest of the metrics — the reserve, the floor, what a trailing button costs — live
    /// in `ConversationTitleBarMetrics.swift`, because they are arithmetic with its own tests
    /// rather than anything this view draws. This one stays because ``markView`` draws with it.
    static let avatarSize: CGFloat = 26

    /// How many controls sit at the trailing edge. Derived rather than passed, so a caller
    /// cannot hand the heading a width budget that disagrees with what it is drawing.
    private var trailingActionCount: Int {
        (peopleAction == nil ? 0 : 1) + (manageAction == nil ? 0 : 1)
    }

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                labelWidth = Self.labelWidth(
                    forSurfaceWidth: width,
                    mark: mark,
                    trailingActions: trailingActionCount
                )
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: action) { label }
                        // Faded out rather than removed: a toolbar item that leaves the
                        // hierarchy takes the bar's layout with it, and the neighbours slide.
                        .opacity(opacity)
                        .allowsHitTesting(!isInert && opacity > 0.5)
                        .accessibilityHidden(opacity < 0.5)
                        .accessibilityLabel(accessibilityLabel)
                        .accessibilityHint(actionHint ?? "")
                }
                // The glass capsule behind the heading is the bar's, not the button's, so
                // `.opacity` on the label never touched it — it stayed as an empty grey pill
                // sitting on top of the panel. This is the only control over it, and it is a
                // `Visibility` rather than a number: the shape goes the moment the heading
                // starts to leave, while the heading itself still fades with the finger.
                .sharedBackgroundVisibility(opacity < 1 ? .hidden : .automatic)
                // Keeps the heading a capsule of its own at the leading edge rather than
                // letting the bar centre or stretch it, and is the seam anything added at
                // the trailing edge later would sit the other side of.
                ToolbarSpacer(.flexible, placement: .topBarLeading)

                if let peopleAction {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: peopleAction) { peopleGlyph }
                            .accessibilityLabel("People")
                            .accessibilityHint("Double tap to see who is in this conversation")
                    }
                }

                // What makes the two trailing buttons two capsules instead of one. iOS 26
                // groups adjacent items in a placement into a single piece of glass, which
                // would read as one segmented control offering two unrelated things: who is
                // here, and what this channel is. The spacer is the seam between them.
                if peopleAction != nil, manageAction != nil {
                    ToolbarSpacer(.fixed, placement: .topBarTrailing)
                }

                if let manageAction {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: manageAction) { manageGlyph }
                            .accessibilityLabel("Manage channel")
                            .accessibilityHint("Double tap to mute, read the channel’s context, or edit its canvas")
                    }
                }
            }
    }

    /// The `person.3.fill`. Filled rather than outlined so it carries the same weight as
    /// the `⋮` beside it — an outlined glyph next to a solid one reads as the disabled one
    /// of the pair.
    private var peopleGlyph: some View {
        Image(systemName: "person.3.fill")
            .font(.hiveSymbol(.footnote, weight: .semibold))
            // Named rather than hierarchical, for the reason given above ``label``: inside a
            // `Button` a hierarchical style resolves against the control's *tint* and comes
            // back amber, which is the thing this is here to avoid. The owner asked for these
            // two at full strength — off the accent, but not dimmed either: they are the
            // bar's actions, and a greyed action reads as one that cannot be taken.
            .foregroundStyle(Color.primary)
            .accessibilityHidden(true)
    }

    /// The `⋮`. Rotated rather than named: SF Symbols ships `ellipsis` horizontal and has
    /// no plain vertical counterpart (`ellipsis.vertical.bubble` is a speech bubble), so a
    /// quarter turn is the whole of it. Hidden from VoiceOver — the button above carries
    /// the label, and a rotated glyph would otherwise be read as "ellipsis".
    private var manageGlyph: some View {
        Image(systemName: "ellipsis")
            .font(.hiveSymbol(.body, weight: .semibold))
            .rotationEffect(.degrees(90))
            // See ``peopleGlyph``: named, at full strength, and deliberately not the accent.
            .foregroundStyle(Color.primary)
            .accessibilityHidden(true)
    }

    /// Deliberately without a `glassEffect` or vertical padding of its own: both belong to
    /// the bar in iOS 26, and adding them here is what made this item too tall to fit the
    /// first time. See the type comment.
    private var label: some View {
        HStack(spacing: Self.markGap) {
            markView
            VStack(alignment: .leading, spacing: Self.betweenLines) {
                Text(title)
                    .font(.hive(.subheadline, weight: .bold))
                    // `Color.primary`, not the hierarchical `.primary`. The heading is a
                    // `Button`, and a hierarchical style inside a control resolves against
                    // the control's *tint* — so the moment the app was given its accent
                    // every heading in the app turned amber, name and glyph together.
                    // `Color.primary` is the label colour itself and does not follow a tint.
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let subtitle {
                    subtitleView(subtitle)
                }
            }
            // The bound the whole file exists for. `alignment: .leading` so a short name
            // keeps a short capsule instead of sitting in the middle of a wide one — the
            // frame caps the column, it does not claim it.
            .frame(maxWidth: labelWidth, alignment: .leading)
        }
        // See ``verticalNudge``. An offset rather than padding, because padding here does
        // nothing at all.
        .offset(y: -Self.verticalNudge)
    }

    @ViewBuilder
    private var markView: some View {
        switch mark {
        case .none:
            EmptyView()
        case let .glyph(glyph, accented):
            // A step above the name rather than two: at `.title3` the `#` was the loudest
            // thing in the bar and hung below the second line's baseline, which is most of
            // what read as the heading being crammed. `.body` semibold is 17 points, said
            // here as a number because artwork cannot be sized by a font — see ``GlyphView``.
            GlyphView(glyph, height: 17)
                // Named colours rather than hierarchical ones, for the reason above the
                // name: inside a control the hierarchy resolves against the tint. The accent
                // is therefore asked for by name where it is wanted, and refused everywhere
                // else — which is the only way a glyph can be *the* accented one.
                //
                // The unaccented mark is `Color.primary`, the name's own colour, and not
                // `.secondary`: this is the heading's icon, not a note about the heading.
                // Drawn secondary it came out pixel-identical to the subtitle underneath it,
                // so the pill read as one bold word with two grey things attached rather than
                // as an icon and a name. The accented mark is still the odd one out — amber
                // against white reads as clearly as amber against grey did.
                .foregroundStyle(accented ? Color.hiveAccent : Color.primary)
                .accessibilityHidden(true)
        case let .avatar(url, seed, initials):
            AvatarView(url: url, seed: seed, monogram: initials, size: Self.avatarSize)
        case let .community(name, iconData):
            CommunityMark(name: name, iconData: iconData, size: Self.avatarSize)
        case let .count(count):
            Text(ConversationMark.countText(count))
                .font(.hive(.body, weight: .bold))
                .monospacedDigit()
                // Named, for the reason above the name: a hierarchical style inside a
                // control resolves against the tint and would turn this amber. `.primary`
                // for the same reason the glyph is: a group's member count sits in the mark
                // slot, so it is the heading's icon and has to carry the icon's weight —
                // left secondary it would have been the one grey mark in the app.
                .foregroundStyle(Color.primary)
                .accessibilityHidden(true)
        }
    }

    private func subtitleView(_ subtitle: Subtitle) -> some View {
        HStack(spacing: Self.dotGap) {
            if let presence = subtitle.presence {
                Circle()
                    .fill(PresenceDot.tint(isOnline: presence))
                    .frame(width: Self.dotSize, height: Self.dotSize)
                    .accessibilityHidden(true)
            }
            Text(subtitle.text)
                .font(.hive(.caption2))
                .foregroundStyle(Color.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    /// One label for both lines, so VoiceOver reads "general, 5 members · 3 online" rather
    /// than stopping at the name — the second line is the part a screen reader cannot see.
    private var accessibilityLabel: String {
        guard let subtitle else { return title }
        return "\(title), \(subtitle.text)"
    }

    // MARK: - Metrics

    /// Between the mark and the name.
    private static let markGap: CGFloat = 8
    /// Between the two lines, so the pair read as a name and its note rather than as one
    /// block. It cannot simply grow: the bar gives the item barely more height than the two
    /// lines already need, and every point here is a point off the breathing room above and
    /// below them.
    private static let betweenLines: CGFloat = 1
    /// Between the presence dot and the word beside it.
    private static let dotGap: CGFloat = 4
    /// The presence dot's diameter, against an 11pt line.
    private static let dotSize: CGFloat = 6
    /// How far up the heading is nudged inside the bar's capsule.
    ///
    /// The capsule is the bar's, not the app's, and it is ~44pt tall around a ~34pt item
    /// with the item centred — so on paper there is 5pt above and below and nothing to fix.
    /// What is centred is the item's *box*, and a two-line text box carries more empty ascent
    /// above its cap heights than descent below its baselines, so the ink inside it sits low
    /// and the second line reads as resting on the glass.
    ///
    /// Measured, not reasoned: `.padding(.vertical, _)` inside the item changes **nothing** —
    /// screenshots at 0, 2, 4 and 6pt are byte-identical, because the bar clamps the item's
    /// height. An offset is not a layout change, so it is the one lever that reaches this,
    /// and 2pt is where the ink centres. The tap target is the capsule and does not move.
    private static let verticalNudge: CGFloat = 2

    // MARK: - Rules

    /// `12 members`, with ` · 3 online` when anybody is, for a channel's second line — or
    /// nothing at all while the roster is still arriving.
    ///
    /// Pure, so the boundaries are tested rather than eyeballed. Zero members returns `nil`
    /// rather than `0 members`: the directory read is scoped to
    /// `channel_member ∪ agent_directory`, so a channel whose roster event has not landed yet
    /// answers with an empty set — and a header that stated a channel had no members would
    /// report a loading state as a fact. Zero *online* drops only that half, for the same
    /// reason: presence arrives on its own heartbeat seconds after the roster, and `0 online`
    /// during that gap is a claim about a channel rather than a report about a subscription.
    static func memberCount(_ count: Int, online: Int = 0) -> String? {
        guard count > 0 else { return nil }
        let members = count == 1 ? "1 member" : "\(count) members"
        // Clamped rather than trusted: presence is workspace-global and the roster is
        // per-channel, and the two are read a frame apart, so a member who leaves between the
        // two reads could otherwise produce "3 members · 4 online".
        let present = min(online, count)
        guard present > 0 else { return members }
        return "\(members) · \(present) online"
    }

}

extension View {
    /// Puts the conversation's heading in the navigation bar's leading slot. See
    /// ``ConversationTitleBar``.
    func conversationTitle(
        mark: ConversationTitleBar.Mark = .none,
        title: String,
        subtitle: ConversationTitleBar.Subtitle? = nil,
        actionHint: String? = nil,
        opacity: Double = 1,
        action: @escaping () -> Void,
        peopleAction: (() -> Void)? = nil
    ) -> some View {
        modifier(ConversationTitleBar(
            mark: mark,
            title: title,
            subtitle: subtitle,
            action: action,
            actionHint: actionHint,
            peopleAction: peopleAction,
            opacity: opacity
        ))
    }

    /// The same heading with nothing behind a tap — for a screen that has a name but no
    /// conversation and nowhere for the heading to lead. See ``ConversationTitleBar/isInert``.
    func conversationTitle(
        mark: ConversationTitleBar.Mark = .none,
        title: String,
        subtitle: ConversationTitleBar.Subtitle? = nil
    ) -> some View {
        modifier(ConversationTitleBar(
            mark: mark,
            title: title,
            subtitle: subtitle,
            action: {},
            isInert: true
        ))
    }
}
