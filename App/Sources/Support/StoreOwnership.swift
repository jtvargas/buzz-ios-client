import Foundation

/// Records which identity the on-disk store currently holds data for, so a login
/// can decide whether to keep the store (same key returning) or wipe it (a
/// different key taking over the device).
///
/// The owner is a public key — not a secret — so `UserDefaults` is the right home,
/// the same place the relay URL lives. It is set on every successful engine start
/// and deliberately left untouched by sign-out, which is what lets a same-key
/// re-login keep its history.
enum StoreOwnership {
    private static let storageKey = "store.ownerPubkey"

    /// The hex pubkey whose data the store currently holds, or `nil` on a fresh
    /// install.
    static var ownerPubkeyHex: String? {
        get { UserDefaults.standard.string(forKey: storageKey) }
        set { UserDefaults.standard.set(newValue, forKey: storageKey) }
    }

    /// Whether the store must be wiped for `incomingPubkey` to take over the device:
    /// true only when a *different* identity already owns the store's data. A fresh
    /// install (no owner) and a same-key re-login both keep the store.
    static func shouldWipe(forIncoming incomingPubkey: String) -> Bool {
        guard let owner = ownerPubkeyHex else { return false }
        return owner != incomingPubkey
    }
}
