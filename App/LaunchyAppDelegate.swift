import AppKit
import SwiftUI

/// Coordinates non-SwiftUI lifecycle tasks such as discovery, window management, and menu bar logic.
@MainActor
final class LaunchyAppDelegate: NSObject, NSApplicationDelegate {
    private var launcherWindowManager: LauncherWindowController?
    private let applicationDiscovery = AppDiscoveryService()
    private let hotkeyCoordinator = HotkeyManager()
    private let itemOrderStore = ItemArrangementStore()
    private var orderedItems: [LauncherItem] = []
    private var pageSizes: [Int] = []
    private var currentLauncherMode: LauncherMode?
    private var currentSettings = LauncherSettings.defaults
    private var settingsStreamTask: Task<Void, Never>?
    private var arrangementResetTask: Task<Void, Never>?
    private var statusBarItem: NSStatusItem?
    private var statusBarMenu: NSMenu?
    private lazy var settingsWindowPresenter = SettingsWindowController()

    /// Finishes bootstrapping the app by loading settings, refreshing apps, and showing the window.
    func applicationDidFinishLaunching(_ notification: Notification) {
        bootstrapApplication()
        removeDefaultMainMenuItems()
    }

    /// Reopens the launcher when the Dock icon is clicked while the app is already running.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        applyLauncherMode()
        launcherWindowManager?.presentWindow()
        return true
    }

    /// Releases observers and menu bar items before the process quits.
    func applicationWillTerminate(_ notification: Notification) {
        settingsStreamTask?.cancel()
        arrangementResetTask?.cancel()
        removeStatusItem()
        hotkeyCoordinator.deactivate()
    }

    /// Reloads applications via the debug menu, clearing stale icon caches beforehand.
    func reloadAppsFromDebugMenu() {
        applicationDiscovery.clearIconCache()
        refreshLauncherItems()
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
        guard let currentIndex = styles.firstIndex(of: currentSettings.backgroundStylePreference) else {
            return
        }

        let nextIndex = (currentIndex + 1) % styles.count
        let nextStyle = styles[nextIndex]
        currentSettings.backgroundStylePreference = nextStyle
        LauncherSettingsPersistence.setPreferredBackgroundStyle(nextStyle)
        applyLauncherMode()
    }

    /// Performs the ordered initialization steps required before the UI appears.
    private func bootstrapApplication() {
        // 2) Initialize launcher settings persisted from prior sessions.
        LauncherSettingsPersistence.registerDefaults()
        currentSettings = LauncherSettingsPersistence.loadSettings()
        LaunchAtLoginManager.setEnabled(currentSettings.launchesAtLogin)

        // 1 & 6) Load apps and immediately apply hidden/background style choices.
        refreshLauncherItems()

        // 3) Build the launcher window so the UI is ready for the hotkey.
        applyLauncherMode()

        // 4) `LaunchyApp` declares the SwiftUI `SettingsWindow` scene, so nothing else is needed here.

        // 5) Wire the global hotkey so it toggles the launcher window on demand.
        configureHotkeyManager()

        updateStatusItemVisibility()
        observeSettingsChanges()
        observeArrangementResetRequests()
    }

    /// Hides unused top-level macOS menu bar items.
    private func removeDefaultMainMenuItems() {
        guard let mainMenu = NSApp.mainMenu else { return }
        let titlesToRemove: Set<String> = ["Edit", "View", "Window", "Help"]
        let itemsToRemove = mainMenu.items.filter { titlesToRemove.contains($0.title) }
        for item in itemsToRemove {
            mainMenu.removeItem(item)
        }
    }

    /// Applies the current launcher mode, rebuilding the window when the persisted value changes.
    func applyLauncherMode() {
        let mode = currentSettings.selectedLauncherMode
        if currentLauncherMode == mode {
            if let controller = launcherWindowManager {
                controller.update(rootView: buildLauncherView())
            } else {
                rebuildWindow(for: mode)
            }
            return
        }

        currentLauncherMode = mode
        updateActivationPolicy(for: mode)
        rebuildWindow(for: mode)
    }

    /// Creates a fresh `LauncherWindowController` using the provided mode.
    private func rebuildWindow(for mode: LauncherMode) {
        launcherWindowManager?.close()

        let view = buildLauncherView()

        let controller = LauncherWindowController(rootView: view, launcherMode: mode)
        controller.presentWindow()
        launcherWindowManager = controller
    }

    /// Adjusts the app's activation policy so the Dock and Spaces behave appropriately for each mode.
    private func updateActivationPolicy(for mode: LauncherMode) {
        switch mode {
        case .floaty:
            if currentSettings.isFloatyDockIconVisible {
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
        if currentSettings.isMenuBarIconVisible {
            createStatusItemIfNeeded()
        } else {
            removeStatusItem()
        }
    }

    /// Lazily builds the status bar icon and menu actions.
    private func createStatusItemIfNeeded() {
        guard statusBarItem == nil else { return }

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

        statusBarMenu = menu
        statusBarItem = item
    }

    /// Removes the status bar item if one has been created.
    private func removeStatusItem() {
        if let item = statusBarItem {
            NSStatusBar.system.removeStatusItem(item)
            statusBarItem = nil
        }
        statusBarMenu = nil
    }

    /// Responds to shared `LauncherSettings` updates so the UI reacts instantly.
    private func observeSettingsChanges() {
        settingsStreamTask?.cancel()
        settingsStreamTask = Task.detached { [weak self] in
            let notifications = NotificationCenter.default.notifications(named: .launcherSettingsDidChange)
            for await _ in notifications {
                guard let self else { continue }
                await self.handleSettingsChange()
            }
        }
    }

    /// Listens for arrangement reset requests dispatched from the settings window.
    private func observeArrangementResetRequests() {
        arrangementResetTask?.cancel()
        arrangementResetTask = Task.detached { [weak self] in
            let notifications = NotificationCenter.default.notifications(named: .launcherArrangementResetRequested)
            for await _ in notifications {
                guard let self else { continue }
                await self.handleArrangementReset()
            }
        }
    }

    /// Handles work that needs to happen after settings mutate elsewhere.
    private func handleSettingsChange() {
        let previousHidden = Set(currentSettings.hiddenBundleIDs)
        let previousGapSetting = currentSettings.fillsGapsAutomatically
        currentSettings = LauncherSettingsPersistence.loadSettings()
        LaunchAtLoginManager.setEnabled(currentSettings.launchesAtLogin)
        let hiddenChanged = previousHidden != Set(currentSettings.hiddenBundleIDs)
        let gapSettingChanged = previousGapSetting != currentSettings.fillsGapsAutomatically
        if hiddenChanged || gapSettingChanged {
            refreshLauncherItems()
        }
        applyLauncherMode()
        updateStatusItemVisibility()
    }

    /// Clears saved arrangement data and reloads apps from disk.
    @MainActor
    private func handleArrangementReset() {
        itemOrderStore.resetArrangement()
        refreshLauncherItems()
        applyLauncherMode()
    }

    /// Sets up the global hotkey used to toggle the launcher window.
    private func configureHotkeyManager() {
        hotkeyCoordinator.onHotkeyPressed = { [weak self] in
            self?.toggleLauncherVisibility()
        }
        hotkeyCoordinator.activate()
    }

    /// Shows or hides the launcher window whenever the hotkey fires.
    private func toggleLauncherVisibility() {
        guard let launcherWindowManager else {
            applyLauncherMode()
            return
        }

        guard let window = launcherWindowManager.window else {
            launcherWindowManager.presentWindow()
            return
        }

        if window.isVisible {
            window.orderOut(nil)
        } else {
            launcherWindowManager.presentWindow()
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
        guard let menu = statusBarMenu else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: button)
    }

    /// Toggles the launcher window when the status bar button is left-clicked.
    @objc private func toggleLauncherFromStatusItemButton(_ sender: Any?) {
        toggleLauncherVisibility()
    }

    /// Shows or rebuilds the launcher when the user clicks the menu bar item.
    @objc private func showLauncherFromStatusItem(_ sender: Any?) {
        applyLauncherMode()
        launcherWindowManager?.presentWindow()
    }

    /// Cycles between floaty and fullscreen layouts when triggered from a menu/shortcut.
    func toggleLauncherModeShortcut() {
        let nextMode: LauncherMode = currentSettings.selectedLauncherMode == .floaty ? .fullscreenOldMac : .floaty
        LauncherSettingsPersistence.setLauncherMode(nextMode)
    }

    /// Opens the settings window regardless of activation policy.
    func showSettingsWindow() {
        settingsWindowPresenter.showWindowAndActivate()
    }

    /// Opens the settings window from the status item click.
    @objc private func openSettingsFromStatusItem(_ sender: Any?) {
        showSettingsWindow()
    }

    /// Terminates the app when the Quit command is invoked from the status menu.
    @objc private func quitFromStatusItem(_ sender: Any?) {
        NSApp.terminate(sender)
    }

    /// Rebuilds the visible items list using the current hidden settings.
    private func refreshLauncherItems() {
        let hiddenBundleIDs = Set(currentSettings.hiddenBundleIDs)
        let (items, sizes) = itemOrderStore.arrangedItems(
            from: applicationDiscovery
                .reloadApps(hiddenBundleIDs: hiddenBundleIDs)
                .map(applicationDiscovery.loadIcon),
            pageCapacity: LauncherGridConfiguration.pageCapacity,
            fillsGapsAutomatically: currentSettings.fillsGapsAutomatically
        )
        orderedItems = items
        pageSizes = sizes
    }

    /// Assembles the launcher SwiftUI view with the latest settings.
    private func buildLauncherView() -> LauncherView {
        LauncherView(
            itemCatalog: orderedItems,
            initialPageSizes: pageSizes,
            backgroundStylePreference: currentSettings.backgroundStylePreference,
            solidBackgroundColor: currentSettings.solidBackgroundColor,
            launcherMode: currentSettings.selectedLauncherMode,
            fillsGapsAutomatically: currentSettings.fillsGapsAutomatically
        ) { [weak self] reorderedItems, newPageSizes in
            guard let self else { return }
            orderedItems = reorderedItems
            pageSizes = newPageSizes
            itemOrderStore.saveOrderedItems(reorderedItems, pageSizes: newPageSizes)
        }
    }
}
