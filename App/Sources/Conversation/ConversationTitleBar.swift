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
    /// An enum rather than an optional symbol name because the three cases are not variations
    /// on one drawing — a face is a different width, a different shape, and a different
    /// reserve against the overflow rule than a glyph is.
    enum Mark: Equatable {
        /// No mark; the name stands on its own.
        case none
        /// An SF Symbol — `number` for a channel, `text.append` for a thread.
        case symbol(String)
        /// The peer's picture, falling back to their monogram. A person is recognised by
        /// their face before their name, which a glyph cannot do.
        case avatar(url: URL?, seed: String, initials: String)
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

    /// The bound on the text column, kept in step with the surface's width so the pill can
    /// be as wide as the bar allows in landscape without risking the overflow menu in
    /// portrait. Seeded at the floor rather than left unbounded: an unbounded first frame is
    /// the one case that *would* collapse into the `…` menu, and a heading that flashes away
    /// and comes back is worse than one that starts narrow and grows.
    @State private var labelWidth: CGFloat = ConversationTitleBar.minimumLabelWidth

    /// What the bar spends on everything that is not the name when the mark is a glyph: the
    /// back button, the bar's leading and trailing margins, the glyph, and the capsule's own
    /// padding. Measured, and deliberately ~25pt above the observed cliff.
    private static let glyphChrome: CGFloat = 180
    /// The narrowest column the heading is ever given — also the seed, so it is a width that
    /// is safe on the narrowest iPhone that runs iOS 26 rather than a placeholder.
    private static let minimumLabelWidth: CGFloat = 190
    /// The face's point size. Fixed rather than `@ScaledMetric`: the bar caps its own type
    /// growth, so an avatar that kept growing would be the one thing left in the item still
    /// pushing it towards the overflow menu at an accessibility size.
    static let avatarSize: CGFloat = 26

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                labelWidth = Self.labelWidth(forSurfaceWidth: width, mark: mark)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: action) { label }
                        .accessibilityLabel(accessibilityLabel)
                        .accessibilityHint(actionHint ?? "")
                }
                // Keeps the heading a capsule of its own at the leading edge rather than
                // letting the bar centre or stretch it, and is the seam anything added at
                // the trailing edge later would sit the other side of.
                ToolbarSpacer(.flexible, placement: .topBarLeading)
            }
    }

    /// Deliberately without a `glassEffect` or vertical padding of its own: both belong to
    /// the bar in iOS 26, and adding them here is what made this item too tall to fit the
    /// first time. See the type comment.
    private var label: some View {
        HStack(spacing: Self.markGap) {
            markView
            VStack(alignment: .leading, spacing: Self.betweenLines) {
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.primary)
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
        case let .symbol(name):
            Image(systemName: name)
                // A step above the name rather than two: at `.title3` the `#` was the
                // loudest thing in the bar and hung below the second line's baseline, which
                // is most of what read as the heading being crammed.
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        case let .avatar(url, seed, initials):
            AvatarView(url: url, seed: seed, monogram: initials, size: Self.avatarSize)
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
                .font(.caption2)
                .foregroundStyle(.secondary)
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

    /// The mark for a conversation: a `#` for a channel, and the peer's own face for a
    /// direct message.
    ///
    /// Pure and tested rather than branched at each call site, because "what marks a
    /// conversation" is a product rule and there are three surfaces that could each answer it
    /// differently. A `#` in front of a person's name would be a category error, and so would
    /// a face in front of a room's name.
    static func mark(for conversation: ConversationIdentity) -> Mark {
        switch conversation.kind {
        case .channel:
            .symbol("number")
        case .direct, .agent:
            .avatar(
                url: conversation.picture,
                seed: conversation.avatarSeed,
                initials: conversation.initials
            )
        }
    }

    /// The text column a surface `width` points wide gets, for a heading carrying `mark`.
    /// Exposed so the rule that keeps the heading out of the overflow menu is tested rather
    /// than only screenshotted.
    static func labelWidth(forSurfaceWidth width: CGFloat, mark: Mark) -> CGFloat {
        max(minimumLabelWidth, width - reservedChrome(for: mark))
    }

    /// What the bar spends on everything that is not the name.
    ///
    /// A face is wider than a glyph and costs the name that difference — charged here rather
    /// than absorbed, because absorbing it is how a long agent name would take the whole
    /// heading into the `…` menu on a narrow screen.
    static func reservedChrome(for mark: Mark) -> CGFloat {
        switch mark {
        case .none, .symbol:
            glyphChrome
        case .avatar:
            // The face, less the glyph it stands in for: a `#` at `.title3` measures ~14pt
            // wide on the iOS 26 simulator.
            glyphChrome + (avatarSize - 14)
        }
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
        action: @escaping () -> Void
    ) -> some View {
        modifier(ConversationTitleBar(
            mark: mark,
            title: title,
            subtitle: subtitle,
            action: action,
            actionHint: actionHint
        ))
    }
}
