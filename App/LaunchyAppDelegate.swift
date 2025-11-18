import AppKit
import SwiftUI

final class LaunchyAppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: LauncherWindowController?
    private let discoveryService = AppDiscoveryService()

    func applicationDidFinishLaunching(_ notification: Notification) {
        hideDockTile()
        presentLauncher()
    }

    private func hideDockTile() {
        NSApp.setActivationPolicy(.accessory)
        NSApp.dockTile.display()
    }

    private func presentLauncher() {
        let apps = discoveryService.reloadApps()
        let view = LauncherView(apps: apps, onLaunch: { [weak self] item in
            self?.launch(app: item)
        })
        let controller = LauncherWindowController(rootView: view)
        controller.present()
        windowController = controller
    }

    private func launch(app: AppItem) {
        guard let url = app.url else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration, completionHandler: nil)
    }
}
