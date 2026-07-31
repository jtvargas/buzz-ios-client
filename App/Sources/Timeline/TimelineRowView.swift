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
/// It has no background, no border, and no inset panel (§3: *do not make every message
/// look like a card*). The only thing between two messages is ``MessageRowMetrics``'
/// space — 12pt between blocks, 6pt inside one — applied by the enclosing list rather
/// than as padding here, so the row's height is its content's height and nothing else
/// whether or not it names its author (``showsAuthorHeader``). The two controls it does
/// carry — the avatar and the name — show a pressed dim and no haptic, because a tap
/// there is on its way to a sheet that will announce itself.
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
/// emoji picker, and the actions. The same row renders in the channel timeline and inside a
/// thread; `onOpenThread` is supplied only in the channel, where a threaded message can be
/// opened, and omitted inside the thread it already shows.
struct TimelineRowView: View {
    @Environment(\.channelNameMap) private var channelNameMap
    /// The app's one identity resolver. Internal rather than private because the row's
    /// identity half lives beside it in `TimelineRowView+Identity.swift`, and Swift's
    /// `private` is file-scoped.
    @Environment(\.entityNames) var names
    @Environment(\.openURL) private var openURL
    /// The stack's own navigation, for a pressed `#`-channel or internal message link.
    @Environment(\.openConversation) private var openConversation
    @State private var arbitration = RowTapArbitration()
    /// Bumped by each recognised long press, purely so the haptic below has a trigger. A
    /// context menu played one of these for free; a sheet does not.
    @State private var longPresses = 0

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
        // What the context menu this replaced played on recognition, and what tells a reader
        // the sheet is coming before it has drawn a pixel.
        .sensoryFeedback(.impact(weight: .medium), trigger: longPresses)
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
            case let .external(url):
                openURL(url)
            case .none:
                openURL(url)
            }
            return .handled
        })
        // The same claim, for the one thing in a message body that is not a link run.
        // An attachment is a view: it presents its own viewer and hands nothing to
        // `openURL`, so it would otherwise open the picture and push the thread too.
        .environment(\.claimRowTap, ClaimRowTapAction { claimTap() })
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

    // MARK: - Tap arbitration

    /// How long a press has to be held before it is the actions sheet rather than a tap.
    /// Shorter than `LongPressGesture`'s own half-second default, which reads as a hesitation
    /// on a message; long enough that the flick that starts a scroll is not one.
    private static let longPressDuration: TimeInterval = 0.35

    /// A tap and a long press over the same row, resolved by the system rather than by the
    /// arbitration below.
    ///
    /// `exclusively(before:)` and not two separately attached gestures, and that is the whole
    /// reason this is a computed gesture instead of an `onTapGesture` beside an
    /// `onLongPressGesture`: SwiftUI's `TapGesture` has **no maximum duration**. A press held
    /// for a second and then lifted satisfies it, so with both attached the sheet would open
    /// on recognition and the thread would be pushed behind it on release. Exclusive
    /// composition gives the long press first refusal and only evaluates the tap when the
    /// press ended too early to be recognised.
    ///
    /// The `guard` is not a nicety: without a sheet to open, an armed long press would win
    /// the press and swallow the tap, which is the Threads screen's rows losing their only
    /// way into a thread.
    private var pressGesture: AnyGesture<Void> {
        let tap = TapGesture().onEnded { scheduleRowTap() }
        guard let onLongPress, !row.isDeleted else { return AnyGesture(tap) }
        return AnyGesture(
            LongPressGesture(minimumDuration: Self.longPressDuration)
                .onEnded { _ in
                    longPresses += 1
                    onLongPress()
                }
                .exclusively(before: tap)
                .map { _ in () }
        )
    }

    /// Opens the thread on the *next* main-actor turn, so any control the same tap also
    /// landed on has already claimed it by the time this runs.
    ///
    /// The controls that claim a tap, and how each one does it:
    ///
    /// - the avatar and the sender's name, the reaction chips, and the reply preview are
    ///   `Button`s whose actions run through ``performControlAction(_:)``;
    /// - a link inside the message body claims it in the `OpenURLAction` below, which is
    ///   the only hook a tappable run of `AttributedString` offers;
    /// - the failed-send strip's Retry claims it the same way the chips do — its closure
    ///   used to be passed straight through, so retrying a send that is not in the store
    ///   also pushed a thread for it;
    /// - the add-reaction pill is a `Menu`, which has *no* about-to-open hook at all, so
    ///   ``AddReactionButton`` carries a `simultaneousGesture` tap instead. That composes
    ///   with the menu's own recogniser rather than replacing it, so the palette still
    ///   opens; and it is effective exactly where the problem is, because the tap it
    ///   observes is the same touch-up the row's own tap gesture completes on.
    ///
    /// Anything added to the row that is a control has to join that list. There is no
    /// mechanism here that notices one by itself.
    private func scheduleRowTap() {
        guard !row.isDeleted, let onOpenThread else { return }
        DispatchQueue.main.async {
            guard !arbitration.suppressesRowTap() else { return }
            onOpenThread()
        }
    }

    /// Internal for the same reason ``avatarSize`` is: the avatar and the name are
    /// controls, and they live in the identity file.
    func performControlAction(_ action: () -> Void) {
        claimTap()
        action()
    }

    /// Claims the current tap without running anything, for a control whose action is not
    /// this row's to run — the add-reaction pill, where the thing being opened is a menu
    /// and the emoji it eventually reports is a separate event.
    func claimTap() {
        arbitration.controlDidAct()
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
            selfPubkey: selfPubkey
        )
    }
}

// MARK: - Tap arbitration

/// Whether a tap that has already landed on one of a message row's own controls should
/// also be allowed to open the row's thread.
///
/// A deadline rather than a flag with a timer behind it. Both express "for a moment after a
/// control acts", but a flag needs a second scheduled block to clear it, and two controls
/// acting inside the same window then leave one block clearing a suppression the other had
/// just set. A deadline has nothing to keep in step — and it makes the rule a value, so the
/// ordering it exists to enforce is unit-tested instead of eyeballed on a device.
struct RowTapArbitration {
    /// How long a control's action keeps the row's own tap from firing.
    ///
    /// One main-actor turn would be enough for the gestures that complete together, which
    /// is the common case; a tenth of a second also covers a control whose action lands a
    /// frame or two late, and is far short of the interval between two deliberate taps.
    static let window: TimeInterval = 0.1

    private var suppressedUntil: Date?

    /// Records that a control on the row has just handled this tap.
    mutating func controlDidAct(now: Date = .now) {
        suppressedUntil = now.addingTimeInterval(Self.window)
    }

    /// Whether the row's deferred tap should be dropped.
    func suppressesRowTap(now: Date = .now) -> Bool {
        guard let suppressedUntil else { return false }
        return suppressedUntil > now
    }
}
