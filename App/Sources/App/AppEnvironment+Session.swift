import BuzzKit
import Foundation
import NostrCore
import SwiftUI

/// What happens to a session that is already running: the app leaving the foreground, a
/// retry after the relay went quiet, the key being read out for a backup, and signing out.
///
/// Its own file because ``AppEnvironment`` builds sessions and this is everything that
/// happens *to* one — and because the composition root is long enough without it.
extension AppEnvironment {
    /// Signs out of every community on this device: each key is deleted and verified gone,
    /// the engine is stopped, and the app returns to onboarding.
    ///
    /// The keys are removed one per community, because that is how they are stored — a
    /// community signs with its own Keychain account (§ ``Community/keychainAccount``), and
    /// a sign-out that cleared only the active one would leave a recoverable `nsec` on the
    /// device for every other community. `.keyNotCleared` is returned if *any* key survived
    /// its delete.
    ///
    /// Unlike the single-community version this tears down even when a key survives. With
    /// one identity, refusing to tear down left the app exactly as it was; with several,
    /// some keys are already gone by then, so the running session is signing with an
    /// identity the reader has asked to remove. The reader is told the truth by the result
    /// and left on a clean screen rather than a half-live one.
    ///
    /// The community *records* and their databases are intentionally kept. That is the
    /// single-community rule carried forward — the recorded owner decides at the next
    /// sign-in (§ ``StoreOwnership``), so a same-key return keeps its history and a
    /// different key wipes it. Removing a community for good is a different action, and it
    /// says so: ``removeCommunity(_:)``.
    @discardableResult
    func signOut() async -> SignOutResult {
        var result = SignOutResult.signedOut
        for community in communities.communities {
            let custody = KeychainSigner(account: community.keychainAccount)
            if deleteAndVerifyKey(custody) == .keyNotCleared {
                result = .keyNotCleared
            }
        }
        await teardownSession()
        setPhase(.needsIdentity)
        if result == .keyNotCleared {
            // The sheet that asked for this went with the workspace, so the refusal is
            // reported at the app level or not at all.
            notice = AppNotice(
                title: "Couldn't remove a key",
                message: Self.keyNotClearedMessage
            )
        }
        return result
    }

    /// Recovery action shared by the fallback banner and empty state.
    func retryConnectionAndDirectory() async {
        await engine?.retryConnectionAndDirectory()
    }

    /// Loads the active community's secret key for a gated backup/reveal, or `nil` if none
    /// is stored. The caller must gate this behind device authentication and never persist
    /// or log the result — it is the one deliberate read-out boundary for the secret.
    func revealSecretKey() -> PrivateKey? {
        guard let signer else { return nil }
        return try? signer.loadPrivateKey()
    }

    /// Forwards a scene-phase change to the engine and drives the presence
    /// heartbeat, if an engine exists. A no-op before the engine is built (i.e. while
    /// the gate is up).
    ///
    /// On background the heartbeat publishes `"offline"` *before* the engine arms its
    /// grace window, so the departure goes out while the socket is still live; on
    /// foreground it forwards first, then resumes beating.
    func handleScenePhase(_ phase: ScenePhase) {
        // Unsent text first, and outside the engine guard: leaving the foreground is the
        // last moment this process is guaranteed to still be here. Usually there is
        // nothing outstanding — the write-through has normally already landed.
        if phase != .active {
            let drafts = self.drafts
            Task { await drafts?.flush() }
        }
        guard let engine else { return }
        let heartbeat = self.heartbeat
        Task {
            switch phase {
            case .active:
                await forwardScenePhase(phase, to: engine)
                heartbeat?.startForeground()
            case .background:
                await heartbeat?.stopBackground()
                await forwardScenePhase(phase, to: engine)
            case .inactive:
                await forwardScenePhase(phase, to: engine)
            @unknown default:
                break
            }
        }
    }

    /// Said when a Keychain delete would not take. Names what is still on the device and
    /// the one action that clears it, rather than apologising.
    static let keyNotClearedMessage =
        "Hive signed out, but one of your keys is still stored on this device. Signing out "
            + "again usually clears it; removing the community always does."
}
