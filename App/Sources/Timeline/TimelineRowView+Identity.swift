import BuzzKit
import SwiftUI

/// How a message row names its author: the resolved name, the avatar, and the header
/// line the two sit on. Split out of `TimelineRowView.swift` so that file is about the
/// row's own hierarchy and its tap arbitration, the same split
/// `TimelineRowChrome.swift` already makes for the row's furniture.
extension TimelineRowView {
    /// The author's human-readable name: the directory's answer first, so it matches
    /// every other surface, then the profile name the row itself carries for an
    /// identity the directory has no entry for. `nil` when nobody knows one.
    private var authorHumanName: String? {
        if let resolved = names.humanName(for: row.pubkey) { return resolved }
        // Trimmed, matching `DirectorySnapshot`'s own normaliser: a profile whose
        // `display_name` is `"   "` is non-empty and passed straight through, rendering a
        // blank bold name where a person's should be — and giving the monogram nothing to
        // take initials from either.
        guard let joined = row.authorName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !joined.isEmpty else { return nil }
        return joined
    }

    /// The name to render — never a raw key: a short `npub1abcdefg…wxyz` is the floor.
    var authorName: String {
        authorHumanName ?? names.shortIdentifier(for: row.pubkey)
    }

    /// The status VoiceOver announces after the message: who wrote it when the row does
    /// not say so on screen, presence, whether it was edited, and its delivery state.
    /// Pure and testable via ``MessageAccessibility``.
    ///
    /// The author is named here exactly when ``TimelineRowView/showsAuthorHeader`` is
    /// `false`. A reader with eyes takes the author of a continuation from the message
    /// above it; a reader by ear has no "above" to look at, and an unattributed run of
    /// messages is the one thing grouping must not cost them.
    var accessibilityStatus: String {
        MessageAccessibility.status(
            author: showsAuthorHeader ? nil : authorName,
            isOnline: isAuthorOnline,
            isEdited: row.isEdited,
            delivery: row.delivery
        )
    }

    /// The empty column a continuation row keeps where the avatar would be.
    ///
    /// Zero height, so it can never be the thing that decides a row's height, and the same
    /// width as the avatar so every message in a block starts on one left edge — the
    /// alignment is the whole reason a block reads as a block.
    var gutter: some View {
        Color.clear
            .frame(width: avatarSize, height: 0)
            .accessibilityHidden(true)
    }

    /// The author's avatar with a presence badge — Slack's rounded square (the shape
    /// ``AvatarView`` already defaults to), downsampled artwork or a monogram, and a
    /// green dot at its corner when the author is online. The frame is fixed before
    /// the artwork exists, so a picture arriving never moves a row.
    ///
    /// Tapping it opens the author's profile. The target is the avatar's own 34pt,
    /// under the 44pt guideline and deliberately so: expanding it would either widen
    /// the gutter every message is indented by or reach into the first line of text.
    /// The name beside it is a second, much larger target for the same destination, and
    /// VoiceOver reaches the sheet through the message's own rotor action, so the small
    /// square is a convenience rather than the only way in.
    @ViewBuilder
    var avatar: some View {
        let artwork = AvatarView(
            url: authorPictureURL,
            seed: row.pubkey,
            monogram: authorInitials,
            size: avatarSize
        )
        .overlay(alignment: .bottomTrailing) {
            if isAuthorOnline { presenceBadge }
        }

        if let onOpenProfile {
            Button {
                performControlAction { onOpenProfile(row.pubkey) }
            } label: {
                artwork
            }
            .buttonStyle(PressFeedbackButtonStyle())
            // `AvatarView` hides itself from VoiceOver, so the button needs its own
            // label or it reads as an unnamed control. The presence signal is not
            // repeated here — the message's accessibility value already carries it.
            .accessibilityLabel("\(authorName)'s profile")
        } else {
            artwork
        }
    }

    /// Up to two initials for the monogram, always taken from the name actually shown
    /// so the two cannot disagree.
    private var authorInitials: String {
        EntityNames.initials(from: authorHumanName)
    }

    /// Everything a picture in this message needs to name itself in the full-screen
    /// viewer: this row's author as the directory currently resolves them, when the
    /// message was sent, and the conversation the surface said it is drawing.
    ///
    /// `nil` when the surface named no conversation — the viewer then draws no header
    /// rather than one that cannot say where the picture came from. Built here rather than
    /// by the viewer because this is the only place all three halves are in hand at once.
    var mediaAttribution: MessageMediaAttribution? {
        guard let conversation else { return nil }
        return MessageMediaAttribution(
            authorName: authorName,
            authorPictureURL: authorPictureURL,
            authorInitials: authorInitials,
            authorSeed: row.pubkey,
            sentAt: row.date,
            conversationTitle: conversation.title,
            conversationIsDirect: conversation.isDirect
        )
    }

    /// The directory's artwork, falling back to whatever the message's own joined
    /// profile row carried.
    private var authorPictureURL: URL? {
        if let resolved = names.picture(for: row.pubkey) { return resolved }
        guard let picture = row.authorPicture, !picture.isEmpty else { return nil }
        return URL(string: picture)
    }

    private var presenceBadge: some View {
        let badge = MessageRowMetrics.presenceBadge(for: avatarSize)
        return Circle()
            .fill(Color.green)
            .frame(width: badge.diameter, height: badge.diameter)
            .overlay(Circle().strokeBorder(Color(.systemBackground), lineWidth: badge.ring))
    }

    /// Name in bold with the time immediately beside it, Slack's arrangement — the
    /// time reads as part of the attribution rather than as a right-aligned column.
    ///
    /// Aligned on the first text baseline, not centred: a 15pt name beside a 12pt time
    /// centred vertically leaves the time floating half a line high, and the baseline is
    /// the line a reader's eye actually follows across.
    var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: MessageRowMetrics.headerGap) {
            name
            MessageTimestampView(date: row.date)
                .fixedSize()
            if row.isReply {
                Image(systemName: "arrowshape.turn.up.left")
                    .font(.hiveSymbol(.caption2))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Reply")
            }
            Spacer(minLength: 0)
        }
    }

    /// The sender's name: bold, one line, and a control when there is a profile to open.
    ///
    /// Bold rather than the reference client's semibold. §3 names it explicitly, and at
    /// `.subheadline` against a `.body` message the attribution is the *smaller* of the
    /// two — semibold at 15pt beside regular at 17pt reads as the quieter one, which
    /// inverts the hierarchy the weight is there to establish.
    @ViewBuilder
    private var name: some View {
        let label = Text(authorName)
            .font(.hive(.subheadline, weight: .bold))
            .foregroundStyle(.primary)
            // One line: a 200-character display name is somebody else's choice, and it
            // must not shove the timestamp off the screen.
            .lineLimit(1)

        if let onOpenProfile {
            Button {
                performControlAction { onOpenProfile(row.pubkey) }
            } label: {
                label
            }
            .buttonStyle(PressFeedbackButtonStyle())
        } else {
            label
        }
    }
}
