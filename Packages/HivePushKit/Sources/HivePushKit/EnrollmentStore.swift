import Foundation

/// Persists the gateway enrollment state for a community in the App Group
/// container, so both the main app and the Notification Service Extension can
/// read it.
///
/// One JSON file per community, stored at
/// `<container>/PushEnrollments/<communityID>.json`. The same layout as
/// ``PushSnapshotStore`` — independent files, atomic writes, file protection
/// until first user authentication.
public struct EnrollmentStore: Sendable {
    private let containerURL: URL

    private static let directoryName = "PushEnrollments"
    private static let pendingDirectoryName = "PushPendingRevocations"
    private static let fileExtension = "json"

    /// Creates a store writing into the given container directory.
    public init(containerURL: URL) {
        self.containerURL = containerURL
    }

    /// Creates a store from an App Group, or `nil` when there is none.
    public init?(appGroup: AppGroup) {
        guard let url = appGroup.containerURL else { return nil }
        self.init(containerURL: url)
    }

    // MARK: - Read

    /// Loads the enrollment for a community, or `nil` if none exists.
    public func load(communityID: String) -> Enrollment? {
        let url = fileURL(for: communityID)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.decoder.decode(Enrollment.self, from: data)
    }

    /// Loads all enrollments in the store.
    public func loadAll() -> [Enrollment] {
        let directory = containerURL.appendingPathComponent(Self.directoryName)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return [] }
        return files.compactMap { url in
            guard url.pathExtension == Self.fileExtension,
                  let data = try? Data(contentsOf: url)
            else { return nil }
            return try? Self.decoder.decode(Enrollment.self, from: data)
        }
    }

    // MARK: - Write

    /// Persists an enrollment, creating the directory if needed.
    public func write(_ enrollment: Enrollment) throws {
        let directory = containerURL.appendingPathComponent(Self.directoryName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = fileURL(for: enrollment.communityID)
        let data = try Self.encoder.encode(enrollment)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    // MARK: - Remove

    /// Removes the enrollment for a community. Idempotent.
    public func remove(communityID: String) {
        let url = fileURL(for: communityID)
        try? FileManager.default.removeItem(at: url)
    }

    /// Removes all enrollments.
    public func removeAll() {
        let directory = containerURL.appendingPathComponent(Self.directoryName)
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Pending revocations

    /// Records an installation the gateway still considers live but this app
    /// no longer uses, together with the App Attest key that can revoke it.
    ///
    /// Written when ``EnrollmentDriver/revoke()`` cannot reach the gateway, or
    /// when a community is removed without a live session to revoke through.
    /// A later install against the same gateway that gets a 409 revokes every
    /// record here, then retries.
    public func savePendingRevocation(_ revocation: PendingRevocation) throws {
        let directory = containerURL.appendingPathComponent(Self.pendingDirectoryName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(revocation)
        try data.write(
            to: pendingFileURL(for: revocation.communityID),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }

    /// Moves a community's enrollment into the pending-revocation set. No-op
    /// when the community has no enrollment.
    ///
    /// The pending record is written durably *before* the enrollment is
    /// removed, so a failure or crash at any point leaves the credentials on
    /// disk in at least one of the two places. On error the enrollment is
    /// untouched.
    ///
    /// - Parameter gatewayURL: the gateway the installation lives on, used
    ///   only when the enrollment predates ``Enrollment/gatewayURL`` and does
    ///   not record one itself. With neither, throws
    ///   ``EnrollmentStoreError/gatewayUnknown`` rather than write a record
    ///   that could be replayed against the wrong gateway.
    public func demoteToPendingRevocation(communityID: String, gatewayURL: URL?) throws {
        guard let enrollment = load(communityID: communityID) else { return }
        guard let gatewayURL = enrollment.gatewayURL ?? gatewayURL else {
            throw EnrollmentStoreError.gatewayUnknown
        }
        try savePendingRevocation(PendingRevocation(enrollment: enrollment, gatewayURL: gatewayURL))
        remove(communityID: communityID)
    }

    /// Loads the pending revocation for a community, if any.
    public func loadPendingRevocation(communityID: String) -> PendingRevocation? {
        guard let data = try? Data(contentsOf: pendingFileURL(for: communityID)) else { return nil }
        return try? Self.decoder.decode(PendingRevocation.self, from: data)
    }

    /// Loads every pending revocation for one gateway. Installations are per
    /// device, not per community, so any of them can be the one blocking a
    /// new install there; records for other gateways are never returned,
    /// because a handle and key only mean something to the gateway that
    /// issued them.
    public func loadAllPendingRevocations(gatewayURL: URL) -> [PendingRevocation] {
        let directory = containerURL.appendingPathComponent(Self.pendingDirectoryName)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return [] }
        return files.compactMap { url in
            guard url.pathExtension == Self.fileExtension,
                  let data = try? Data(contentsOf: url),
                  let record = try? Self.decoder.decode(PendingRevocation.self, from: data),
                  record.gatewayURL == gatewayURL
            else { return nil }
            return record
        }
    }

    /// Removes a pending revocation. Idempotent.
    public func removePendingRevocation(communityID: String) {
        try? FileManager.default.removeItem(at: pendingFileURL(for: communityID))
    }

    // MARK: - Helpers

    private func fileURL(for communityID: String) -> URL {
        containerURL
            .appendingPathComponent(Self.directoryName)
            .appendingPathComponent(communityID)
            .appendingPathExtension(Self.fileExtension)
    }

    private func pendingFileURL(for communityID: String) -> URL {
        containerURL
            .appendingPathComponent(Self.pendingDirectoryName)
            .appendingPathComponent(communityID)
            .appendingPathExtension(Self.fileExtension)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

// MARK: - Enrollment record

/// The persisted result of a successful gateway enrollment: everything downstream
/// code needs to publish a lease and the NSE needs to know push is active.
public struct Enrollment: Codable, Equatable, Sendable {
    /// The community this enrollment belongs to.
    public let communityID: String
    /// The gateway installation handle.
    public let installationHandle: String
    /// The opaque sealed endpoint grant token for the relay.
    public let endpointGrant: String
    /// The App Attest key identifier, needed for assertion generation.
    public let attestKeyID: String
    /// A random UUID used as the `d` tag in the NIP-PL lease, so this device's
    /// lease is addressable independently.
    public let installID: String
    /// The relay URL this enrollment targets.
    public let relayURL: String
    /// The gateway that issued the installation. `nil` only for enrollments
    /// written before this field existed; the app supplies the community's
    /// gateway when it demotes those.
    public let gatewayURL: URL?
    /// When the enrollment was completed.
    public let enrolledAt: Date

    public init(
        communityID: String,
        installationHandle: String,
        endpointGrant: String,
        attestKeyID: String,
        installID: String,
        relayURL: String,
        gatewayURL: URL?,
        enrolledAt: Date = .now
    ) {
        self.communityID = communityID
        self.installationHandle = installationHandle
        self.endpointGrant = endpointGrant
        self.attestKeyID = attestKeyID
        self.installID = installID
        self.relayURL = relayURL
        self.gatewayURL = gatewayURL
        self.enrolledAt = enrolledAt
    }
}

// MARK: - Pending revocation record

/// An installation this app has stopped using but may not have revoked on the
/// gateway yet. Revocation needs both the handle and the App Attest key that
/// enrolled it, so both are kept until the gateway confirms the tombstone or
/// the installation is known to have expired.
public struct PendingRevocation: Codable, Equatable, Sendable {
    /// The community the installation belonged to; also the record's file name.
    public let communityID: String
    /// The gateway that issued the installation. The record is only ever
    /// replayed against this gateway.
    public let gatewayURL: URL
    /// The gateway installation handle.
    public let installationHandle: String
    /// The App Attest key identifier that signs the revocation assertion.
    public let attestKeyID: String
    /// The latest moment the gateway can still hold this installation live.
    ///
    /// The gateway answers `404 not_authorized` for every rejection on the
    /// revoke path — row missing, expired, consumed challenge, assertion
    /// counter race — so a 404 alone never proves the installation is gone.
    /// Past this instant it does: the gateway filters `expires_at >= now`
    /// before it checks anything else, and nothing extends an installation
    /// once this client has stopped using it.
    public let installationExpiresAt: Date

    public init(
        communityID: String,
        gatewayURL: URL,
        installationHandle: String,
        attestKeyID: String,
        installationExpiresAt: Date
    ) {
        self.communityID = communityID
        self.gatewayURL = gatewayURL
        self.installationHandle = installationHandle
        self.attestKeyID = attestKeyID
        self.installationExpiresAt = installationExpiresAt
    }

    /// Builds the record from an enrollment.
    ///
    /// The installation's gateway-side expiry is the later of the install and
    /// delegation expiries, both `now + NIPPLLease.defaultDuration` taken
    /// during enrollment, so `enrolledAt + defaultDuration` is an upper bound.
    public init(enrollment: Enrollment, gatewayURL: URL) {
        self.init(
            communityID: enrollment.communityID,
            gatewayURL: gatewayURL,
            installationHandle: enrollment.installationHandle,
            attestKeyID: enrollment.attestKeyID,
            installationExpiresAt: enrollment.enrolledAt.addingTimeInterval(NIPPLLease.defaultDuration)
        )
    }
}

/// Failures of ``EnrollmentStore`` that are not plain file-system errors.
public enum EnrollmentStoreError: Error, Equatable {
    /// An enrollment cannot be demoted because neither it nor the caller
    /// knows which gateway issued it.
    case gatewayUnknown
}
