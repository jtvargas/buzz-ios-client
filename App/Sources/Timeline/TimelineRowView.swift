import BuzzKit
import SwiftUI

/// One timeline message, in Slack's hierarchy: a rounded-square avatar, the author's
/// name in bold with the time beside it, then the content (markdown with a plain
/// fallback, or a "message deleted" placeholder), reaction chips, a reply preview with
/// its participants' faces, and the delivery treatment — `.pending` dimmed, `.failed`
/// carrying a tap-to-retry strip, `.sent` plain.
///
/// # What the row deliberately is not
///
/// It has no resting background, no border, and no inset panel (§3: *do not make every
/// message look like a card*), and — since the owner had the press highlight taken off both
/// the sidebar and the message — **nothing behind it under a finger either**. The only thing
/// between two messages is ``MessageRowMetrics``' space — 12pt between blocks, 6pt inside one
/// — applied by the enclosing list rather than as padding here, so the row's height is its
/// content's height and nothing else whether or not it names its author
/// (``showsAuthorHeader``).
///
/// A message answering a finger with nothing is a decision, not an omission. What a press on
/// a message is *for* is the actions sheet, and that announces itself twice already: a haptic
/// on recognition and then the sheet itself. The wash that used to sit here was a third
/// announcement, and it cost this file two rounds of trouble — the construction that drew it
/// is the same construction that took the conversation's scrolling away.
///
/// The two controls it carries — the avatar and the name — take the `inline` press
/// treatment and no haptic, because a tap there is on its way to a sheet that will
/// announce itself.
///
/// # Where the name and the time come from
///
/// The name, artwork, and monogram are resolved through the injected ``EntityNames``,
/// not from the row's own joined profile columns, so one person reads identically here,
/// in the sidebar, and inside a mention — and a name that lands after the message did
/// updates every surface at once. The row's own `authorName` stays as the fallback for
/// someone the directory has never seen (a member who left). That half lives in
/// `TimelineRowView+Identity.swift`.
///
/// The timestamp is a ``MessageTimestampView`` leaf: it, and nothing else in the row,
/// observes the shared 15-second clock, so an ageing `3 min ago` re-evaluates one
/// `Text` instead of the message.
///
/// A long press asks the surface to open ``MessageActionsSheet`` — the quick reactions, the
/// emoji picker, and the actions — and so does a **double tap**, anywhere on the message
/// including on a picture inside it. That second way in is what defers the row's own tap: see
/// ``MessageTapArbiter``. The same row renders in the channel timeline and inside a thread;
/// `onOpenThread` is supplied only in the channel, where a threaded message can be opened, and
/// omitted inside the thread it already shows.
struct TimelineRowView: View {
    @Environment(\.channelNameMap) private var channelNameMap
    /// The app's one identity resolver. Internal rather than private because the row's
    /// identity half lives beside it in `TimelineRowView+Identity.swift`, and Swift's
    /// `private` is file-scoped.
    @Environment(\.entityNames) var names
    @Environment(\.openURL) private var openURL
    /// The stack's own navigation, for a pressed `#`-channel or internal message link.
    @Environment(\.openConversation) private var openConversation
    /// The app-wide markdown reader, installed above the tabs. `nil` in a preview.
    @Environment(\.openMarkdownDocument) private var openMarkdownDocument
    /// Whether a control inside the row already answered the touch the row's own tap is
    /// about to act on. Internal for the same reason ``names`` is: the rules that read it
    /// live in `TimelineRowView+Taps.swift`.
    @State var arbitration = RowTapArbitration()
    /// Resolves this row's taps against each other: one opens what was tapped, two open a
    /// sheet. See ``MessageTapArbiter`` for what that costs the single tap.
    @State var taps = MessageTapArbiter()

    /// The avatar's point size, and so the width the content column is indented by, at
    /// this reader's text size. Scaled against `.subheadline` — the name beside it — so
    /// the gutter and the attribution grow together.
    ///
    /// Internal rather than private because the row's identity half lives beside it in
    /// `TimelineRowView+Identity.swift`, and Swift's `private` is file-scoped.
    @ScaledMetric(relativeTo: .subheadline)
    var avatarSize: CGFloat = MessageRowMetrics.avatarSize

