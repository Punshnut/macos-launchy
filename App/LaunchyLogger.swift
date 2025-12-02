import os

enum LaunchyLogger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.launchy"
    private static let logger = Logger(subsystem: subsystem, category: "runtime")
    private static var hasLoggedSessionStart = false

    static func startup() {
        guard hasLoggedSessionStart == false else { return }
        hasLoggedSessionStart = true
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let header = "[Launchy] === Session start \(timestamp) ==="
        print(header)
        logger.info("\(header, privacy: .public)")
    }

    static func log(_ message: String) {
        let entry = "[Launchy] \(message)"
        print(entry)
        logger.info("\(entry, privacy: .public)")
    }

    static func error(_ message: String) {
        let entry = "[Launchy][ERROR] \(message)"
        print(entry)
        logger.error("\(entry, privacy: .public)")
    }
}
