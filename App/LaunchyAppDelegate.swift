import AppKit
import SwiftUI

/// Coordinates non-SwiftUI lifecycle tasks such as discovery, window management, and menu bar logic.
@MainActor
final class LaunchyAppDelegate: NSObject, NSApplicationDelegate {
    private var launcherWindowManager: LauncherWindowController?
    private let applicationDiscovery = AppDiscoveryService()
    private let launcherHotkeyManager = HotkeyManager()
    private let layoutHotkeyManager = HotkeyManager(descriptor: nil)
    private let itemOrderStore = ItemArrangementStore()
    private var orderedItems: [LauncherItem] = []
    private var pageSizes: [Int] = []
    private var currentLauncherMode: LauncherMode?
    private var currentSettings = LauncherSettings.defaults
    private var settingsStreamTask: Task<Void, Never>?
    private var arrangementResetTask: Task<Void, Never>?
    private var statusBarItem: NSStatusItem?
    private var statusBarMenu: NSMenu?
    private var lastFocusedApplication: NSRunningApplication?
    private var pendingLaunchedApplication: NSRunningApplication?
    private var pendingLaunchBundleIdentifier: String?
    private lazy var settingsWindowPresenter = SettingsWindowController()
    private lazy var introductionPresenter = IntroductionWindowController.shared
    private let updaterController = UpdaterController()

    /// Finishes bootstrapping the app by loading settings, refreshing apps, and preparing the window.
    func applicationDidFinishLaunching(_ notification: Notification) {
        bootstrapApplication()
        enforceMinimalMainMenu()
    }

    /// Reapplies menu pruning after the app is foregrounded.
    func applicationDidBecomeActive(_ notification: Notification) {
        enforceMinimalMainMenu()
    }

