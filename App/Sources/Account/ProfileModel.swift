import BuzzKit
import Foundation
import NostrCore
import Observation

/// Drives the profile editor: it seeds the display-name, about and avatar fields from the
/// live `profile` projection, and publishes edits as a kind-0 metadata event through the
/// durable outbox (``MessageSending``), preserving any NIP-05/LUD-16 fields the projection
/// already holds so a name edit does not drop them.
@MainActor
@Observable
final class ProfileModel {
    var draftDisplayName = ""
    var draftAbout = ""

    /// The avatar's `picture` value — an uploaded URL or an inline emoji document.
    ///
    /// Not a text field, so unlike the two drafts above it is never mid-edit: the avatar
    /// editor hands over a finished value and it is published immediately. It lives here
    /// rather than in that editor because it is one field of one event, and a save that
    /// wrote the avatar without the name (or the reverse) would clear the other.
    private(set) var draftPicture: String?

    /// The identity's `npub`, shown for copy. Derived once and stable.
    let npub: String
    /// The identity's hex public key — the spelling Buzz's own profile screen shows.
    let pubkeyHex: String

    private(set) var hasLoaded = false
    private(set) var isSaving = false
    private(set) var didSave = false
    private(set) var saveError: String?

    /// The handle the projection holds, shown read-only: it is issued rather than chosen,
    /// so the screen reports it and offers nothing to type.
    private(set) var nip05: String?

    private let store: BuzzEventStore
    private let selfPubkey: String
    private let sender: any MessageSending
    private var currentProfile: ProfileRow?

    init(store: BuzzEventStore, selfPubkey: String, sender: any MessageSending) {
        self.store = store
        self.selfPubkey = selfPubkey
        self.sender = sender
        pubkeyHex = selfPubkey
        npub = PublicKey(hex: selfPubkey)?.npub ?? selfPubkey
    }

    /// Observes the store and seeds the draft fields once, so later echoes (this
    /// device's own save, or another device's edit) refresh the preserved fields
    /// without clobbering what the user is typing.
    nonisolated func run() async {
        do {
            for try await _ in DatabaseSignal.changes(in: store.reader) {
                let row = try? store.profile(pubkey: selfPubkey)
                await apply(row)
            }
        } catch {
            // The stream ends on cancellation or teardown; the last state stays.
        }
    }

    private func apply(_ row: ProfileRow?) {
        currentProfile = row
        nip05 = row?.nip05
        if !hasLoaded {
            draftDisplayName = row?.displayName ?? ""
            draftAbout = row?.about ?? ""
            draftPicture = row?.picture
            hasLoaded = true
        }
    }

    // MARK: - Reading

    /// What is published right now, for the rows that are read-only until Edit is tapped.
    var publishedDisplayName: String? { currentProfile?.displayName?.trimmedNonEmpty }
    var publishedAbout: String? { currentProfile?.about?.trimmedNonEmpty }

    // MARK: - Editing

    /// Puts the text fields back to what was last published, for a cancelled edit.
    func revertTextEdits() {
        draftDisplayName = currentProfile?.displayName ?? ""
        draftAbout = currentProfile?.about ?? ""
        saveError = nil
    }

    /// Whether either text field differs from what is published, so an Edit that changed
    /// nothing does not publish an event.
    var hasUnsavedTextEdits: Bool {
        draftDisplayName.trimmedNonEmpty != publishedDisplayName
            || draftAbout.trimmedNonEmpty != publishedAbout
    }

    /// Takes a new avatar from the editor and publishes it straight away.
    ///
    /// Immediate rather than staged behind a Save, because the editor's own Done is the
    /// decision — a picture chosen, previewed and confirmed that then needed a second
    /// confirmation on the screen behind it is where an avatar silently fails to change.
    func updateAvatar(_ picture: String) async {
        draftPicture = picture
        await save()
    }

    /// Publishes the edited profile as a kind-0 event through the outbox.
    func save() async {
        isSaving = true
        didSave = false
        saveError = nil

        let content = ProfileMetadataContent(
            name: draftDisplayName.trimmedNonEmpty,
            displayName: draftDisplayName.trimmedNonEmpty,
            about: draftAbout.trimmedNonEmpty,
            picture: draftPicture,
            nip05: currentProfile?.nip05,
            lud16: currentProfile?.lud16
        )

        do {
            _ = try await sender.enqueue(
                kind: .metadata,
                content: content.jsonString(),
                in: "",
                tags: [],
                maxContentBytes: OutboxPolicy.maxContentBytes
            )
            didSave = true
        } catch {
            saveError = "Couldn't save your profile. Please try again."
        }
        isSaving = false
    }
}

/// The kind-0 profile JSON. Both `name` and `display_name` are written (the former
/// for older clients and relays, the latter the field the Buzz projector prefers),
/// and existing avatar/handle fields are carried through unchanged. Empty fields
/// are omitted rather than written as empty strings.
struct ProfileMetadataContent: Encodable {
    let name: String?
    let displayName: String?
    let about: String?
    let picture: String?
    let nip05: String?
    let lud16: String?

    private enum CodingKeys: String, CodingKey {
        case name, about, picture, nip05, lud16
        case displayName = "display_name"
    }

    func jsonString() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self), let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }
}

private extension String {
    /// The trimmed value, or `nil` when it is empty — so a blank field clears rather
    /// than persists as `""`.
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
