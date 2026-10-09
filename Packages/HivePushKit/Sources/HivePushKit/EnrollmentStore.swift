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

    // MARK: - Helpers

    private func fileURL(for communityID: String) -> URL {
        containerURL
            .appendingPathComponent(Self.directoryName)
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
    /// When the enrollment was completed.
    public let enrolledAt: Date

    public init(
        communityID: String,
        installationHandle: String,
        endpointGrant: String,
        attestKeyID: String,
        installID: String,
        relayURL: String,
        enrolledAt: Date = .now
    ) {
        self.communityID = communityID
        self.installationHandle = installationHandle
        self.endpointGrant = endpointGrant
        self.attestKeyID = attestKeyID
        self.installID = installID
        self.relayURL = relayURL
        self.enrolledAt = enrolledAt
    }
}