    /// Reopens the launcher when the Dock icon is clicked while the app is already running.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        toggleLauncherVisibility()
        return true
    }

    /// Releases observers and menu bar items before the process quits.
    func applicationWillTerminate(_ notification: Notification) {
        settingsStreamTask?.cancel()
        arrangementResetTask?.cancel()
        removeStatusItem()
        launcherHotkeyManager.deactivate()
        layoutHotkeyManager.deactivate()
    }

    /// Allows menu items to kick off a manual Sparkle check.
    func checkForUpdatesFromMenu() {
        updaterController.checkForUpdates(nil)
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

        // 3) Build the launcher window so the UI is ready for the hotkey without surfacing it yet.
        applyLauncherMode(shouldPresentWindow: false)

        // 4) `LaunchyApp` declares the SwiftUI `SettingsWindow` scene, so nothing else is needed here.

        // 5) Wire the global hotkey so it toggles the launcher window on demand.
        configureHotkeyManagers()

        updateStatusItemVisibility()
        observeSettingsChanges()
        observeArrangementResetRequests()
        showIntroductionIfNeeded()
    }

    /// Double-checks that unused menu bar items are stripped even if AppKit rebuilds the menu.
    private func enforceMinimalMainMenu() {
        removeDefaultMainMenuItems()

        Task { @MainActor [weak self] in
            await Task.yield()
            self?.removeDefaultMainMenuItems()
        }
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
    func applyLauncherMode(shouldPresentWindow: Bool = true) {
        let mode = currentSettings.selectedLauncherMode
        if currentLauncherMode == mode {
            if let controller = launcherWindowManager {
                controller.update(rootView: buildLauncherView())
            } else {
                rebuildWindow(for: mode, shouldPresentWindow: shouldPresentWindow)
            }
            return
        }

        currentLauncherMode = mode
        updateActivationPolicy(for: mode, shouldActivate: shouldPresentWindow)
        rebuildWindow(for: mode, shouldPresentWindow: shouldPresentWindow)
    }

    /// Creates a fresh `LauncherWindowController` using the provided mode.
    private func rebuildWindow(for mode: LauncherMode, shouldPresentWindow: Bool) {
        launcherWindowManager?.close()

        let view = buildLauncherView()

        let controller = LauncherWindowController(rootView: view, launcherMode: mode)
        if shouldPresentWindow {
            controller.presentWindow()
        }
        launcherWindowManager = controller
    }

    /// Adjusts the app's activation policy so the Dock and Spaces behave appropriately for each mode.
    private func updateActivationPolicy(for mode: LauncherMode, shouldActivate: Bool) {
        switch mode {
        case .floaty:
            if currentSettings.isFloatyDockIconVisible {
                NSApp.setActivationPolicy(.regular)
                if shouldActivate {
                    NSApp.activate(ignoringOtherApps: true)
                }
            } else {
                NSApp.setActivationPolicy(.accessory)
                NSApp.dockTile.display()
            }
        case .fullscreen:
            NSApp.setActivationPolicy(.regular)
            if shouldActivate {
                NSApp.activate(ignoringOtherApps: true)
            }
        }

        enforceMinimalMainMenu()
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
        let showItem = NSMenuItem(title: String(localized: "Show Launcher"), action: #selector(showLauncherFromStatusItem(_:)), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)

        let settingsItem = NSMenuItem(title: String(localized: "Settings..."), action: #selector(openSettingsFromStatusItem(_:)), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let updateItem = NSMenuItem(title: String(localized: "Check for Updates..."), action: #selector(checkForUpdatesFromStatusItem(_:)), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: String(localized: "Quit Launchy"), action: #selector(quitFromStatusItem(_:)), keyEquivalent: "q")
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
        refreshHotkeyRegistrations()
    }

    /// Clears saved arrangement data and reloads apps from disk.
    @MainActor
    private func handleArrangementReset() {
        let preservedNames = customNamesByBundleID(from: orderedItems)
        itemOrderStore.resetArrangement()
        refreshLauncherItems(preservingCustomNames: preservedNames)
        applyLauncherMode()
    }

    /// Sets up global hotkeys for toggling the launcher and switching layouts.
    private func configureHotkeyManagers() {
        launcherHotkeyManager.onHotkeyPressed = { [weak self] in
            self?.toggleLauncherVisibility()
        }
        layoutHotkeyManager.onHotkeyPressed = { [weak self] in
            self?.toggleLauncherModeShortcut()
        }
        refreshHotkeyRegistrations()
    }

    /// Applies the persisted hotkey selections to the running listeners.
    private func refreshHotkeyRegistrations() {
        launcherHotkeyManager.update(descriptor: currentSettings.launcherHotkey)
        launcherHotkeyManager.activate()

        layoutHotkeyManager.update(descriptor: currentSettings.layoutToggleHotkey)
        layoutHotkeyManager.activate()
    }

    /// Remembers which app was active before the launcher appeared so we can restore focus after hiding.
    private func recordFrontmostApplicationForRestoration() {
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.isTerminated == false else { return }

        if let bundleID = Bundle.main.bundleIdentifier, frontmost.bundleIdentifier == bundleID {
            return
        }

        lastFocusedApplication = frontmost
    }

    /// Tracks the app the user asked to launch so we can bring it forward after the launcher hides.
    func recordLaunchedApplication(bundleIdentifier: String, application: NSRunningApplication?) {
        pendingLaunchBundleIdentifier = bundleIdentifier
        if let application {
            pendingLaunchedApplication = application
        }

        if launcherWindowManager?.window?.isVisible == false {
            focusPreferredApplicationAfterLauncherHides()
        }
    }

    /// Restores focus to either the app being launched or the one that was active before opening Launchy.
    func focusPreferredApplicationAfterLauncherHides() {
        if activatePendingLaunchIfPossible() {
            return
        }
        activateLastFocusedApplicationIfAvailable()
    }

    /// Attempts to foreground the last launched app, returning true on success.
    private func activatePendingLaunchIfPossible() -> Bool {
        guard let application = pendingLaunchedApplication ?? runningApplicationForPendingBundleID() else {
            return false
        }

        application.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        pendingLaunchedApplication = nil
        pendingLaunchBundleIdentifier = nil
        return true
    }

    /// Looks up a running instance for the pending bundle identifier, if any.
    private func runningApplicationForPendingBundleID() -> NSRunningApplication? {
        guard let bundleID = pendingLaunchBundleIdentifier else { return nil }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first { $0.isTerminated == false }
    }

    /// Brings back the previously focused app when no launch target is waiting.
    private func activateLastFocusedApplicationIfAvailable() {
        guard let app = lastFocusedApplication, app.isTerminated == false else { return }
        app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    }

    /// Shows or hides the launcher window whenever the hotkey fires.
    private func toggleLauncherVisibility() {
        if launcherWindowManager == nil {
            applyLauncherMode(shouldPresentWindow: false)
        }

        guard let launcherWindowManager else { return }

        guard let window = launcherWindowManager.window else {
            recordFrontmostApplicationForRestoration()
            launcherWindowManager.presentWindow()
            return
        }

        if window.isVisible {
            window.orderOut(nil)
            focusPreferredApplicationAfterLauncherHides()
        } else {
            recordFrontmostApplicationForRestoration()
            activateApplicationForCurrentModeIfNeeded()
            launcherWindowManager.presentWindow()
        }
    }

    /// Activates the app when the current launcher mode expects a regular foreground experience.
    private func activateApplicationForCurrentModeIfNeeded() {
        switch currentSettings.selectedLauncherMode {
        case .floaty:
            NSApp.activate(ignoringOtherApps: true)
        case .fullscreen:
            NSApp.activate(ignoringOtherApps: true)
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
        if launcherWindowManager?.window?.isVisible != true {
            recordFrontmostApplicationForRestoration()
        }
        applyLauncherMode()
        activateApplicationForCurrentModeIfNeeded()
        launcherWindowManager?.presentWindow()
    }

    /// Cycles between floaty and fullscreen layouts when triggered from a menu/shortcut.
    func toggleLauncherModeShortcut() {
        let nextMode: LauncherMode = currentSettings.selectedLauncherMode == .floaty ? .fullscreen : .floaty
        LauncherSettingsPersistence.setLauncherMode(nextMode)
    }

    /// Opens the settings window regardless of activation policy.
    func showSettingsWindow() {
        settingsWindowPresenter.showWindowAndActivate()
    }

    /// Presents the Launchy introduction flow.
    func showIntroduction(startingAt step: Int = 0, markCompletionOnFinish: Bool = true) {
        introductionPresenter.present(startingAt: step, markCompletionOnFinish: markCompletionOnFinish)
    }

    /// Triggers a manual Sparkle update check from the status menu.
    @objc private func checkForUpdatesFromStatusItem(_ sender: Any?) {
        updaterController.checkForUpdates(sender)
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
    private func refreshLauncherItems(preservingCustomNames names: [String: String] = [:]) {
        let hiddenBundleIDs = Set(currentSettings.hiddenBundleIDs)
        let (items, sizes) = itemOrderStore.arrangedItems(
            from: applicationDiscovery
                .reloadApps(hiddenBundleIDs: hiddenBundleIDs)
                .map(applicationDiscovery.loadIcon),
            pageCapacity: LauncherGridConfiguration.pageCapacity,
            fillsGapsAutomatically: currentSettings.fillsGapsAutomatically,
            preferredCustomNames: names
        )
        orderedItems = items
        pageSizes = sizes
    }

    /// Builds a bundle ID keyed map of custom names from both root items and folder contents.
    private func customNamesByBundleID(from items: [LauncherItem]) -> [String: String] {
        var names: [String: String] = [:]

        func recordName(for app: AppItem) {
            guard let custom = app.customName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  custom.isEmpty == false else { return }
            names[app.bundleIdentifier] = custom
        }

        for item in items {
            switch item {
            case .app(let app):
                recordName(for: app)
            case .folder(let folder):
                folder.apps.forEach(recordName)
            }
        }

        return names
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

    /// Shows the introduction dialog on first launch.
    private func showIntroductionIfNeeded() {
        guard currentSettings.hasCompletedIntroduction == false else { return }
        showIntroduction()
    }
}
