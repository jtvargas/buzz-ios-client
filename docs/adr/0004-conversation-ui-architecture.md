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

A full 64-character key and a channel group id never render in ordinary UI. There are
exactly two exceptions, both of them places whose purpose *is* the identifier:

- the channel-details **Developer** section, which exists to be technical;
- the **profile sheet's key row** (`ProfileSheetView`), which is the thing someone
  opened that sheet to copy — a client that shows a person's key nowhere cannot hand it
  to another client, and asking a reader to find it in a Developer section under a
  channel is not the same affordance.

Both are labelled, monospaced, and truncated in the middle so they read as technical
values rather than as names. The profile sheet renders and copies the **`npub1…` form**,
not the hex: hex is the protocol's spelling, npub is the one other Nostr clients accept,
so a hex string would have been the wrong answer to the only question the row exists to
answer. The truncation is display-only — the whole npub goes to the pasteboard.

This is an exception for identifiers people are meant to exchange, and it does not
weaken the rule anywhere else: a name, a channel title, a mention, and a sidebar row
still never render a full identifier, and the fallback chain above remains the only way
they are named.

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

## Amendment (Part 1b, device pass)

Three findings from the owner's device pass amend the above rather than replace it.

**The heading is part of the shell, not of the navigation bar.** It was a
`ToolbarItem(placement: .topBarLeading)`, on the unverified assumption that the bar would
compress the item so `lineLimit(1)` truncated. It does not: the bar squeezes a two-line
item to a stub, and the reported symptom was "a little bubble, not an actual header".
`ConversationScaffold` now owns a `header` slot attached with `safeAreaBar(edge: .top)`.

That slot first held only the pill, under an otherwise empty system bar, and the owner
rejected the result: two rows of chrome, about 100pt before the first message. He supplied a
Slack screenshot instead, and it resolves the tension — the reference has **no system
navigation bar**. Three floating glass capsules share one row over the conversation: the back
chevron alone in a circle, the heading, and a trailing group. That is how a two-line pill sits
at back-button level; the 44pt ceiling belongs to the system bar, and there is no system bar.
So ``ConversationHeaderRow`` draws all three, the surfaces call
`.toolbar(.hidden, for: .navigationBar)`, and the row's leading inset stays
`MessageRowMetrics.rowLeading` so the heading, the avatars and the day separators start on one
line.

**Hiding the navigation bar costs the interactive pop gesture, and nothing readable says so.**
Measured by driving real left-edge drags through XCUITest (`~/.buzz/.scratch/headerharness`):
the same drag pops with the bar visible and does not with it hidden, and forcing
`interactivePopGestureRecognizer.isEnabled` back to `true` does not help. Meanwhile every
property of that recogniser reads *identically* in both cases — enabled, same
`_UINavigationInteractiveTransition` delegate, same host view, same two recognisers on the
navigation controller's view — because the refusal lives in the delegate's
`gestureRecognizerShouldBegin`. A probe that logged `isEnabled` would have reported the gesture
healthy while it was dead. `ConversationBackSwipe` restores it with a
`UIScreenEdgePanGestureRecognizer` that pops on release; what it does not restore is
interactivity, which has no public entry point.

Because the row is the app's, the height ceiling is gone — but the *width* one is not, since
the screen does not scale with the text. At AX5 the back circle and the trailing group left the
pill about 115pt, enough for the `#` and no name. So the decoration is dropped at the
accessibility sizes (it is the only thing in the row that does nothing) and the row's type is
capped at `.accessibility1`; every message still scales without limit.

**`safeAreaBar` tracks a keyboard that appears; it does not discover one already up.** The
34 → 345 → 34 measurement above holds only while the surface stays in the window. Measured
in the same style of harness (`~/.buzz/.scratch/navharness`): pushing a thread over a
focused composer makes UIKit force-resign the composer's first responder as the channel's
hosting view leaves the window, and **restore** it on the way back — a responder change
SwiftUI never asked for and never hears about. The keyboard returns, the root bottom inset
stays 34, and the composer is laid out behind the keyboard. That is the third reported
defect, and it is why `ConversationKeyboardRelease` resigns the responder in
`viewWillDisappear`, the last moment the view is still in its window: after that, UIKit's
restoration is the thing raising the keyboard, and nothing SwiftUI-side can undo it.
`onDisappear` and clearing the focus flag were both measured and are both too late.

**"UIKit reports only user-initiated changes" was too generous to UIKit.** It also resigns
and restores on window changes, which is the mechanism above. And the focus binding must
read the flag *live* — a `Bool` captured in `body` and closed over is a snapshot, and
`updateUIView` runs on layout passes too, so a layout pass between a write and the next
body re-applied the stale value and re-raised the keyboard mid-transition.

