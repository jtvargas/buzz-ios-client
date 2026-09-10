# ADR-0005: Experimental agent Live Activity monitoring

**Status:** Proposed — device prototype, disabled by default

## Context

Hive can receive agents' kind-20002 activity heartbeats through its existing relay
connection. The requested prototype makes that activity visible on the Lock Screen
without an APNs service. An app left in the app switcher can still be suspended;
keeping an object or WebSocket allocated does not provide background execution.

## Decision

Settings → Live agent activity → **Experimental** opts into a finite, 30-minute
monitoring session. Start/Stop controls allow another session without changing the
preference. A subsequent foreground app launch or community switch can start a new
session while the preference remains enabled. A stopped or interrupted session is
not automatically restarted on each foreground transition within the same session.

- Foreground monitoring starts independently of iOS 26 `BGContinuedProcessingTask`.
  The app requests background runtime with an immediate-fail strategy after a
  one-second foreground settling delay when the session starts from Settings.
  Sending to a verified agent DM or mentioning an agent submits immediately from
  the composer action, before card setup or asynchronous enqueue. This also starts
  a new session if the previous one ended and Experimental remains enabled. Empty
  or attaching drafts do not trigger it. The sender must belong to the mounted
  engine; ordinary human messages and received heartbeats never trigger requests.
  A direct send replaces a pending Settings attempt; rapid sends share a direct
  attempt for five seconds. A missing callback gets one retry after
  two seconds, with a fresh identifier and a five-second callback deadline for each
  attempt. Exhausting those attempts leaves foreground monitoring running. Settings
  offers an explicit retry. The system progress describes elapsed time in the
  monitoring window, never agent task completion.
- A real continued-processing grant or a live UIKit background assertion retains
  the existing SyncEngine relay connection while backgrounded. Human presence still
  follows the real scene lifecycle. Releasing
  the session restores the existing background connection policy. The monitoring
  tick resumes a connection if an already-started background suspension finishes late.
- Each foreground request can acquire a single named `UIApplication` background
  assertion for a brief handoff. The app and card label this Brief background
  window, separately from a continued-processing grant. It ends at twenty seconds
  after backgrounding or earlier on iOS expiration, foreground return, grant,
  or session cleanup. Background events never renew it. It does not promise twenty
  seconds of execution or extend iOS's shared background budget.
- Locking preserves a request already submitted in the foreground, until its
  callback deadline. A retry not yet submitted is never submitted from the
  background. Without either execution mechanism the roster clears and the card
  publishes Paused; in-flight reads cannot overwrite that state. Foreground
  monitoring resumes on return within the same monitoring window. A callback from
  a cancelled or replaced request is completed without adopting it.
- BuzzKit exposes a fresh in-memory activity snapshot. The monitor filters verified
  agent identities, excludes self, and preserves channel/thread scopes. It uses the
  same subscriptions as Hive: joined channels plus any active conversation, within
  the mounted community. Reconnect subscription rearming can leave temporary gaps;
  this is not a relay-wide task inventory.
- The app checks activity every two seconds and refreshes the custom ActivityKit
  content at least every four seconds while it executes. Every update sets a stale
  date twelve seconds ahead. Existing heartbeat TTL and disconnect clearing remain
  authoritative for the roster. Connection loss shows Reconnecting; stale content
  shows Paused instead of a working count.
- Metadata refreshes at most every fifteen seconds on the concurrent executor,
  using directory and channel metadata reads without timeline or unread queries.
  `EntityNames` resolves people, agents, channels, and DMs consistently with the app.
- A separate WidgetKit extension renders only the supplied ActivityKit state. It
  owns no socket, credentials, database, APNs token, or app-group storage. The shared
  Codable contract contains at most three distinct agents; bounded content leaves
  room under ActivityKit's 4 KB payload budget. Accessibility sizes show one row.
- The card counts each agent once. Its full in-app roster lists all received scopes.
  Rows open the existing channel/thread route; the header and overflow open the
  roster. Community identifiers prevent an old card from opening the same channel
  identifier in a different community. Thread labels currently show the parent
  conversation plus “Thread”; the deep link contains the exact root event ID.
- Toggle-off, logout, community teardown, and card dismissal clean up the session.
  Expiration leaves a paused summary with a short dismissal policy when execution
  permits. Startup removes orphaned cards left by a previous process.

## Rationale

