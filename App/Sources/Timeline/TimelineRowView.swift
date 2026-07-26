import BuzzKit
import SwiftUI
import UIKit

/// One timeline message, in Slack's hierarchy: a rounded-square avatar, the author's
/// name in bold with the time beside it, then the content (markdown with a plain
/// fallback, or a "message deleted" placeholder), reaction chips, a "N replies"
/// affordance, and the delivery treatment — `.pending` dimmed, `.failed` carrying a
/// tap-to-retry strip, `.sent` plain.
///
/// # Where the name and the time come from
///
/// The name, artwork, and monogram are resolved through the injected
/// ``EntityNames``, not from the row's own joined profile columns, so one person reads
/// identically here, in the sidebar, and inside a mention — and a name that lands
/// after the message did updates every surface at once. The row's own `authorName`
/// stays as the fallback for someone the directory has never seen (a member who left).
///
/// The timestamp is a ``MessageTimestampView`` leaf: it, and nothing else in the row,
/// observes the shared 15-second clock, so an ageing `3 min ago` re-evaluates one
/// `Text` instead of the message.
///
/// A long-press menu offers a quick-reaction palette and Copy, plus Retry/Delete on
/// an own pending or failed row. The same row renders in the channel timeline and
/// inside a thread; `onOpenThread` is supplied only in the channel, where a threaded
/// message can be opened, and omitted inside the thread it already shows.
struct TimelineRowView: View {
    @Environment(\.channelNameMap) private var channelNameMap
    @Environment(\.entityNames) private var names
    @Environment(\.openURL) private var openURL
    @State private var suppressNextRowTap = false

    let row: TimelineRow
    /// Whether this message's author is present in the workspace (S-5 presence).
    var isAuthorOnline: Bool = false
    /// The surviving reaction groups for this row (S-2), own reaction highlighted.
    var reactions: [ReactionGroup] = []
    /// The users this message mentions, resolved to names from its own `p` tags —
    /// so a mention renders identically wherever the row appears (WS-1 #9).
    var mentions: [MentionRef] = []
    /// The local identity's hex pubkey, for self-mention emphasis. `nil` degrades to
    /// no self-emphasis (keyless fallback).
    var selfPubkey: String?
    /// Whether this is the local identity's own send, gating Delete/Retry in the menu.
    var isOwn: Bool = false
    let onRetry: (String) -> Void
    /// Send a fresh reaction with this emoji.
    var onReact: (String) -> Void = { _ in }
    /// Toggle an existing chip (add, or withdraw an own reaction).
    var onToggleReaction: (ReactionGroup) -> Void = { _ in }
    /// Discard this own pending/failed row.
    var onDelete: (String) -> Void = { _ in }
    /// Open this message's thread; absent when already inside a thread.
    var onOpenThread: (() -> Void)?

