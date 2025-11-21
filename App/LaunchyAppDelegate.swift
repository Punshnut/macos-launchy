import AppKit
import SwiftUI

/// Coordinates non-SwiftUI lifecycle tasks such as discovery, window management, and menu bar logic.
@MainActor
final class LaunchyAppDelegate: NSObject, NSApplicationDelegate {
    private var launcherWindowController: LauncherWindowController?
    private let appDiscoveryService = AppDiscoveryService()
    private let globalHotkeyManager = HotkeyManager()
    private let appArrangementStore = AppArrangementStore()
    private var installedApplications: [AppItem] = []
    private var activeLauncherMode: LauncherMode?
    private var launcherSettings = LauncherSettings.defaults
    private var settingsObservationTask: Task<Void, Never>?
    private var menuBarStatusItem: NSStatusItem?
    private var statusItemMenu: NSMenu?
    private lazy var settingsWindowController = SettingsWindowController()

    /// Finishes bootstrapping the app by loading settings, refreshing apps, and showing the window.
    func applicationDidFinishLaunching(_ notification: Notification) {
        bootstrapApplication()
    }

    /// Reopens the launcher when the Dock icon is clicked while the app is already running.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        applyLauncherMode()
        launcherWindowController?.present()
        return true
    }

    /// Releases observers and menu bar items before the process quits.
    func applicationWillTerminate(_ notification: Notification) {
        settingsObservationTask?.cancel()
        removeStatusItem()
        globalHotkeyManager.deactivate()
    }

    /// Reloads applications via the debug menu, clearing stale icon caches beforehand.
    func reloadAppsFromDebugMenu() {
        appDiscoveryService.clearIconCache()
        reloadVisibleApps()
        applyLauncherMode()
    }

    /// Restores the default settings payload and reapplies it to the live UI.
    func resetSettingsFromDebugMenu() {
        LauncherSettingsPersistence.resetSettings()
        handleSettingsChange()
    }

    /// Cycles through the available background styles to help preview launcher appearance.
    func toggleTestBackgroundStyles() {
        let styles = LauncherSettings.PreferredBackgroundStyle.allCases
        guard let currentIndex = styles.firstIndex(of: launcherSettings.backgroundStylePreference) else {
            return
        }

        let nextIndex = (currentIndex + 1) % styles.count
        let nextStyle = styles[nextIndex]
        launcherSettings.backgroundStylePreference = nextStyle
        LauncherSettingsPersistence.setPreferredBackgroundStyle(nextStyle)
        applyLauncherMode()
    }

    /// Performs the ordered initialization steps required before the UI appears.
    private func bootstrapApplication() {
        // 2) Initialize launcher settings persisted from prior sessions.
        LauncherSettingsPersistence.registerDefaults()
        launcherSettings = LauncherSettingsPersistence.loadSettings()
        LaunchAtLoginManager.setEnabled(launcherSettings.launchesAtLogin)

        // 1 & 6) Load apps and immediately apply hidden/background style choices.
        reloadVisibleApps()

        // 3) Build the launcher window so the UI is ready for the hotkey.
        applyLauncherMode()

        // 4) `LaunchyApp` declares the SwiftUI `SettingsWindow` scene, so nothing else is needed here.

        // 5) Wire the global hotkey so it toggles the launcher window on demand.
        configureHotkeyManager()

        updateStatusItemVisibility()
        observeSettingsChanges()
    }

    /// Applies the current launcher mode, rebuilding the window when the persisted value changes.
    func applyLauncherMode() {
        let mode = launcherSettings.selectedLauncherMode
        if activeLauncherMode == mode {
            if let controller = launcherWindowController {
                controller.update(rootView: makeLauncherView())
            } else {
                rebuildWindow(for: mode)
            }
            return
        }

        activeLauncherMode = mode
        updateActivationPolicy(for: mode)
        rebuildWindow(for: mode)
    }

    /// Creates a fresh `LauncherWindowController` using the provided mode.
    private func rebuildWindow(for mode: LauncherMode) {
        launcherWindowController?.close()

        let view = makeLauncherView()

        let controller = LauncherWindowController(rootView: view, launcherMode: mode)
        controller.present()
        launcherWindowController = controller
    }

    /// Adjusts the app's activation policy so the Dock and Spaces behave appropriately for each mode.
    private func updateActivationPolicy(for mode: LauncherMode) {
        switch mode {
        case .floaty:
            if launcherSettings.isFloatyDockIconVisible {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
            } else {
                NSApp.setActivationPolicy(.accessory)
                NSApp.dockTile.display()
            }
        case .fullscreenOldMac:
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Ensures the menu bar status item matches the persisted setting.
    private func updateStatusItemVisibility() {
        if launcherSettings.isMenuBarIconVisible {
            createStatusItemIfNeeded()
        } else {
            removeStatusItem()
        }
    }

    /// Lazily builds the status bar icon and menu actions.
    private func createStatusItemIfNeeded() {
        guard menuBarStatusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            if let image = NSImage(systemSymbolName: "square.grid.3x3.fill", accessibilityDescription: "Launchy") {
                button.image = image
            } else {
                button.title = "Launchy"
            }
            button.target = self
            button.action = #selector(handleStatusItemButtonClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let menu = NSMenu()
        let showItem = NSMenuItem(title: "Show Launcher", action: #selector(showLauncherFromStatusItem(_:)), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettingsFromStatusItem(_:)), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Launchy", action: #selector(quitFromStatusItem(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItemMenu = menu
        menuBarStatusItem = item
    }

    /// Removes the status bar item if one has been created.
    private func removeStatusItem() {
        if let item = menuBarStatusItem {
            NSStatusBar.system.removeStatusItem(item)
            menuBarStatusItem = nil
        }
        statusItemMenu = nil
    }

    /// Responds to shared `LauncherSettings` updates so the UI reacts instantly.
    private func observeSettingsChanges() {
        settingsObservationTask?.cancel()
        settingsObservationTask = Task.detached { [weak self] in
            let notifications = NotificationCenter.default.notifications(named: .launcherSettingsDidChange)
            for await _ in notifications {
                guard let self else { continue }
                await self.handleSettingsChange()
            }
        }
    }

    /// Handles work that needs to happen after settings mutate elsewhere.
    private func handleSettingsChange() {
        let previousHidden = Set(launcherSettings.hiddenBundleIDs)
        launcherSettings = LauncherSettingsPersistence.loadSettings()
        LaunchAtLoginManager.setEnabled(launcherSettings.launchesAtLogin)
        let hiddenChanged = previousHidden != Set(launcherSettings.hiddenBundleIDs)
        if hiddenChanged {
            reloadVisibleApps()
        }
        applyLauncherMode()
        updateStatusItemVisibility()
    }

    /// Sets up the global hotkey used to toggle the launcher window.
    private func configureHotkeyManager() {
        globalHotkeyManager.onHotkeyPressed = { [weak self] in
            self?.toggleLauncherVisibility()
        }
        globalHotkeyManager.activate()
    }

    /// Shows or hides the launcher window whenever the hotkey fires.
    private func toggleLauncherVisibility() {
        guard let launcherWindowController else {
            applyLauncherMode()
            return
        }

        guard let window = launcherWindowController.window else {
            launcherWindowController.present()
            return
        }

        if window.isVisible {
            window.orderOut(nil)
        } else {
            launcherWindowController.present()
        }
    }

    /// Responds to clicks on the status item button.
    @objc private func handleStatusItemButtonClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }

        let isRightClick = event.type == .rightMouseUp
        let isControlClick = event.modifierFlags.contains(.control)

        if isRightClick || isControlClick {
            showStatusItemMenu(with: event, from: sender)
            return
        }

        toggleLauncherFromStatusItemButton(sender)
    }

    /// Presents the status item's menu anchored to the button.
    private func showStatusItemMenu(with event: NSEvent, from button: NSStatusBarButton) {
        guard let menu = statusItemMenu else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: button)
    }

    /// Toggles the launcher window when the status bar button is left-clicked.
    @objc private func toggleLauncherFromStatusItemButton(_ sender: Any?) {
        toggleLauncherVisibility()
    }

    /// Shows or rebuilds the launcher when the user clicks the menu bar item.
    @objc private func showLauncherFromStatusItem(_ sender: Any?) {
        applyLauncherMode()
        launcherWindowController?.present()
    }

    /// Cycles between floaty and fullscreen layouts when triggered from a menu/shortcut.
    func toggleLauncherModeShortcut() {
        let nextMode: LauncherMode = launcherSettings.selectedLauncherMode == .floaty ? .fullscreenOldMac : .floaty
        LauncherSettingsPersistence.setLauncherMode(nextMode)
    }

    /// Opens the settings window regardless of activation policy.
    func showSettingsWindow() {
        settingsWindowController.showWindowAndActivate()
    }

    /// Opens the settings window from the status item click.
    @objc private func openSettingsFromStatusItem(_ sender: Any?) {
        showSettingsWindow()
    }

    /// Terminates the app when the Quit command is invoked from the status menu.
    @objc private func quitFromStatusItem(_ sender: Any?) {
        NSApp.terminate(sender)
    }

    /// Rebuilds the visible apps list using the current hidden settings.
    private func reloadVisibleApps() {
        let hiddenBundleIDs = Set(launcherSettings.hiddenBundleIDs)
        installedApplications = appArrangementStore.arrangedApps(
            from: appDiscoveryService
                .reloadApps(hiddenBundleIDs: hiddenBundleIDs)
                .map(appDiscoveryService.loadIcon),
            appsPerPage: LauncherGridConfiguration.appsPerPage
        )
    }

    /// Assembles the launcher SwiftUI view with the latest settings.
    private func makeLauncherView() -> LauncherView {
        LauncherView(
            appLibrary: installedApplications,
            backgroundStylePreference: launcherSettings.backgroundStylePreference,
            launcherMode: launcherSettings.selectedLauncherMode
        ) { [weak self] reorderedApps in
            guard let self else { return }
            installedApplications = reorderedApps
            appArrangementStore.saveOrderedApps(reorderedApps)
        }
    }
}
