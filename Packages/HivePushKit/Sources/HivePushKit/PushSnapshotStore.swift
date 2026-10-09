import Foundation

/// The per-community push snapshots in the App Group, one JSON file per community
/// under `<container>/PushSnapshots/<communityID>.json`.
///
/// One file per community, rather than one file holding all of them, so that a
/// community joining or leaving touches only its own entry and the extension can
/// read one wake's community without parsing every other. Each write is atomic
/// (a rename over the old file), so the extension never sees a half-written
/// snapshot; and each file is protected until first unlock, matching the
/// identity key's Keychain accessibility, so a wake after a reboot — but before
/// the reader has unlocked — finds neither rather than one without the other.
///
/// The app is the only writer. The extension reads.
public struct PushSnapshotStore: Sendable {
    public static let directoryName = "PushSnapshots"

    public let directory: URL

    public init(containerURL: URL) {
        directory = containerURL.appendingPathComponent(Self.directoryName, isDirectory: true)
    }

    /// The store in `appGroup`'s container, or `nil` when this process has no
    /// access to the group.
    public init?(appGroup: AppGroup) {
        guard let containerURL = appGroup.containerURL else { return nil }
        self.init(containerURL: containerURL)
    }

    public func write(_ snapshot: PushCommunitySnapshot) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(snapshot)
        try data.write(
            to: fileURL(communityID: snapshot.communityID),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }

    /// The snapshot for `communityID`, or `nil` when none is stored or the stored
    /// one is of a version this build does not read.
    public func load(communityID: String) throws -> PushCommunitySnapshot? {
        let url = fileURL(communityID: communityID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Self.decode(Data(contentsOf: url))
    }

    /// Every readable snapshot, in no particular order.
    public func loadAll() throws -> [PushCommunitySnapshot] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return files
            .filter { $0.pathExtension == Self.fileExtension }
            .compactMap { url in (try? Data(contentsOf: url)).flatMap(Self.decode) }
    }

    /// Removes `communityID`'s snapshot; none stored is not an error.
    public func remove(communityID: String) throws {
        let url = fileURL(communityID: communityID)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// Removes every snapshot; an empty or absent store is not an error.
    public func removeAll() throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    // MARK: - Layout

    private static let fileExtension = "json"

    private func fileURL(communityID: String) -> URL {
        directory.appendingPathComponent(communityID).appendingPathExtension(Self.fileExtension)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static func decode(_ data: Data) -> PushCommunitySnapshot? {
        guard let snapshot = try? decoder.decode(PushCommunitySnapshot.self, from: data),
              snapshot.version == PushCommunitySnapshot.currentVersion
        else { return nil }
        return snapshot
    }
}