    /// The avatar's point size — also the width the content column is indented by, so
    /// every row's text starts on the same vertical line.
    private static let avatarSize: CGFloat = 36

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            avatar
            VStack(alignment: .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: 2) {
                    header
                    content
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(accessibilityStatus)

                if !row.isDeleted, !reactions.isEmpty {
                    ReactionChipsView(
                        groups: reactions,
                        onTap: { group in
                            performControlAction { onToggleReaction(group) }
                        },
                        onReact: { emoji in
                            performControlAction { onReact(emoji) }
                        }
                    )
                }
                if row.hasThread, let onOpenThread {
                    RepliesButton(
                        count: row.replyCount,
                        lastReplyAt: row.lastReplyDate,
                        action: {
                            performControlAction(onOpenThread)
                        }
                    )
                }
                if case let .failed(reason) = row.delivery {
                    RetryStrip(reason: reason) { onRetry(row.id) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(row.delivery == .pending ? 0.5 : 1)
        // Both animations are scoped to a value on *this* row, never ambient: a
        // pending→sent handover fades, and nothing here can catch the enclosing list
        // inserting a row into a bottom-anchored scroll view.
        .animation(.default, value: row.delivery)
        .animation(.default, value: isAuthorOnline)
        .contentShape(.rect)
        .onTapGesture {
            scheduleRowTap()
        }
        // AttributedString links are controls inside the otherwise tappable row.
        // Mark their gesture before handing the URL back to the app environment so
        // opening a link never also pushes the message's thread.
        .environment(\.openURL, OpenURLAction { url in
            suppressRowTapBriefly()
            openURL(url)
            return .handled
        })
        .accessibilityAction(named: "Open thread") {
            onOpenThread?()
        }
        .contextMenu {
            menuItems
        } preview: {
            MessagePreview(row: row, authorName: authorName, bodyText: bodyText, resolver: resolver)
        }
    }

    private func scheduleRowTap() {
        guard !row.isDeleted, let onOpenThread else { return }
        DispatchQueue.main.async {
            guard !suppressNextRowTap else { return }
            onOpenThread()
        }
    }

    private func performControlAction(_ action: () -> Void) {
        suppressRowTapBriefly()
        action()
    }

    private func suppressRowTapBriefly() {
        suppressNextRowTap = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            suppressNextRowTap = false
        }
    }

    // MARK: - Identity

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
    private var authorName: String {
        authorHumanName ?? names.shortIdentifier(for: row.pubkey)
    }

    /// Up to two initials for the monogram, always taken from the name actually shown
    /// so the two cannot disagree.
    private var authorInitials: String {
        EntityNames.initials(from: authorHumanName)
    }

    /// The directory's artwork, falling back to whatever the message's own joined
    /// profile row carried.
    private var authorPictureURL: URL? {
        if let resolved = names.picture(for: row.pubkey) { return resolved }
        guard let picture = row.authorPicture, !picture.isEmpty else { return nil }
        return URL(string: picture)
    }

    /// The author's avatar with a presence badge — Slack's rounded square (the shape
    /// ``AvatarView`` already defaults to), downsampled artwork or a monogram, and a
    /// green dot at its corner when the author is online. The frame is fixed before
    /// the artwork exists, so a picture arriving never moves a row. The badge carries
    /// the presence signal VoiceOver reads through the row's accessibility value, so
    /// the avatar itself stays decorative.
    private var avatar: some View {
        AvatarView(
            url: authorPictureURL,
            seed: row.pubkey,
            monogram: authorInitials,
            size: Self.avatarSize
        )
        .overlay(alignment: .bottomTrailing) {
            if isAuthorOnline {
                Circle()
                    .fill(Color.green)
                    .frame(width: 11, height: 11)
                    .overlay(Circle().strokeBorder(Color(.systemBackground), lineWidth: 2))
            }
        }
    }

    /// The status VoiceOver announces after the message: presence, whether it was
    /// edited, and its delivery state. Pure and testable via ``MessageAccessibility``.
    private var accessibilityStatus: String {
        MessageAccessibility.status(isOnline: isAuthorOnline, isEdited: row.isEdited, delivery: row.delivery)
    }

    /// Name in bold with the time immediately beside it, Slack's arrangement — the
    /// time reads as part of the attribution rather than as a right-aligned column.
    private var header: some View {
        HStack(spacing: 6) {
            Text(authorName)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            MessageTimestampView(date: row.date)
                .fixedSize()
            if row.isReply {
                Image(systemName: "arrowshape.turn.up.left")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Reply")
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var content: some View {
        if row.isDeleted {
            Text("message deleted")
                .font(.body)
                .italic()
                .foregroundStyle(.secondary)
        } else {
            // One engine for both kind-40002 rich markdown and plain kind-9 content:
            // block layout, safe links, and resolved @mention / #channel tokens, so a
            // message renders identically on every surface (WS-1 #7/#9).
            RichTextView(text: bodyText, resolver: resolver)
        }
    }

    /// The content to render: the kind-40002 rich markdown when present, otherwise
    /// the plain kind-9 body. Both flow through the same engine.
    private var bodyText: String {
        if let rich = row.richContent, !rich.isEmpty { return rich }
        return row.content
    }

    /// The per-message resolver: mentions from this row's own `p`-tag refs, channels
    /// from the app-wide injected map, self from the local identity.
    ///
    /// The refs go through ``EntityNames/aliased(_:)`` first. BuzzKit resolves a ref's name
    /// from the `profile` projection alone and falls back to eight characters of the key,
    /// so a mentioned user with no kind-0 profile rendered either a tinted key prefix or —
    /// when the token was authored against an agent-directory or NIP-05 name — nothing at
    /// all. The sidebar's preview goes through the same call, so all three surfaces agree.
    private var resolver: MessageMentionResolver {
        MessageMentionResolver(
            mentions: names.aliased(mentions),
            channels: channelNameMap,
            selfPubkey: selfPubkey
        )
    }

    /// The long-press menu: a quick-reaction palette and Copy on any live message,
    /// plus Retry (on a failed send) and Delete on an own pending/failed row.
    @ViewBuilder
    private var menuItems: some View {
        if !row.isDeleted {
            ControlGroup {
                ForEach(ReactionPalette.common, id: \.self) { emoji in
                    Button(emoji) { onReact(emoji) }
                }
            }
            Button {
                UIPasteboard.general.string = row.content
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
        }
        if isOwn, row.delivery != .sent {
            if case .failed = row.delivery {
                Button {
                    onRetry(row.id)
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
            }
            Button(role: .destructive) {
                onDelete(row.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}
