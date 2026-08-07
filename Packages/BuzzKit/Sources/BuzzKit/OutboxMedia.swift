import Foundation
import GRDB

/// One content-addressed blob staged for a signed outbox event.
public struct OutboxMedia: Sendable, Equatable {
    public let sha256: String
    public let ordinal: Int
    public let fileExtension: String
    public let mimeType: String
    public let size: Int

    public init(sha256: String, ordinal: Int, fileExtension: String, mimeType: String, size: Int) {
        self.sha256 = sha256
        self.ordinal = ordinal
        self.fileExtension = fileExtension
        self.mimeType = mimeType
        self.size = size
    }
}

/// The durable upload state of one staged blob.
public enum OutboxMediaState: String, Sendable, Equatable {
    case staged
    case uploading
    case uploaded
    case failed
}

/// A content-addressed staged file. Multiple outbox events may reference the same key.
public struct StagedMediaKey: Sendable, Hashable {
    public let sha256: String
    public let fileExtension: String

    public init(sha256: String, fileExtension: String) {
        self.sha256 = sha256
        self.fileExtension = fileExtension
    }
}

/// The on-disk store for scrubbed media waiting for its outbox upload.
public struct MediaStagingStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    @discardableResult
    public func write(_ data: Data, for key: StagedMediaKey) throws -> URL {
        let destination = try fileURL(for: key)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: destination.path) {
            try data.write(to: destination, options: .atomic)
        }
        return destination
    }

    public func data(for key: StagedMediaKey) throws -> Data {
        try Data(contentsOf: fileURL(for: key))
    }

    public func removeAll() throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    /// Removes files that no surviving `outbox_media` row references.
    public func sweep(retaining keys: Set<StagedMediaKey>) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        for url in urls {
            guard let fileKey = key(for: url), keys.contains(fileKey) else {
                try FileManager.default.removeItem(at: url)
                continue
            }
        }
    }

    private func fileURL(for key: StagedMediaKey) throws -> URL {
        guard key.sha256.count == 64,
              key.sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              !key.fileExtension.isEmpty,
              key.fileExtension.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
        else { throw CocoaError(.fileWriteInvalidFileName) }
        return directory.appendingPathComponent("\(key.sha256).\(key.fileExtension)", isDirectory: false)
    }

    private func key(for url: URL) -> StagedMediaKey? {
        let fileExtension = url.pathExtension
        let sha256 = url.deletingPathExtension().lastPathComponent
        guard !fileExtension.isEmpty, !sha256.isEmpty else { return nil }
        return StagedMediaKey(sha256: sha256, fileExtension: fileExtension)
    }
}

public extension BuzzEventStore {
    /// Deletes database rows whose signed event no longer exists and returns the
    /// file keys still referenced by a live outbox row.
    func reconcileOutboxMedia() async throws -> Set<StagedMediaKey> {
        try await writer.write { db in
            try db.execute(sql: """
            DELETE FROM outbox_media
            WHERE NOT EXISTS (
                SELECT 1 FROM outbox WHERE outbox.event_id = outbox_media.event_id
            )
            """)
            return try Row.fetchAll(db, sql: "SELECT DISTINCT sha256, ext FROM outbox_media")
                .reduce(into: Set<StagedMediaKey>()) { keys, row in
                    keys.insert(StagedMediaKey(sha256: row["sha256"], fileExtension: row["ext"]))
                }
        }
    }

    internal static func insertOutboxMedia(
        _ media: [OutboxMedia],
        eventID: String,
        into db: Database
    ) throws {
        for item in media {
            try db.execute(
                sql: """
                INSERT INTO outbox_media (
                    event_id, sha256, ordinal, ext, mime, size, state, attempts, last_error
                ) VALUES (?, ?, ?, ?, ?, ?, ?, 0, NULL)
                ON CONFLICT(event_id, sha256) DO NOTHING
                """,
                arguments: [
                    eventID,
                    item.sha256,
                    item.ordinal,
                    item.fileExtension,
                    item.mimeType,
                    item.size,
                    OutboxMediaState.staged.rawValue,
                ]
            )
        }
    }
}