An explicit monitoring window provides a concrete user task and truthful duration
for evaluating continued-processing runtime. Reusing the mounted engine avoids a
second subscription graph or copying credentials into an extension. Existing
heartbeat semantics provide working presence, not a trustworthy success signal;
silence therefore never becomes “Done.”

## Consequences and limits

This remains a prototype until physical-device use establishes practical runtime,
battery cost, lock-screen presentation, and reconnect behavior. No sustained
background-runtime guarantee or App Review approval is implied. iOS may refuse or
interrupt a request. The system may show its own progress Live Activity alongside
Hive's custom card; the public task API does not expose a replacement for that UI.

Force-quitting stops the app's monitoring execution, but does **not** guarantee an
immediate custom-card dismissal or a final callback. The card uses ActivityKit's
stale-state rendering and is reclaimed on next launch. A stale date is not a
programmatic dismissal deadline. Updates and stale rendering are system-managed.

The card exposes agent names and conversation labels on the Lock Screen. Opt-in UI
states this. No message bodies are included. No separate observer/completion event
protocol is implemented; activity stopping can mean success, cancellation, failure,
or lost connectivity.

## Physical-device review

No test cases or simulator runs are part of this prototype, at the owner's request.
Build and install the signed app and extension; the owner performs runtime review:

1. Leave Experimental off and confirm ordinary app use is unchanged.
2. Enable it while Hive is foregrounded. Agent updates must start without waiting
   for extended execution. Check Brief background window, Foreground only, and Background monitoring active
   in Settings and start agents in different joined channels and threads. If both
   background attempts time out, foreground monitoring must remain running.
3. Lock the phone and use another app. Compare the count and roster with actual
   agent activity, including an agent working in more than one conversation.
4. Let agents stop. Their heartbeat presence should expire; no success is inferred.
5. Tap an agent, the header, and the overflow. Check exact conversation routing,
   including when Settings was open before locking the phone.
6. Disconnect/reconnect the network. Expect Reconnecting or Paused until current
   activity is received; check that the roster recovers after subscriptions rearm.
7. Try Stop, rapid off/on, system-task cancellation, community switching, and signout.
   Disabling must end monitoring and dismiss the custom card.
8. Force-quit while agents are active. The remaining custom card should become stale
   rather than promise continued monitoring. Reopen Hive to reclaim the old card.
9. Let a session reach thirty minutes. Start another in Settings. Repeat under Low
   Power Mode and with larger accessibility text to evaluate system limits/layout.
10. Send to an agent DM or mention an agent in a channel/thread, then lock promptly:
    a live UIKit assertion permits brief updates without cancelling the pending
    continued-processing request. Without a continued-processing grant, expect
    Paused at twenty seconds or earlier on iOS expiration. Reopen Hive: updates
    resume. Retry background monitoring explicitly; only an actual launch callback
    changes the capability to Background monitoring active. Stop or toggle off
    during either attempt; no late callback may revive the session. Human sends
    and remote agent heartbeats must not create more background assertions.

## Amendment (2026-09-10): missing background launch callback

Device logs from iPhone JT on iOS 26.6.1 showed four submissions followed by the
scheduler message `Foregrounded apps (...) don't include expected identifier`.
No launch callback or submission error reached Hive; the original ten-second
watchdog then cancelled each session. This matches the platform failure described
in [Apple DTS's background-task discussion](https://developer.apple.com/forums/thread/807370).

The confirmed client defect was making all foreground monitoring depend on that
callback. The monitor now starts independently and treats background execution as
an optional capability. Delayed submission and one retry may help transient system
state; they do not bypass an iOS refusal or prove that background delivery works on
this device. Sparse runtime logs record submissions, missing callbacks, errors, and
actual grants without agent or conversation data.

The follow-up couples new attempts to the user's actual agent-send action and
preserves an in-flight request across locking. A separate, bounded UIKit assertion
provides short handoff execution while the continued-processing result is unknown
or unavailable. It is released synchronously on expiration, is never renewed by a
timer, and is distinct in both UI and relay ownership from a long-running grant.

## References

- [Apple: Performing long-running tasks](https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados)
- [Apple: BGContinuedProcessingTask](https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtask)
- [Apple: UIApplication background task lifetime](https://developer.apple.com/forums/thread/85066)
- [Apple: Live Activity presentation and limits](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities)
- [Apple DTS: continued-processing use cases](https://developer.apple.com/forums/thread/840384)
- [Apple DTS: networking and suspension](https://developer.apple.com/forums/thread/799259)
