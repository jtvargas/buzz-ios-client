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

- The app requests iOS 26 `BGContinuedProcessingTask` runtime with an immediate-fail
  strategy. Each request has its own identifier and handler. The system progress
  describes elapsed time in the monitoring window, never agent task completion.
- Only a granted session retains the existing SyncEngine relay connection while
  backgrounded. Human presence still follows the real scene lifecycle. Releasing
  the session restores the existing background connection policy. The monitoring
  tick resumes a connection if an already-started background suspension finishes late.
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
2. Enable it while Hive is foregrounded. Check the status, custom card, and any
   system progress card. Start agents in different joined channels and threads.
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

## References

- [Apple: Performing long-running tasks](https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados)
- [Apple: BGContinuedProcessingTask](https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtask)
- [Apple: Live Activity presentation and limits](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities)
- [Apple DTS: continued-processing use cases](https://developer.apple.com/forums/thread/840384)
- [Apple DTS: networking and suspension](https://developer.apple.com/forums/thread/799259)
