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
    private var userAppPageSizes: [Int] = []
    private var currentLauncherMode: LauncherMode?
    private var currentSettings = LauncherSettings.defaults
    private var settingsStreamTask: Task<Void, Never>?
    private var arrangementResetTask: Task<Void, Never>?
    private var statusBarItem: NSStatusItem?
    private var statusBarMenu: NSMenu?
    private var lastFocusedApplication: NSRunningApplication?
    private var pendingLaunchedApplication: NSRunningApplication?
    private var pendingLaunchBundleIdentifier: String?
    private var mainMenuUpdateObserver: NSObjectProtocol?
    private var isTrimmingMainMenu = false
    private var applicationDirectoryMonitor: ApplicationDirectoryMonitor?
    private lazy var settingsWindowPresenter: SettingsWindowController = {
        let controller = SettingsWindowController()
        controller.onClose = { [weak self] in
            self?.refocusLauncherWindowIfVisible()
        }
        return controller
    }()
    private lazy var introductionPresenter = IntroductionWindowController.shared
    private lazy var hotCornerMonitor = HotCornerMonitor { [weak self] in
        self?.toggleLauncherVisibility()
    }
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
        applicationDirectoryMonitor?.stop()
        applicationDirectoryMonitor = nil
        removeStatusItem()
        launcherHotkeyManager.deactivate()
        layoutHotkeyManager.deactivate()
        hotCornerMonitor.stopMonitoring()
        if let observer = mainMenuUpdateObserver {
            NotificationCenter.default.removeObserver(observer)
            mainMenuUpdateObserver = nil
        }
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
        configureApplicationDirectoryMonitoring()
        LaunchAtLoginManager.setEnabled(currentSettings.launchesAtLogin)

        // 1 & 6) Load apps and immediately apply hidden/background style choices.
        refreshLauncherItems()

        // 3) Build the launcher window so the UI is ready for the hotkey without surfacing it yet.
        applyLauncherMode(shouldPresentWindow: false)

        // 4) `LaunchyApp` declares the SwiftUI `SettingsWindow` scene, so nothing else is needed here.

        // 5) Wire the global hotkey so it toggles the launcher window on demand.
        configureHotkeyManagers()

        updateStatusItemVisibility()
        updateHotCornerMonitoring()
        observeSettingsChanges()
        observeArrangementResetRequests()
        showIntroductionIfNeeded()
        observeMainMenuChanges()
    }

    /// Double-checks that unused menu bar items are stripped even if AppKit rebuilds the menu.
    private func enforceMinimalMainMenu() {
        removeDefaultMainMenuItems()

        Task { @MainActor [weak self] in
            await Task.yield()
            self?.removeDefaultMainMenuItems()
        }
    }

    /// Observes AppKit updates so we can trim the menu anytime Launchy is active.
    private func observeMainMenuChanges() {
        mainMenuUpdateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didUpdateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, NSApp.isActive else { return }
                self.removeDefaultMainMenuItems()
            }
        }
    }

    /// Keeps only the application menu so no extra menus appear.
    private func removeDefaultMainMenuItems() {
        guard isTrimmingMainMenu == false else { return }
        guard let mainMenu = NSApp.mainMenu,
              mainMenu.items.count > 1,
              let appMenuItem = mainMenu.items.first else {
            return
        }

        isTrimmingMainMenu = true
        defer { isTrimmingMainMenu = false }

        appMenuItem.menu?.removeItem(appMenuItem)

        let trimmedMenu = NSMenu(title: "")
        trimmedMenu.addItem(appMenuItem)
        NSApp.mainMenu = trimmedMenu
    }

    /// Applies the current launcher mode, rebuilding the window when the persisted value changes.
    func applyLauncherMode(shouldPresentWindow: Bool = true) {
        let mode = currentSettings.selectedLauncherMode
        let modeChanged = currentLauncherMode != mode
        currentLauncherMode = mode
        let shouldActivateApp = shouldPresentWindow && (modeChanged || launcherWindowManager?.window?.isVisible == true)
        updateActivationPolicy(for: mode, shouldActivate: shouldActivateApp)

        if modeChanged == false, let controller = launcherWindowManager {
            controller.update(rootView: buildLauncherView())
        } else {
            rebuildWindow(for: mode, shouldPresentWindow: shouldPresentWindow)
        }
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
    private func updateActivationPolicy(for _: LauncherMode, shouldActivate: Bool) {
        if currentSettings.isDockIconVisible {
            NSApp.setActivationPolicy(.regular)
            if shouldActivate {
                NSApp.activate(ignoringOtherApps: true)
            }
        } else {
            NSApp.setActivationPolicy(.accessory)
            NSApp.dockTile.display()
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

        statusBarMenu = buildStatusBarMenu()
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
        let previousUserApplicationsScan = currentSettings.shouldScanUserApplicationsFolder
        currentSettings = LauncherSettingsPersistence.loadSettings()
        LaunchAtLoginManager.setEnabled(currentSettings.launchesAtLogin)
        let hiddenChanged = previousHidden != Set(currentSettings.hiddenBundleIDs)
        let gapSettingChanged = previousGapSetting != currentSettings.fillsGapsAutomatically
        let scanSettingChanged = previousUserApplicationsScan != currentSettings.shouldScanUserApplicationsFolder
        if scanSettingChanged {
            configureApplicationDirectoryMonitoring()
        }
        if hiddenChanged || gapSettingChanged || scanSettingChanged {
            refreshLauncherItems()
        }
        applyLauncherMode()
        updateStatusItemVisibility()
        refreshHotkeyRegistrations()
        updateHotCornerMonitoring()
    }

    /// Ensures the directory watcher covers the locations we scan for apps.
    private func configureApplicationDirectoryMonitoring() {
        let directories = monitoredApplicationDirectories()
        applicationDirectoryMonitor?.stop()
        guard directories.isEmpty == false else {
            applicationDirectoryMonitor = nil
            return
        }

        applicationDirectoryMonitor = ApplicationDirectoryMonitor(
            directories: directories
        ) { [weak self] in
            Task { @MainActor in
                self?.refreshLauncherItems()
            }
        }
    }

    /// Mirrors the same directories AppDiscoveryService inspects.
    private func monitoredApplicationDirectories() -> [URL] {
        var directories: [URL] = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true)
        ]

        if currentSettings.shouldScanUserApplicationsFolder {
            let userApps = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications", isDirectory: true)
            directories.append(userApps)
        }

        return directories
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

    private func updateHotCornerMonitoring() {
        hotCornerMonitor.update(
            enabled: currentSettings.hotCornerEnabled,
            corner: currentSettings.hotCornerPosition
        )
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

    private func refocusLauncherWindowIfVisible() {
        guard let window = launcherWindowManager?.window, window.isVisible else { return }
        window.makeKeyAndOrderFront(nil)
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
        let menu = buildStatusBarMenu()
        statusBarMenu = menu
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

    /// Supplies the Dock's context menu with the arranged launcher items.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        buildDockMenu()
    }

    /// Cycles between floaty and fullscreen layouts when triggered from a menu/shortcut.
    func toggleLauncherModeShortcut() {
        let nextMode: LauncherMode = currentSettings.selectedLauncherMode == .floaty ? .fullscreen : .floaty
        LauncherSettingsPersistence.setLauncherMode(nextMode)
    }

    /// Connects the floating-layout toggle to a status-item menu command.
    @objc private func toggleLauncherModeMenuItem(_ sender: Any?) {
        toggleLauncherModeShortcut()
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
        let includeUserApplications = currentSettings.shouldScanUserApplicationsFolder
        let (baseApps, userApps) = applicationDiscovery.reloadApps(
            includeUserApplicationsFolder: includeUserApplications,
            hiddenBundleIDs: hiddenBundleIDs
        )
        let decoratedBaseApps = baseApps.map(applicationDiscovery.loadIcon)
        let decoratedUserApps = userApps
            .map(applicationDiscovery.loadIcon)
            .map { app -> AppItem in
                var modified = app
                if let custom = names[app.bundleIdentifier] {
                    modified.customName = custom
                }
                return modified
            }

        let (items, sizes) = itemOrderStore.arrangedItems(
            from: decoratedBaseApps,
            pageCapacity: LauncherGridConfiguration.pageCapacity,
            fillsGapsAutomatically: currentSettings.fillsGapsAutomatically,
            preferredCustomNames: names
        )

        let computedUserPageSizes = pageSizesForUserApplications(decoratedUserApps.count)
        userAppPageSizes = computedUserPageSizes

        orderedItems = items + decoratedUserApps.map(LauncherItem.app)
        pageSizes = sizes + computedUserPageSizes
    }

    private func pageSizesForUserApplications(_ count: Int) -> [Int] {
        guard count > 0 else { return [] }
        var remaining = count
        var sizes: [Int] = []
        let capacity = LauncherGridConfiguration.pageCapacity

        while remaining > 0 {
            let fill = min(capacity, remaining)
            sizes.append(fill)
            remaining -= fill
        }

        return sizes
    }

    private func isUserLauncherItem(_ item: LauncherItem) -> Bool {
        guard case .app(let app) = item else { return false }
        return app.isUserApplication
    }

    private func basePageSizes(from items: [LauncherItem], pageSizes: [Int]) -> [Int] {
        guard items.isEmpty == false else { return [] }
        var sanitized: [Int] = []
        var cursor = 0
        for size in pageSizes {
            guard size > 0 else { continue }
            let end = min(cursor + size, items.count)
            guard end > cursor else { continue }
            let pageItems = items[cursor..<end]
            let baseCount = pageItems.reduce(0) { partial, item in
                partial + (isUserLauncherItem(item) ? 0 : 1)
            }
            if baseCount > 0 {
                sanitized.append(min(baseCount, LauncherGridConfiguration.pageCapacity))
            }
            cursor = end
        }
        return sanitized
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
            fillsGapsAutomatically: currentSettings.fillsGapsAutomatically,
            onSettingsRequested: { [weak self] in
                self?.showSettingsWindow()
            }
        ) { [weak self] reorderedItems, newPageSizes in
            guard let self else { return }
            let baseItems = reorderedItems.filter { !isUserLauncherItem($0) }
            let basePageSizes = basePageSizes(from: reorderedItems, pageSizes: newPageSizes)
            orderedItems = reorderedItems
            pageSizes = basePageSizes + userAppPageSizes
            itemOrderStore.saveOrderedItems(baseItems, pageSizes: basePageSizes)
        }
    }

    /// Shows the introduction dialog on first launch.
    private func showIntroductionIfNeeded() {
        guard currentSettings.hasCompletedIntroduction == false else { return }
        showIntroduction()
    }

    /// Builds the menu shown from the status bar icon, mixing launcher content and app controls.
    private func buildStatusBarMenu() -> NSMenu {
        let menu = NSMenu()
        let showItem = NSMenuItem(title: String(localized: "Show Launcher"), action: #selector(showLauncherFromStatusItem(_:)), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)

        let toggleFloatyItem = NSMenuItem(
            title: String(localized: "Toggle Floaty Panel"),
            action: #selector(toggleLauncherModeMenuItem(_:)),
            keyEquivalent: ""
        )
        toggleFloatyItem.target = self
        menu.addItem(toggleFloatyItem)

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

        return menu
    }

    /// Builds the Dock context menu listing launcher items above the system options.
    private func buildDockMenu() -> NSMenu {
        let menu = NSMenu()
        let hasLauncherEntries = appendLauncherItemsMenu(to: menu)
        if hasLauncherEntries {
            menu.addItem(.separator())
        }
        return menu
    }

    /// Adds the arranged apps and folders to the provided menu in alphabetical order.
    @discardableResult
    private func appendLauncherItemsMenu(to menu: NSMenu) -> Bool {
        let sortedItems = orderedItems.sorted { lhs, rhs in
            menuSortKey(for: lhs).localizedCaseInsensitiveCompare(menuSortKey(for: rhs)) == .orderedAscending
        }

        guard sortedItems.isEmpty == false else {
            let placeholder = NSMenuItem(title: String(localized: "No applications available"), action: nil, keyEquivalent: "")
            placeholder.isEnabled = false
            menu.addItem(placeholder)
            return false
        }

        for item in sortedItems {
            switch item {
            case .app(let app):
                menu.addItem(menuItem(for: app))
            case .folder(let folder):
                menu.addItem(menuItem(for: folder))
            }
        }

        return true
    }

    /// Builds a menu item representing an app launch target.
    private func menuItem(for app: AppItem) -> NSMenuItem {
        let title = menuDisplayTitle(for: app)
        let item = NSMenuItem(title: title, action: #selector(launchAppFromMenu(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = app
        item.image = nil
        item.attributedTitle = nil
        item.isEnabled = app.bundleURL != nil
        return item
    }

    /// Builds a submenu-backed menu item representing a folder of apps.
    private func menuItem(for folder: FolderItem) -> NSMenuItem {
        let item = NSMenuItem(title: folder.name, action: nil, keyEquivalent: "")
        item.image = nil
        item.attributedTitle = nil

        let submenu = NSMenu()
        let sortedApps = folder.apps.sorted { lhs, rhs in
            menuSortKey(for: lhs).localizedCaseInsensitiveCompare(menuSortKey(for: rhs)) == .orderedAscending
        }

        if sortedApps.isEmpty {
            let placeholder = NSMenuItem(title: String(localized: "No applications available"), action: nil, keyEquivalent: "")
            placeholder.isEnabled = false
            submenu.addItem(placeholder)
        } else {
            for app in sortedApps {
                submenu.addItem(menuItem(for: app))
            }
        }

        item.submenu = submenu
        return item
    }

    /// Returns a stable string for sorting and displaying app items.
    private func menuDisplayTitle(for app: AppItem) -> String {
        if let bundleName = app.bundleURL?.lastPathComponent {
            return bundleName
        }
        return app.resolvedDisplayName
    }

    /// Produces a consistent sort key for menu entries.
    private func menuSortKey(for item: LauncherItem) -> String {
        switch item {
        case .app(let app):
            return menuSortKey(for: app)
        case .folder(let folder):
            return folder.name
        }
    }

    /// Produces a consistent sort key for app menu entries.
    private func menuSortKey(for app: AppItem) -> String {
        menuDisplayTitle(for: app)
    }

    /// Launches an app when chosen from a menu list.
    @objc private func launchAppFromMenu(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? AppItem,
              let bundleURL = app.bundleURL else { return }

        recordLaunchedApplication(bundleIdentifier: app.bundleIdentifier, application: nil)

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { [weak self] runningApp, _ in
            Task { @MainActor in
                self?.recordLaunchedApplication(bundleIdentifier: app.bundleIdentifier, application: runningApp)
            }
        }
    }
}
