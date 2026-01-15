import Foundation
import OSLog

/// Lightweight logging facade that mirrors messages to both `os_log` and a rolling file for support.
enum LaunchyLogger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.launchy"
    private static let logger = Logger(subsystem: subsystem, category: "runtime")
    private static let logQueue = DispatchQueue(label: "com.launchy.logger.file", qos: .utility)
    private static let logDirectoryName = "Launchy"
    private static let logFileName = "launchy.log"

    /// Signals the beginning of a session, clears any previous log, and records the new header.
    static func startup() {
        clearLogFile()
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let header = "[Launchy] === Session start \(timestamp) ==="
        record(entry: header, level: .info)
        if let path = resolvedLogFileURL()?.path {
            record(entry: "[Launchy] log file: \(path)", level: .info)
        }
    }

    /// Writes an informational log entry to both the unified logger and the rolling file.
    static func log(_ message: String) {
        record(entry: "[Launchy] \(message)", level: .info)
    }

    /// Writes an error log entry to both the unified logger and the rolling file.
    static func error(_ message: String) {
        record(entry: "[Launchy][ERROR] \(message)", level: .error)
    }

    private static func record(entry: String, level: OSLogType) {
        print(entry)
        switch level {
        case .error:
            logger.error("\(entry)")
        default:
            logger.info("\(entry)")
        }
        appendToLogFile(entry)
    }

    private static func resolvedLogFileURL() -> URL? {
        let baseDirectory = FileManager.default.homeDirectoryForCurrentUser
        return baseDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent(logDirectoryName, isDirectory: true)
            .appendingPathComponent(logFileName, isDirectory: false)
    }

    private static func clearLogFile() {
        logQueue.sync {
            guard let fileURL = resolvedLogFileURL() else { return }
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    private static func appendToLogFile(_ text: String) {
        guard let fileURL = resolvedLogFileURL() else { return }
        logQueue.async {
            do {
                let directoryURL = fileURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
                let payload = (text + "\n").data(using: .utf8) ?? Data()
                // Keep the rolling log capped to roughly 1 MB so it stays lightweight for support uploads.
                if let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                   let size = attributes[.size] as? NSNumber,
                   size.intValue > 1_000_000 {
                    try? FileManager.default.removeItem(at: fileURL)
                }
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    let handle = try FileHandle(forWritingTo: fileURL)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: payload)
                } else {
                    try payload.write(to: fileURL, options: .atomic)
                }
            } catch {
                logger.error("Failed to append log entry: \(error.localizedDescription)")
            }
        }
    }
}
