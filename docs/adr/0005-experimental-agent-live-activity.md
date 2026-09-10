# ADR-0005: Experimental agent Live Activity monitoring

**Status:** Proposed — device prototype, disabled by default

## Context

Hive can receive agents' kind-20002 activity heartbeats through its existing relay
connection. The requested prototype makes that activity visible on the Lock Screen
without an APNs service. An app left in the app switcher can still be suspended;
keeping an object or WebSocket allocated does not provide background execution.

## Decision

Settings → Live agent activity → **Experimental** arms a foreground listener only.
Enabling, launching Hive, returning to the foreground, and sending a message do not
create a Live Activity or request background runtime. A fresh kind-20002 heartbeat
from a known agent, received while Hive is open, starts a finite, 30-minute session.
The first card already contains the confirmed working roster. The trigger uses the
same activity records and agent classification as the in-app working indicator;
there is no inference of work from an outgoing message, online presence, or history.

Stop ends the session; **Enable next activity** in Settings rearms the listener
without creating a card. Stopped, dismissed, failed, or expired sessions do not
restart on each heartbeat or foreground transition. A subsequent app launch or
community switch can arm a new listener while the preference remains enabled.

- Foreground monitoring starts independently of iOS 26 `BGContinuedProcessingTask`.
  After confirming actual agent work, the app requests background runtime with an
  immediate-fail strategy before asynchronous card setup. The trigger listener then
  detaches. The monitoring tick requests background execution automatically when
  a fresh agent heartbeat arrives after a real background-to-foreground return.
  Repeated foreground failures back off for 30, 60, then 120 seconds between request
  cycles; subsequent cycles stay at 120 seconds and require current agent activity.
  Requests never replace one already pending or active. Each missing callback gets one retry after
  two seconds, with a fresh identifier and a five-second callback deadline for each
  attempt. Exhausting those attempts leaves foreground monitoring running. No
  Settings retry button is required. The system progress describes elapsed time in the
  monitoring window, never agent task completion.
- A real continued-processing grant or a live UIKit background assertion retains
  the existing SyncEngine relay connection while backgrounded. Human presence still
  follows the real scene lifecycle. Releasing
  the session restores the existing background connection policy. The monitoring
  tick resumes a connection if an already-started background suspension finishes late.
- Each foreground request can acquire a single named `UIApplication` background
  assertion for a brief handoff. The app and card label this Brief background
  window, separately from a continued-processing grant. It lasts until iOS calls
  its expiration handler, foreground return, a continued-processing grant, or
  session cleanup. There is no twenty-second client cutoff and no deadline based
  on `backgroundTimeRemaining`. Background events never renew the assertion. Its
  lifetime remains finite and does not extend iOS's shared background budget.
- Locking preserves a request already submitted in the foreground, until its
  callback deadline. A retry not yet submitted is never submitted from the
  background. Without either execution mechanism the roster clears and the card
  publishes Paused; in-flight reads cannot overwrite that state. Foreground
  monitoring resumes on return within the same monitoring window. A callback from
  a cancelled or replaced request is completed without adopting it.
- Expiration of a granted continued-processing task releases that runtime but
  preserves the custom activity and monitoring session. Because system-card
  cancellation can use the same expiration callback, recovery waits for the next
  real foreground visit and a fresh working heartbeat. Explicit Stop, toggle-off,
  custom-card dismissal, and the 30-minute session limit still end the session.
- BuzzKit exposes a fresh in-memory activity snapshot plus a bounded, unseeded
  notification stream for newly accepted typing heartbeats. Idle opt-in has no
  polling loop, card, background assertion, or additional relay subscription.
  Receipt times exclude signals from before opt-in or the latest foreground return.
  Freshness and foreground state are checked again after asynchronous reads;
  toggle-off and community teardown cancel any trigger in flight.
  The monitor filters verified
  agent identities, excludes self, and preserves channel/thread scopes. It uses the
  same subscriptions as Hive: joined channels plus any active conversation, within
  the mounted community. Reconnect subscription rearming can leave temporary gaps;
  this is not a relay-wide task inventory.
- The app checks activity every two seconds and refreshes the custom ActivityKit
  content at least every four seconds while it executes. Every update sets a stale
  date twelve seconds ahead. Existing heartbeat TTL and disconnect clearing remain
  authoritative for the roster. Connection loss shows Reconnecting; stale content
  shows Paused instead of a working count.
- The existing relay connection already probes foreground liveness with a bounded
  ping and runs an idle watchdog with ping/pong and reconnect handling. Additional
  pings cannot establish agent work or grant background execution. The agent's
  own fresh kind-20002 heartbeat remains the source for its working indicator.
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

A relay-confirmed working indicator starts a bounded monitoring window instead of
an idle card created by the opt-in toggle. Reusing the mounted engine avoids a
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
2. Enable it while Hive is foregrounded: Settings must say it is waiting for an
   agent, with no Live Activity or background-runtime request. Send to an agent:
   sending alone must not create a card. Wait for its working indicator while Hive
   remains open; the first card must show that agent and the correct conversation.
   Check that human typing and online presence do not trigger it. Start other agents
   in joined channels/threads: they must join the existing card, not create new ones.
   If both background attempts time out, foreground monitoring must remain running.
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
9. Let a session reach thirty minutes. Use Enable next activity in Settings, then
   wait for a fresh agent working indicator. Repeat under Low
   Power Mode and with larger accessibility text to evaluate system limits/layout.
10. Send to an agent DM or mention an agent in a channel/thread. Wait for the
    working indicator and Live Activity while Hive is open, then lock:
    a live UIKit assertion permits brief updates without cancelling the pending
    continued-processing request. Without a continued-processing grant, expect
    Paused when iOS expires the brief assertion; there must be no client cutoff at
    twenty seconds. Reopen Hive and wait for fresh agent work: background monitoring
    must retry automatically without visiting Settings. Repeated foreground failures
    must back off, with no submissions while backgrounded or when no agent is working.
    Only an actual launch callback
    changes the capability to Background monitoring active. Stop or toggle off
    during either attempt; no late callback may revive the session. Subsequent
    background heartbeats must not create more assertions. If the phone is locked
    before the first working heartbeat, no new Live Activity should start there;
    return to Hive and wait for a fresh heartbeat.

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

The latest follow-up replaces the earlier toggle/send triggers with a fresh relay
working indicator received in the foreground. It preserves an in-flight request
across locking. A separate, bounded UIKit assertion
provides short handoff execution while the continued-processing result is unknown
or unavailable. It is released synchronously on expiration, is never renewed by a
timer, and is distinct in both UI and relay ownership from a long-running grant.
Changing the trigger does not establish that iOS will launch the longer background
task; the observed scheduler foreground-recognition failure remains unresolved.

Later device feedback exposed a missing foreground retry: the roster resumed, but
the runtime request only ran at initial startup or through the Settings button.
Foreground recovery now waits for current relay-confirmed work and retries with
backoff. The brief assertion also uses iOS's actual expiration instead of the
client's twenty-second timer. Fresh logs still showed the scheduler's foreground
recognition failure; these changes do not demonstrate sustained background runtime.

## References

- [Apple: Performing long-running tasks](https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados)
- [Apple: BGContinuedProcessingTask](https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtask)
- [Apple: UIApplication background task lifetime](https://developer.apple.com/forums/thread/85066)
- [Apple: Live Activity presentation and limits](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities)
- [Apple DTS: continued-processing use cases](https://developer.apple.com/forums/thread/840384)
- [Apple DTS: networking and suspension](https://developer.apple.com/forums/thread/799259)
