import Foundation
import OSLog

/// A bounded, device-retrievable account of foreground-banner decisions.
///
/// Unified logging is useful while attached, but it has not been reliably retrievable from
/// the device this feature is being verified on. Debug builds therefore write the same
/// content-free lines into the app container, where `devicectl device copy from` can collect
/// them after a failed interaction.
enum InAppNotificationDiagnostics {
    private static let logger = Logger(subsystem: "Hive", category: "banner")

#if DEBUG
    private static let queue = DispatchQueue(label: "Hive.InAppNotificationDiagnostics")
    private static let maximumFileSize = 256 * 1024
    private static let filename = "banner-diagnostics.log"
#endif

    static func record(_ message: String) {
        logger.notice("\(message, privacy: .public)")
#if DEBUG
        queue.async {
            append("\(Date().timeIntervalSince1970) \(message)\n")
        }
#endif
    }

#if DEBUG
    private static func append(_ line: String) {
        guard let data = line.data(using: .utf8),
              let fileURL = try? diagnosticsFileURL()
        else { return }

        if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size + data.count > maximumFileSize {
            try? Data().write(to: fileURL, options: .atomic)
        }

        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try? Data().write(to: fileURL, options: .atomic)
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            logger.error("Could not append banner diagnostics: \(String(describing: error), privacy: .public)")
        }
    }

    private static func diagnosticsFileURL() throws -> URL {
        let directory = try FileManager.default
            .url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            .appendingPathComponent("Hive", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(filename)
    }
#endif
}
