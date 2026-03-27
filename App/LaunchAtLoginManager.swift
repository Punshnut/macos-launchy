import Foundation
import ServiceManagement
import OSLog

/// Coordinates enabling or disabling Launchy as a login item.
enum LaunchAtLoginManager {
    private static let loginItemLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Launchy",
        category: "LaunchAtLogin"
    )

    /// Returns whether Launchy is currently registered as a login item according to the system.
    /// This reflects the ground truth from System Settings, not the stored preference.
    @available(macOS 13.0, *)
    static var isCurrentlyEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Attempts to update the login item state using the best API available for the platform.
    static func setEnabled(_ shouldEnableLoginItem: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if shouldEnableLoginItem {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                loginItemLogger.error("Failed to update login item state: \(error.localizedDescription, privacy: .public)")
            }
        } else {
            // Pre-macOS 13 fallback relying on the legacy SMLoginItem API.
            guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
                loginItemLogger.error("Missing bundle identifier; cannot toggle login item.")
                return
            }
            let didUpdateLoginItem = SMLoginItemSetEnabled(bundleIdentifier as CFString, shouldEnableLoginItem)
            if !didUpdateLoginItem {
                loginItemLogger.error("SMLoginItemSetEnabled returned false for identifier \(bundleIdentifier, privacy: .public).")
            }
        }
    }
}
