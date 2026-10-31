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
    static var isCurrentlyEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Registers or unregisters Launchy as a login item.
    static func setEnabled(_ shouldEnableLoginItem: Bool) {
        do {
            if shouldEnableLoginItem {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            loginItemLogger.error("Failed to update login item state: \(error.localizedDescription, privacy: .public)")
        }
    }
}