The `TextEditor` spike noted above would delete this class of bug outright, and this pass is
one more argument for taking it.

## Amendment (Part 1c/1d): the heading goes back on the system bar

The Part 1b amendment above is **superseded**. `ConversationHeaderRow`,
`ConversationHeaderPill` and `ConversationBackSwipe` are deleted; the heading is a leading
`ToolbarItem` again, with a flexible `ToolbarSpacer` splitting it from the back button so the
two read as separate glass capsules. `ConversationTitleBar` is the whole of it.

**The diagnosis behind all three previous placements was wrong.** "The bar squeezes a two-line
item to a stub" was inferred from a symptom, not measured. A leading toolbar item holds two
lines fine. What did not fit was the *old pill*, which carried its own `glassEffect` capsule
and 6pt of vertical padding **inside** the item, so it asked the bar for ~46pt where its text
needed ~34. Handing the capsule back to iOS 26 fixes it, and the back button, the material, the
metrics, the interactive drag-back and the type cap all come from the system — none of which
the hand-drawn row could reproduce. The row cost the drag-back (Part 1b's own finding) to solve
a problem that was never the bar's.

Three things the bar does that are not in the documentation and had to be measured:

1. **An item that does not fit is moved into the `…` overflow menu, not truncated.** A long
   channel name took the *entire heading* off screen. The defence is to bound the text column
   to the surface width less measured chrome (`ConversationTitleBar.labelWidth(forSurfaceWidth:mark:)`);
   an avatar is charged the extra width a `#` did not cost.
2. **A bare label is squeezed to its minimum where a `Button`'s label is sized to its ideal.**
   The thread heading had no action and came out `Th…` over `#gen…`, jammed against the glass.
   That is why the heading's action is not optional: every heading is a control, so every
   heading gets the room the bar gives a control.
3. **`padding(.vertical, _)` inside the item does nothing.** Screenshots at 0, 2, 4 and 6pt are
   byte-identical — the bar clamps the item's height. The capsule *is* ~5pt taller than the
   item on each side, but a two-line text box carries more empty ascent above its cap heights
   than descent below its baselines, so the ink sits low and the second line reads as resting
   on the glass. A 2pt `offset` is the only lever that reaches this, and it does not move the
   tap target.

What the heading carries: a `#` and `12 members · 3 online` for a channel; `text.append`
and the parent conversation for a thread; and for a direct message the peer's own face with
their presence — a green or grey dot and the word — in place of the NIP-05 identifier, which
does not change and is still on the profile sheet. Presence is read from the same
`PresenceModel` the message rows' dots are, so a row and the header cannot disagree about the
same person. The thread heading pops back to its conversation on tap, driven as a real tap in
`~/.buzz/.scratch/headerharness` (`UITests/ThreadHeadingTests.swift`) rather than assumed —
the harness now builds the shipping `ConversationTitleBar.swift` by symlink, so what is
screenshotted there is this file.

## Amendment (Parts 2–5): the conversation body, and the drag surface

Four passes since 1d extended the shell rather than changing its shape. Each settled at
least one thing Apple does not document, and those are recorded here because the next
person to touch this code will otherwise re-derive them from a symptom.

**Completion is anchored to the caret, not to the end of the draft.** `MentionDraft`
searched backwards from the end of the whole message, so a trigger typed mid-sentence
produced a query of everything after it, a newline anywhere later killed the token
outright, and a double space did the same. The scan now runs from the caret backwards to
the first delimiter, which makes mid-sentence, multiline and repeated triggers one code
path instead of three special cases. The caret itself is new information: `TokenTextView`
implements `textViewDidChangeSelection`, but reports **only when the text view and the
published draft already agree about the text** — while an edit is in flight UIKit's
selection describes a string the model has not seen, and the edit carries its own caret a
moment later. One internal space stays legal in a query, deliberately, because display
names contain spaces and `@Will Pfleger` is otherwise unreachable.

**Interactive ranges are links, because links are the only run a `Text` will let you
press.** Three measurements shaped this:

1. A custom `AttributedString` attribute is **invisible to `Text.Layout`**, so a
   `TextRenderer` cannot see it and cannot draw behind it. The inline is built as
   concatenated `Text` segments, not one attributed string. `AttributedString`'s own
   background colour was never an option either — a bare rectangle, no corner radius, no
   padding.
2. A `link` still reaches `OpenURLAction` under a custom renderer, **private schemes
   included**. So a mention travels as a URL and inherits the tap arbitration links
   already had; pressing one claims the tap and never also opens the thread. Interaction
   priority comes from that proven path rather than a second mechanism to keep in step.
3. **A press-down highlight is not affordable.** A `DragGesture(minimumDistance: 0)` on
   the text swallows the row's own tap (0 row taps across every press in the harness);
   moving it to the row keeps both taps but stops the message list scrolling at all. The
   pill flashes on activation instead — visible feedback, on release rather than on press.

Identity never comes from the visible name: a mention's URL carries the pubkey that
message's own `p` tags resolved to, an authored `hive-entity:` link is stripped (or an
author could hand themselves a mention pointing at anyone), and a `buzz://` the app cannot
route stays plain text rather than looking pressable and doing nothing.

