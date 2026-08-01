import Foundation

/// Whether a store file must be wiped for an identity to take it over.
///
/// # This used to be a fact about the device and is now a fact about one community
///
/// With one store there was one owner, kept in `UserDefaults`, and a login by a different
/// key wiped it. With a store file per community (§ ``Community``) the same question has to
/// be asked once per file: "a different key signed in" is true of the community that was
/// re-paired and false of every other one on the phone, and answering it globally would
/// wipe histories the incoming key never touched.
///
/// So the *storage* of the owner moved onto the record that names the store file
/// (``Community/ownerPubkeyHex``), and what is left here is the rule itself — a pure
/// function — and ``legacyOwnerPubkeyHex``, which exists only to carry the old global
/// answer into the record of the install being adopted.
enum StoreOwnership {
    /// Whether the store must be wiped for `incoming` to take over data recorded as
    /// belonging to `recordedOwner`: true only when a *different* identity already owns it.
    /// A community with nothing stored yet, and a same-key re-pairing, both keep what is
    /// there.
    static func shouldWipe(recordedOwner: String?, incoming: String) -> Bool {
        guard let recordedOwner else { return false }
        return recordedOwner != incoming
    }

    /// The owner the single-community app recorded, read once when that install is adopted
    /// as community #1 (``CommunityStorage/loadAdoptingLegacyInstall(hasLegacyIdentity:)``).
    ///
    /// Not cleared afterwards: it is a public key, it costs nothing to leave, and clearing
    /// it is a write that can fail in the middle of a migration whose whole point is that
    /// it cannot half-happen.
    static var legacyOwnerPubkeyHex: String? {
        UserDefaults.standard.string(forKey: "store.ownerPubkey")
    }
}
