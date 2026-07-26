# ADR-0004: Conversation UI architecture

**Status:** Accepted

## Context

Phase 4 delivered the messaging surfaces feature-by-feature: a rich-text renderer, a
mention composer, thread navigation, reaction polish, a channel list. Daily driving
the result surfaced eleven areas of polish, and the striking thing about the list was
how much of it was the *same* defect seen from different surfaces:

- a member read as a display name in one place, a truncated hex key in another, and a
  raw group id in a third, because each surface owned its own fallback;
- timestamps were formatted per row, in two different styles, one of which never aged;
- the composer, the keyboard inset, and the scroll anchoring were re-derived per
  screen — the channel and the thread each carried a slightly different copy;
- day separators did not exist, and the obvious cheap version (a header on the first
  message of a day) would have put the grouping decision inside the row view, where a
  channel, a thread, and a DM each get their own subtly different copy of it.

The owner's brief made the structural requirement explicit: *"avoid implementing these
fixes as isolated patches"*. It also settled a product question that the code had no
way to answer — **a direct message is a channel whose roster is exactly two members** —
which means DMs are not a new surface but a *reading* of an existing one.

## Decision

Four shared pieces own what the surfaces used to each own a copy of.

**1. One directory read, one resolver.** `BuzzEventStore.directorySnapshot()` returns
every nameable identity and every channel roster in a single read, tracked by a single
`ValueObservation` (`EntityDirectoryModel`). `EntityNames` — injected once above the
navigation stack — is the only place that turns identity into text, artwork, or
conversation identity. Its fallback chain is fixed:

> kind-0 profile display name → agent directory (kind 10100) name → NIP-05 username
> (local part, or the domain for the `_` root form) → `npub1abcdefg…wxyz`

A full 64-character key and a channel group id never render in ordinary UI. The single
exception is the channel-details **Developer** section, which exists to be technical.

**2. One DM derivation.** `EntityNames.directPeer(in:)` — roster count exactly two
*and* the local identity among them — is the only implementation of the product rule.
`EntityNames.conversation(for:)` returns a `ConversationIdentity` whose `kind` is
`.channel`, `.direct`, or `.agent`, and the sidebar's sections, the conversation
header, and the details sheet all read that one value rather than re-deriving it.

**3. One clock, and separators as list items.** `MessageTimestamp` and
`DaySeparatorLabel` are pure and injectable (`now`, `locale`, `calendar`), so the
boundaries are tested rather than eyeballed. A single `RelativeTimeTicker` ticks every
15 s and is observed **only** by `MessageTimestampView` leaves, so a tick re-evaluates
a handful of `Text`s instead of the message list. `ConversationGrouping.items(for:)`
turns rows into `[ConversationItem]` — `.day` or `.message` — computed once per rows
change in the model and rendered identically by channel, thread, and DM.

**4. One conversation shell.** `ConversationScaffold` owns the message list, the
floating composer, and the keyboard/safe-area behaviour for every surface. The list
keeps full height and the composer is attached with `safeAreaBar(edge: .bottom)`; the
mention suggestion panel floats over the list as a `ZStack` accessory rather than
living inside the bar. Scroll *policy* lives in the scaffold (three
`defaultScrollAnchor` roles, one `onScrollGeometryChange` reporting three `Bool` bands —
at the bottom, clearly away from it, and near the top, the first two being the hysteresis
loop); scroll *content* policy lives in the model, which decides what "the reader is not
at the bottom" means.

## Rationale

- **Liquid Glass forced the layering decision.** `glassEffect` renders the material
  over what is *behind* the view. A composer laid out beside the list (the Phase-4
  `VStack`) has nothing behind it, so it renders as a flat opaque panel — and the
  keyboard region, being outside that `VStack`'s frame, shows whatever is behind the
  navigation stack. Both reported symptoms are the same layering bug, and overlaying
  the list fixes both.
- **`safeAreaBar` over the alternatives.** It is documented as `safeAreaInset` plus
  "extends the edge effect of any scroll views affected by the inset safe area", which
  is exactly what a floating bar over scrolling content needs. `overlay` floats but
  does not inset, so the last message becomes unreachable; an `inputAccessoryView` ties
  the composer's lifetime to responder state, which is the coupling behind the
  focus bugs.
- **Keyboard tracking is measured, not assumed.** Apple documents neither
  `safeAreaBar` nor `safeAreaInset` as keyboard-aware — the word "keyboard" appears on
  neither page. Measured in an isolated harness on iPhone 17 Pro / iOS 26.0: root
  bottom safe-area inset 34 at rest → 345 with the keyboard up (composer directly on
  the keyboard, content still inset) → 34 after dismissal, **with no residual spacer**.
  The recipe is kept so the next such question is also settled by measurement.
- **Focus needs one owner.** SwiftUI owns focus; UIKit reports only user-initiated
  changes. `updateUIView` guards on `view.window != nil` (a responder change before the
  view is in a window fails silently, which is how the two states start disagreeing)
  and applies the change inside a reconciliation flag with animations disabled, so the
  delegate cannot write observed state back during SwiftUI's update pass and no
  ambient animation can drive the keyboard's inset on the app's own curve.
- **The composer's text view keeps scrolling permanently enabled.** With
  `isScrollEnabled` false its pan recogniser is inert and the drag is delivered to the
  message list; keeping it live is what guarantees a drag starting in the composer
  never moves the conversation. `sizeThatFits` is therefore pure — it may be called
  several times per layout pass, so mutating UIKit state inside it was invalidating
  layout from within layout.
- **Anchors cannot express "don't move under the reader".** `ScrollAnchorRole` has no
  notion of who scrolled, and `ScrollPosition.isPositionedByUser` has no documented
  read semantics. So the timeline model freezes its rendered tail while the newest row
  is out of view and surfaces the held-back count, which is both the correct behaviour
  and unit-testable without a view host.
- **The directory observation is equality-gated.** Without the guard, any unrelated
  commit (a reaction, a read-state blob) would re-publish an identical snapshot and
  invalidate every view reading `EntityNames` — the shared resolver would become a
  global re-render pump, which is the opposite of the performance requirement it exists
  to serve.

## Consequences

- A new surface gets names, avatars, DM identity, timestamps, separators, keyboard
  handling, and scroll behaviour by construction. The cost of the next messaging
  surface is its own content, not another copy of these decisions.
- The directory read is scoped to `channel_member ∪ agent_directory`, so a message
  author who has left every channel is not in it. Those rows already carry their own
  resolved `TimelineRow.authorName` from the same `profile` projection, so nothing goes
  unnamed — but a future surface that needs to name arbitrary historical authors must
  widen the read rather than invent a second fallback.
- `EntityNames` is rebuilt when the directory or the channel list changes. Cost is kept
  proportional to the *nameless* identities (the ones whose short form has to be
  computed), not to the roster.
- Two behaviours remain device-verified rather than test-verified: scroll feel under a
  large history, and Liquid Glass rendering. Both are on the owner's daily-drive pass.
- `TextEditor(text: Binding<AttributedString>, selection:)` is new in iOS 26 and is the
  eventual native replacement for the `UITextView` bridge, which would delete this
  whole class of first-responder bug. It was deliberately not taken in this pass: it
  fills available space rather than growing to fit, so the composer's six-line growth
  needs re-solving first. Worth a spike once the scaffold is stable.