    let row: TimelineRow
    /// Whether this row names its author: the avatar, the bold name, and the time.
    ///
    /// `false` for a message that continues the block above it — the same author, inside
    /// ``ConversationGrouping/groupWindow``, with nothing drawn in between. The row then
    /// stacks under the one that did name them: no face, no name, no time, and the avatar
    /// gutter kept empty so the text still starts on the block's own left edge.
    ///
    /// Decided by ``ConversationGrouping`` and handed down, never worked out here. A row
    /// can only see itself, so a row that grouped itself would need the surface to tell it
    /// what came before anyway — and each surface would end up with its own copy of the
    /// rule, which is exactly what day separators being items rather than row headers
    /// avoids. Defaults to `true` for the surfaces that draw a message on its own (the
    /// Threads screen's summaries), where there is no block to continue.
    var showsAuthorHeader = true
    /// Whether this message's author is present in the workspace (S-5 presence).
    var isAuthorOnline: Bool = false
    /// The surviving reaction groups for this row (S-2), own reaction highlighted.
    var reactions: [ReactionGroup] = []
    /// The users this message mentions, resolved to names from its own `p` tags —
    /// so a mention renders identically wherever the row appears (WS-1 #9).
    var mentions: [MentionRef] = []
    /// The distinct people who replied in this message's thread, oldest reply first and
    /// already capped by the read. Empty when the row has no thread, or on a surface
    /// that does not preview one.
    var replyParticipants: [String] = []
    /// The local identity's hex pubkey, for self-mention emphasis. `nil` degrades to
    /// no self-emphasis (keyless fallback).
    var selfPubkey: String?
    /// Whether this conversation currently accepts writes. Reading the timeline,
    /// opening threads, copying, and profiles remain available while stale.
    var allowsInteraction = true
    /// Re-queue a failed send — the action on the strip under the row.
    ///
    /// The row no longer asks whether the message is the local identity's own: only an own
    /// send can be pending or failed, and Delete, which was the other thing that answer
    /// gated, has moved to the actions sheet.
    let onRetry: (String) -> Void
    /// Send a fresh reaction with this emoji.
    var onReact: (String) -> Void = { _ in }
    /// Toggle an existing chip (add, or withdraw an own reaction).
    var onToggleReaction: (ReactionGroup) -> Void = { _ in }
    /// Open this message's thread; absent when already inside a thread.
    var onOpenThread: (() -> Void)?
    /// Open the actions sheet for this message. Absent on a surface that presents no sheet —
    /// the Threads screen's summaries — where the row then keeps its plain tap and a long
    /// press does nothing, rather than arming a gesture with nowhere to go.
    var onLongPress: (() -> Void)?
    /// Show the author's profile — raised by the avatar and by the name, so the row
    /// asks and the surface presents. Absent on a surface with nowhere to present it,
    /// where the identity then renders as plain text rather than as a dead control.
    var onOpenProfile: ((String) -> Void)?
    /// The conversation this row is being drawn in, when the surface knows one.
    ///
    /// Used only to name the place a picture was posted in, in the full-screen viewer's
    /// header — the row itself draws nothing from it. `nil` on a surface that is not a
    /// conversation, where a picture's viewer then draws no header. ``TimelineRow`` cannot
    /// answer this itself: it carries no channel id, deliberately, and the Threads screen
    /// draws rows from several conversations at once.
    var conversation: ConversationIdentity?
    /// How many lines of the message body to draw, or `nil` for all of them.
    ///
    /// `nil` on both conversation surfaces: a message being read is read whole. The Threads
    /// screen is the one place a bound belongs, because a row there is a summary of a
    /// conversation and a single 40-line opener would be the whole screen.
    var contentLineLimit: Int?

