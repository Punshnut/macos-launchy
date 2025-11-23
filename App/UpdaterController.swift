import AppKit
import Sparkle

/// Owns Sparkle's updater and exposes a menu-friendly action to trigger manual checks.
@MainActor
final class UpdaterController: NSObject {
    private let updaterController: SPUStandardUpdaterController

    override init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()
    }

    /// Invoked from menu items or the status bar to present Sparkle's update UI.
    @IBAction func checkForUpdates(_ sender: Any?) {
        updaterController.checkForUpdates(sender)
    }
}
