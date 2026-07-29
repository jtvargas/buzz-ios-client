import Foundation
import NostrCore
import os

// MARK: - Errors

/// Why creating a channel failed.
///
/// A closed set rather than a message string, for the same reason
/// ``DirectMessageError`` is one: a sheet can tell "you have not typed a name yet"
/// (fix the input, stay open) from "this deployment refused you" (nothing to retry)
/// without matching on prose.
public enum ChannelCreationError: Error, Equatable, Sendable {
    /// The name was empty once its leading `#` and surrounding whitespace came off.
    /// Caught before the wire; the relay would only answer
    /// `invalid: channel name is required`.
    case emptyName
    /// The relay refused the create, carrying its classified reason. Terminal:
    /// `invalid:` (a name, visibility or type it will not take), `restricted:` (the
    /// deployment's membership gate), `rate-limited:`, or an `error:`. Resending the
    /// same event earns the same answer, and resending a *different* one would make a
    /// second channel — see the retry note on ``SyncEngine/createChannel(name:about:isPrivate:)``.
    case rejected(OKReason)
    /// The create never reached a verdict: no authenticated socket, a drop mid-flight,
    /// or a watchdog timeout. The channel may or may not exist; the caller has not
    /// been told which.
    case publishFailed(RelayConnectionError)
}

// MARK: - Public surface

/// Creating a channel: one NIP-29 create-group event, whose id the **client** mints.
///
/// # Why there is no read-back of an id
///
/// Unlike opening a DM (kind 41010), where the relay decides the channel id and hands
/// it back in the `OK` payload, a create carries the id it wants in its `h` tag and the
/// relay commits the channel under exactly that value. So the caller knows where it is
/// navigating before the event is even signed, and the only thing the answer adds is
/// whether the commit happened.
///
/// # Why this does not retry the way the DM open does
///
/// ``SyncEngine/openDirectMessage(with:)`` retries an `error:` once, because that error
/// is what a two-device race on the *same* DM looks like and the retry finds the row the
/// winner committed. A create has no such fixed point: the relay is idempotent on a DM's
/// participant set, and on nothing at all here. A blind resend after an ambiguous failure
/// would not find the first channel — it would manufacture a second one and leave the
/// first orphaned, with a name in the sidebar and nobody in it. One attempt, and an
/// honest error, is the only shape that cannot silently double.
public extension SyncEngine {
    /// Creates a channel and returns its id — what a UI navigates to.
    ///
    /// - Parameters:
    ///   - name: The channel's name as typed. A leading `#` and surrounding whitespace
    ///     are stripped (what the relay itself does); nothing else is rewritten, so a
    ///     name made here reads the same on Desktop as it does on the phone.
    ///   - about: The description, or `nil`/blank for none.
    ///   - isPrivate: `true` publishes `visibility: private` — hidden from the channel
    ///     directory and unjoinable without an invite. `false` is `open`.
    /// - Returns: The new channel's id. By the time this returns, the channel's
    ///   relay-signed state has been read back and ingested and its live subscription is
    ///   open, so the channel exists locally.
    @discardableResult
    func createChannel(name: String, about: String?, isPrivate: Bool) async throws -> String {
        let canonicalName = Self.canonicalChannelName(name)
        guard !canonicalName.isEmpty else { throw ChannelCreationError.emptyName }

        let channelID = UUID().uuidString.lowercased()
        let event = try await signCreateChannel(
            channelID: channelID,
            name: canonicalName,
            about: about,
            isPrivate: isPrivate
        )

        do {
            let message = try await connection.publishAwaitingResponse(event)
            Self.channelCreationLog.notice(
                """
                Created channel \(channelID, privacy: .public) \
                (relay said: \(message, privacy: .public))
                """
            )
        } catch RelayConnectionError.publishRejected(let reason) {
            throw ChannelCreationError.rejected(reason)
        } catch let error as RelayConnectionError {
            throw ChannelCreationError.publishFailed(error)
        }

        await adoptOpenedChannel(channelID)
        return channelID
    }
}

// MARK: - The event

extension SyncEngine {
    /// Logger for the create. Its own category so a refused create is legible in a
    /// session log — the verdict rides in an `OK` message and is never an event, so
    /// nothing else records it.
    static let channelCreationLog = Logger(subsystem: "BuzzKit", category: "SyncEngine.channelCreation")

    /// The `channel_type` this client creates. `stream` is the ordinary conversational
    /// channel and the relay's own default; `forum` is a different surface this app does
    /// not have, and `dm` is made by the DM command rather than by a create.
    static let conversationalChannelType = "stream"

    /// Signs the create-group event.
    ///
    /// The tags are the relay's contract for kind 9007 and are read positionally by
    /// nothing — each is found by name — but all four of the required ones must be
    /// present in the form the relay's enums parse: `visibility` is `open` or `private`,
    /// `channel_type` is one of its channel kinds. `about` is omitted rather than sent
    /// empty, because an empty description and no description are the same thing and
    /// only one of them is a tag.
    ///
    /// No `nonce` tag, unlike the DM open: the `h` tag is already a fresh UUID per call,
    /// so two creates can never hash to one event id even inside a single wall-clock
    /// second.
    ///
    /// Stamped from the engine's injected clock, which the relay's ingest gate requires
    /// to sit within ±15 minutes of its own time.
    private func signCreateChannel(
        channelID: String,
        name: String,
        about: String?,
        isPrivate: Bool
    ) async throws -> NostrEvent {
        try await signer.sign(
            kind: .groupCreate,
            content: "",
            tags: Self.channelCreateTags(
                channelID: channelID,
                name: name,
                about: about,
                isPrivate: isPrivate
            ),
            createdAt: now()
        )
    }
}

// MARK: - Pure helpers

public extension SyncEngine {
    /// A channel name as the relay stores it.
    ///
    /// The same two edits `buzz_core::channel::canonical_channel_name` makes: any leading
    /// `#` and whitespace come off, and trailing whitespace goes. Nothing is lowercased
    /// and no space becomes a hyphen — a name is stored as typed, so `Release Notes`
    /// stays `Release Notes` on every client reading the same relay.
    ///
    /// Applied here as well as server-side so the sheet can refuse an empty name without
    /// a round trip, and so what the caller navigates to is named what it will be named.
    static func canonicalChannelName(_ raw: String) -> String {
        var name = raw.drop { $0 == "#" || $0.isWhitespace }
        while let last = name.last, last.isWhitespace { name = name.dropLast() }
        return String(name)
    }

    /// The tags a create-group event carries, built as a value so the wire shape is
    /// asserted rather than eyeballed against a relay.
    ///
    /// `name` is expected to be canonical already — this does not re-run
    /// ``canonicalChannelName(_:)``, because the caller navigates to the name it passed
    /// and a second, different normalisation here is exactly how those two drift apart.
    static func channelCreateTags(
        channelID: String,
        name: String,
        about: String?,
        isPrivate: Bool
    ) -> [[String]] {
        var tags = [
            ["h", channelID],
            ["name", name],
            ["visibility", isPrivate ? "private" : "open"],
            ["channel_type", conversationalChannelType],
        ]
        let description = about?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !description.isEmpty { tags.append(["about", description]) }
        return tags
    }
}
