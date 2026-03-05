import AppKit
import Sparkle

/// Owns Sparkle's updater and exposes a menu-friendly action to trigger manual checks.
@MainActor
final class UpdaterController: NSObject, SPUStandardUserDriverDelegate, SPUUpdaterDelegate {
    private lazy var updaterController: SPUStandardUpdaterController = {
        SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: self
        )
    }()

    override init() {
        super.init()
        _ = updaterController
    }

    /// Invoked from menu items or the status bar to present Sparkle's update UI.
    @IBAction func checkForUpdates(_ sender: Any?) {
        bringUpdateUIToFront()
        updaterController.checkForUpdates(sender)
    }

    // MARK: - SPUStandardUserDriverDelegate

    /// Ensures Sparkle alerts appear above the launcher when a modal is shown.
    nonisolated func standardUserDriverWillShowModalAlert() {
        Task { @MainActor [weak self] in
            self?.bringUpdateUIToFront()
        }
    }

    /// Surfaces a fallback download hint if Sparkle aborts due to validation issues.
    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.presentFallbackDownloadHintIfNeeded(for: error)
        }
    }

    // MARK: - Private

    /// Activates the app and elevates Sparkle windows so update UI is not hidden.
    private func bringUpdateUIToFront() {
        NotificationCenter.default.post(name: .sparkleWillPresentUpdateUI, object: nil)
        NSApp.activate(ignoringOtherApps: true)
        elevateSparkleWindowsIfNeeded()
        DispatchQueue.main.async { [weak self] in
            self?.elevateSparkleWindowsIfNeeded()
        }
    }

    /// Raises Sparkle windows above other app windows and keeps them on the active space.
    private func elevateSparkleWindowsIfNeeded() {
        let targetLevel = NSWindow.Level.screenSaver
        let behaviors: NSWindow.CollectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

        for window in NSApp.windows where isSparkleWindow(window) {
            window.level = targetLevel
            window.collectionBehavior.insert(behaviors)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }

    /// Heuristically identifies Sparkle-owned windows by their runtime class prefixes.
    private func isSparkleWindow(_ window: NSWindow) -> Bool {
        let className = NSStringFromClass(type(of: window))
        return className.hasPrefix("SPU") || className.hasPrefix("SU")
    }

    /// Shows a friendly GitHub download prompt when Sparkle detects signature/validation errors.
    private func presentFallbackDownloadHintIfNeeded(for error: Error) {
        let nsError = error as NSError
        guard nsError.domain == SUSparkleErrorDomain,
              let sparkleError = SUError(rawValue: OSStatus(nsError.code)),
              sparkleError == .signatureError || sparkleError == .validationError
        else {
            return
        }

        Task { @MainActor in
            let alert = NSAlert()
            alert.messageText = "Update could not be verified"
            alert.informativeText = "Launchy couldn't verify the downloaded update. Please download the latest release directly from GitHub instead."
            alert.addButton(withTitle: "Open GitHub")
            alert.addButton(withTitle: "Cancel")

            let response = alert.runModal()
            if response == .alertFirstButtonReturn,
               let url = URL(string: "https://github.com/Punshnut/macos-launchy/releases/latest") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}

extension Notification.Name {
    static let sparkleWillPresentUpdateUI = Notification.Name("LaunchySparkleWillPresentUpdateUI")
}
