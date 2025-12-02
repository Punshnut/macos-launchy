import Foundation
import OSLog

@MainActor
enum LaunchyLogger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.launchy"
    private static let logger = Logger(subsystem: subsystem, category: "runtime")

    static func startup() {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let header = "[Launchy] === Session start \(timestamp) ==="
        print(header)
        logger.info("\(header)")
    }

    static func log(_ message: String) {
        let entry = "[Launchy] \(message)"
        print(entry)
        logger.info("\(entry)")
    }

    static func error(_ message: String) {
        let entry = "[Launchy][ERROR] \(message)"
        print(entry)
        logger.error("\(entry)")
    }
}
