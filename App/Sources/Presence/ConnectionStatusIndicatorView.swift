import BuzzKit
import SwiftUI

/// "Reconnecting…" over a conversation, in the same capsule the typing strip uses.
///
/// # Why a conversation needs one at all
///
/// The connection state is drawn in exactly one place: the dot on your face, on the
/// home screen. A reader inside a channel or a thread — where the app is *used*, and
/// where a stalled connection looks precisely like a quiet room — had no signal at
/// all. This is that signal, at the one moment it is worth interrupting for: the
/// connection is not live *now*.
///
/// # Why it is debounced
///
/// A reconnect that lands in under a second is not news, and a banner that appears and
/// vanishes over a conversation is worse than no banner: it draws the eye to something
/// that has already resolved. So the word waits ``settleDelay`` before it is shown at
/// all, and a state that recovers inside that window never draws anything. Recovery in
/// the other direction is immediate — going live is news you want at once.
///
/// # Why it does not move the conversation
///
/// It is an accessory, drawn in the ``ConversationScaffold`` stack over the list rather
/// than in the bar beneath it. That bar's height *is* the list's bottom inset, so a
/// strip that appeared there would re-inset the conversation and move the reader's
/// place — for an event they did not cause. The typing strip was moved out for exactly
/// this reason; this rides in the slot beside it for exactly the same one.
struct ConnectionStatusIndicatorView: View {
    /// Optional, and deliberately so. The conversation surfaces are also driven by
    /// ``ConversationFixtureHost`` — the UI-test fixture the scroll shape gate measures —
    /// which composes them from named collaborators and injects no app environment at
    /// all. A non-optional read would trap the instant that host launched, a crash no
    /// unit test could see because none of them render this. With no environment there is
    /// no engine, and a surface with no engine has nothing to report.
    @Environment(AppEnvironment.self) private var environment: AppEnvironment?

    /// The word currently on screen, `nil` for a healthy connection. Settled by the
    /// task below rather than read straight from the engine, which is the debounce.
    @State private var shown: String?

    var body: some View {
        Group {
            if let shown {
                ConversationAccessoryCapsule(label: shown) {
                    TypingDots()
                }
            }
        }
        .animation(.default, value: shown)
        // Restarted — and the previous run cancelled — on every engine transition, so a
        // state that resolves inside the delay takes its pending word with it.
        .task(id: environment?.engineState) {
            guard let environment else { return }
            await settle(on: environment.engineState, hasConnectedBefore: environment.hasConnectedBefore)
        }
    }

    private func settle(on state: SyncEngine.State, hasConnectedBefore: Bool) async {
        guard let pending = Self.message(for: state, hasConnectedBefore: hasConnectedBefore) else {
            shown = nil // live again: no delay, and nothing to say
            return
        }
        // Only wait when there is nothing up yet. Once the capsule is on screen, a
        // move between two unhealthy states should change its word immediately rather
        // than blank it for another second.
        if shown == nil {
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled else { return }
        }
        shown = pending
    }

    /// The word for an engine state, or `nil` when there is nothing worth saying.
    ///
    /// ``SyncEngine/State/suspended`` is deliberately silent: it means the app was
    /// backgrounded and the socket deliberately released, so there is nobody reading
    /// this screen — and by the time there is, the resume has already moved it on.
    static func message(for state: SyncEngine.State, hasConnectedBefore: Bool) -> String? {
        switch state {
        case .running, .suspended:
            nil
        case .starting:
            // The engine cannot tell these apart — both are `.starting` — but a reader
            // very much can: one is the app opening, the other is the app it was
            // already using going quiet.
            hasConnectedBefore ? "Reconnecting…" : "Connecting…"
        case .stopped:
            "Offline"
        }
    }

    /// How long an unhealthy state must persist before it is worth a word. Long enough
    /// that an ordinary reconnect — a foreground probe finding a dead socket, a backoff
    /// of one second — passes in silence.
    static let settleDelay: Duration = .seconds(1)
}