    var body: some View {
        HStack(alignment: .top, spacing: MessageRowMetrics.avatarGap) {
            if showsAuthorHeader {
                avatar
            } else {
                gutter
            }
            VStack(alignment: .leading, spacing: 4) {
                message

                if !row.isDeleted, !reactions.isEmpty {
                    ReactionChipsView(
                        groups: reactions,
                        onTap: { group in
                            performControlAction { onToggleReaction(group) }
                        },
                        onReact: { emoji in
                            performControlAction { onReact(emoji) }
                        },
                        // The palette *opening* is the event to arbitrate, not the emoji
                        // chosen from it: the tap that opens it is the same tap the row
                        // would read as "open the thread".
                        onOpenPalette: { claimTap() }
                    )
                    .allowsHitTesting(allowsInteraction)
                }
                if row.hasThread, let onOpenThread {
                    RepliesButton(
                        count: row.replyCount,
                        lastReplyAt: row.lastReplyDate,
                        participants: replyParticipants,
                        action: {
                            performControlAction(onOpenThread)
                        }
                    )
                }
                if case let .failed(reason) = row.delivery {
                    RetryStrip(
                        reason: reason,
                        canRetry: row.failureIsRetryable && allowsInteraction
                    ) {
                        performControlAction { onRetry(row.id) }
                    }
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
        .gesture(pressGesture)
        // Every interactive range of a message — mention, channel, link, email,
        // internal link — is a link run, because that is the only run of a `Text` a
        // reader can press (see ``RichTextTarget``). They all arrive here. Marking the
        // gesture first is what keeps pressing one from also pushing the thread.
        .environment(\.openURL, OpenURLAction { url in
            claimTap()
            switch RichTextRoute(url: url) {
            case let .profile(pubkey):
                onOpenProfile?(pubkey)
            case let .conversation(channelID):
                openConversation?(channelID)
            case let .markdownDocument(document):
                // No reader installed — outside the app's root, in a preview or a test — means
                // the browser, which is where this link went before there was a reader.
                if let openMarkdownDocument {
                    openMarkdownDocument(document)
                } else {
                    openURL(document.url)
                }
            case let .external(url):
                openURL(url)
            case .none:
                openURL(url)
            }
            return .handled
        })
        // The same claim, for everything in the row that is not a link run: an attachment,
        // which is a view that presents its own viewer and hands nothing to `openURL`, and
        // every control carrying the app's press treatment — the avatar, the name, the
        // reaction chips — each of which claims as the finger lands and again as it leaves.
        // See ``scheduleRowTap()`` for why the press and not the action.
        .environment(\.claimRowTap, ClaimRowTapAction { claimTap() })
        // What a picture inside the message hands its own tap to, so that opening it and
        // opening a sheet are decided by one arbiter rather than two racing ones. A tap on a
        // picture is a tap on the message: it must be able to be the first half of a double,
        // and the second half must be able to land anywhere on the row. What that double then
        // *means* is the picture's — see ``MediaActionsSheet``.
        .environment(
            \.messageTap,
            MessageTapAction(
                single: { single, double in taps.tapped(single: single, double: double) },
                double: { double in taps.doubleTapped(double) }
            )
        )
        .accessibilityAction(named: "Open thread") {
            onOpenThread?()
        }
        // By ear there is no press to hold, so the sheet is offered as a rotor action — and
        // only where there is one to open, so a surface without it grows no dead action.
        .accessibilityActions {
            if let onLongPress {
                Button("Message actions", action: onLongPress)
            }
        }
    }

    /// The attribution and the body as one VoiceOver utterance: `.combine` flattens its
    /// children, so the name button inside stops being separately reachable and the
    /// message reads as a sentence instead of as three fragments. The profile it opens
    /// is offered back as a rotor action, which is the only way in by ear.
    private var message: some View {
        VStack(alignment: .leading, spacing: 2) {
            if showsAuthorHeader { header }
            content
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(accessibilityStatus)
        .accessibilityActions {
            if let onOpenProfile {
                Button("View profile") { onOpenProfile(row.pubkey) }
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if row.isDeleted {
            Text("message deleted")
                .font(.hive(.body))
                .italic()
                .foregroundStyle(.secondary)
        } else {
            // One engine for both kind-40002 rich markdown and plain kind-9 content:
            // block layout, safe links, and resolved @mention / #channel tokens, so a
            // message renders identically on every surface (WS-1 #7/#9).
            RichTextView(
                text: bodyText,
                media: row.media,
                resolver: resolver,
                attribution: mediaAttribution
            )
                // Applied here rather than inside the renderer: it is a property of a
                // message being read in a timeline, not of the markdown, and the
                // channel-list snippet wants its single line tight.
                .lineSpacing(MessageRowMetrics.bodyLineSpacing)
                // A no-op at `nil`, which is every message on both conversation surfaces.
                .lineLimit(contentLineLimit)
        }
    }

    /// The content to render: the kind-40002 rich markdown when present, otherwise
    /// the plain kind-9 body. Both flow through the same engine.
    var bodyText: String {
        if let rich = row.richContent, !rich.isEmpty { return rich }
        return row.content
    }

    /// The agents among *this message's* mentions, so a mention of one draws the bot
    /// glyph in place of its `@`.
    ///
    /// Scoped to the refs rather than handed the whole directory: `EntityNames.isAgent`
    /// is a dictionary hit, the list is a message's `p` tags rather than a roster, and
    /// the result feeds ``MessageMentionResolver/identity`` — a set that grew with every
    /// agent in the community would re-key every cached render whenever any of them
    /// joined a channel.
    var agentPubkeys: Set<String> {
        Set(mentions.map(\.pubkey).filter(names.isAgent))
    }

    /// The per-message resolver: mentions from this row's own `p`-tag refs, channels
    /// from the app-wide injected map, self from the local identity.
    ///
    /// The refs go through ``EntityNames/aliased(_:)`` first. BuzzKit resolves a ref's name
    /// from the `profile` projection alone and falls back to eight characters of the key,
    /// so a mentioned user with no kind-0 profile rendered either a tinted key prefix or —
    /// when the token was authored against an agent-directory or NIP-05 name — nothing at
    /// all. The sidebar's preview goes through the same call, so all three surfaces agree.
    var resolver: MessageMentionResolver {
        MessageMentionResolver(
            mentions: names.aliased(mentions),
            channels: channelNameMap,
            selfPubkey: selfPubkey,
            agentPubkeys: agentPubkeys
        )
    }
}