**A pill's gap from its neighbours is kerning, not padding.** The fill is drawn 4pt past
its glyphs, and growing a fill does not move the text around it — it grows *over* the
letter beside it. The advance has to come from layout, so an interactive range is kerned
7pt before it and after its last character. The part that had to be measured: a run's
typographic bounds **include** the kern added after its last character, so the advance
inserted to open the gap was itself being filled as pill. The last character carries a
marker saying how much of its width is gap and the renderer takes it back out before
filling. Only the last character carries it, so a link wrapping across two lines still
fills to the end of its glyphs on the first line — trimming every fragment instead would
leave the characters at the wrap outside their own pill.

**A jump to a *message* cannot go through `ScrollPosition`.** `scrollTo(id:anchor:)`
reaches the right row but **loses its anchor** to `defaultScrollAnchor(.bottom, for:
.alignment)` above it: asking for a row at `.top` landed it hard against the *bottom*
edge, leaving the reader exactly where they were. That alignment anchor is what rests a
short conversation against the composer, so it stays; the message jump goes through a
`ScrollViewReader`, whose proxy honours the anchor in the same hierarchy, and the
jump-to-bottom keeps `ScrollPosition`. Two mechanisms, each doing the one it is good at.

The affordances also need their own distance band. The freeze arms ~120pt off the bottom,
which is right for "stop moving my place" and far too eager for a floating button that
would then sit on the message being read; `↓ Latest` waits for half a viewport. And the
pill's state lives in its own observable read by a leaf view — read in the same body as
the message list, every arrival while scrolled up re-evaluated the whole timeline. Both
models also stopped writing back values equal to the ones they held, which the observation
was doing on every commit regardless.

**The dismissal gesture's active band is a property, and it had to be set.**
`.scrollDismissesKeyboard(.interactively)` does not begin when the drag begins — UIKit
waits for the touch to reach the keyboard's own top edge, so the band the composer
occupies was dead and a drag ending inside it moved the keyboard across zero frames.
`ConversationKeyboardDismissPadding` sets `keyboardLayoutGuide.keyboardDismissPadding` to
the bar height the scaffold already measures. Measured with a real finger held mid-drag
while a `CADisplayLink` recorded both positions per frame: the same drag moved the
keyboard across 0 frames without it and 17 with it.

That measurement also settled the risk the whole pass hung on. The long-standing SwiftUI
report — a `safeAreaInset` bar stays put through an interactive dismissal and snaps at the
end — **does not reproduce on iOS 26.0**: across 69 consecutive frames the composer-to-
keyboard gap held at exactly 112.0pt, with the drawn position trailing the laid-out one by
a single frame rather than by an animation.

One requirement remains structurally out of reach, and is recorded so it is not
re-attempted blind: **a drag that begins on the composer cannot drive the dismissal.**
`safeAreaBar` makes the bar a *sibling* of the scroll view, so the touch is never delivered
to the list's pan, and UIKit's interactive dismissal is driven by that pan alone with no
public way to hand it a foreign gesture. Making the bar's dead space hit-transparent was
tried twice, including moving its glass into a non-hit-testing background; neither got the
touch through, and success would drop taps onto the message rows behind the bar. The only
shipped implementation is Telegram's, which moves the keyboard's own window through private
API.

Two harness notes for whoever measures next. `app.scrollViews.firstMatch` in XCUITest
resolves to the **keyboard's own 44pt candidate strip**, not the message list — take
coordinates from the window. And a `keyboardLayoutGuide` is clamped to its owning view's
bounds, so asking a small probe view reports that view's own edge as the keyboard's; ask
the window's root view. The full recipe is in `GUIDES/IOS_KEYBOARD_SCROLL_VERIFICATION.md`
in the maintainer's workspace.
