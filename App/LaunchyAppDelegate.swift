import AppKit
import SwiftUI

/// Coordinates non-SwiftUI lifecycle tasks such as discovery, window management, and menu bar logic.
@MainActor
final class LaunchyAppDelegate: NSObject, NSApplicationDelegate {
    private var launcherWindowManager: LauncherWindowController?
    private var launcherWindowControllersByMode: [LauncherMode: LauncherWindowController] = [:]
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
    private var mainMenuUpdateObserver: NSObjectProtocol?
    private var sparkleUpdateObserver: NSObjectProtocol?
    private var appearanceChangeObserver: NSObjectProtocol?
    private var appearanceObservation: NSKeyValueObservation?
    private var isTrimmingMainMenu = false
    private var applicationDirectoryMonitor: ApplicationDirectoryMonitor?
    private let coreServicesFolderID = UUID(uuidString: "E5F3D7F7-CCE6-4A3E-9EA1-357C39B58F9A")!
    private let systemToolsFolderID = UUID(uuidString: "B7291F1D-45DF-46A0-B84F-8B05626DD3C0")!
    private let coreServicesDirectory = URL(fileURLWithPath: "/System/Library/CoreServices", isDirectory: true)
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
    private var hasHandledInitialActivation = false
    private var shouldAutoPresentOnFirstActivation = false
    private var isAnimatingLauncherHide = false
    private var suppressLauncherRevealOnNextActivation = false
    private var visiblePageWarmupTask: Task<Void, Never>?
    private var pendingFloatyVisibilityCheckID: UUID?
    private var hasUsedFloatyFallback = false
    private var hasScheduledRunloopProbe = false
    private var loggedHiddenWindowReasons: Set<String> = []
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var pendingRemovalDeadlines: [String: Date] = [:]
    private var pendingRemovalApps: [String: AppItem] = [:]
    private var removalConfirmationTimer: DispatchSourceTimer?
    private let removalGracePeriod: TimeInterval = 6
    private var memoryMaintenanceTimer: DispatchSourceTimer?
    private let memoryMaintenanceInterval: TimeInterval = 180
    private let idleTrimGracePeriod: TimeInterval = 70
    private let visibleTrimGracePeriod: TimeInterval = 120
    private let elevatedMemoryThreshold: UInt64 = 650 * 1024 * 1024
    private let criticalMemoryThreshold: UInt64 = 850 * 1024 * 1024
    private var lastLauncherVisibilityChange = Date()

    /// Finishes bootstrapping the app by loading settings, refreshing apps, and preparing the window.
    func applicationDidFinishLaunching(_ notification: Notification) {
        LaunchyLogger.startup()
        LaunchyLogger.log("applicationDidFinishLaunching")
        bootstrapApplication()
        enforceMinimalMainMenu()
        scheduleFloatyStartupPresentationIfNeeded()
        scheduleRunloopProbes(label: "post-launch")
    }

    /// Reapplies menu pruning after the app is foregrounded.
    func applicationDidBecomeActive(_ notification: Notification) {
        enforceMinimalMainMenu()

        if hasHandledInitialActivation == false {
            hasHandledInitialActivation = true
            if shouldAutoPresentOnFirstActivation {
                showLauncherWindowAfterActivation()
            }
            return
        }

        if suppressLauncherRevealOnNextActivation {
            suppressLauncherRevealOnNextActivation = false
            return
        }

        guard launcherWindowManager?.window?.isVisible != true else {
            return
        }

        showLauncherWindowAfterActivation()
    }

    /// Captures the previously focused app so focus can be restored after showing Launchy.
    func applicationWillBecomeActive(_ notification: Notification) {
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.isTerminated == false,
              let bundleID = Bundle.main.bundleIdentifier,
              frontmost.bundleIdentifier != bundleID else {
            return
        }

        lastFocusedApplication = frontmost
    }

    /// Hides the launcher when Launchy loses focus (e.g., user clicks away).
    func applicationDidResignActive(_ notification: Notification) {
        hideLauncherWindow(restoreFocus: false)
    }

    /// Reopens the launcher when the Dock icon is clicked while the app is already running.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if flag {
            refocusLauncherWindowIfVisible()
        } else {
            showLauncherWindowAfterActivation()
        }
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
        launcherWindowManager?.close()
        for controller in launcherWindowControllersByMode.values {
            controller.close()
        }
        launcherWindowControllersByMode.removeAll()
        if let observer = mainMenuUpdateObserver {
            NotificationCenter.default.removeObserver(observer)
            mainMenuUpdateObserver = nil
        }
        if let observer = sparkleUpdateObserver {
            NotificationCenter.default.removeObserver(observer)
            sparkleUpdateObserver = nil
        }
        if let observer = appearanceChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            appearanceChangeObserver = nil
        }
        appearanceObservation?.invalidate()
        appearanceObservation = nil
        memoryPressureSource?.cancel()
        memoryPressureSource = nil
        memoryMaintenanceTimer?.cancel()
        memoryMaintenanceTimer = nil
        visiblePageWarmupTask?.cancel()
        visiblePageWarmupTask = nil
        removalConfirmationTimer?.cancel()
        removalConfirmationTimer = nil
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
        LaunchyLogger.log("bootstrap: initializing launcher")
        // Prime defaults and load persisted settings before wiring anything else.
        LauncherSettingsPersistence.registerDefaults()
        currentSettings = LauncherSettingsPersistence.loadSettings()
        configureApplicationDirectoryMonitoring()
        applicationDiscovery.handleAppearanceChange(NSApp.effectiveAppearance)
        LaunchAtLoginManager.setEnabled(currentSettings.launchesAtLogin)

        LaunchyLogger.log("bootstrap: loading apps (hidden=\(currentSettings.hiddenBundleIDs.count) scanUser=\(currentSettings.shouldScanUserApplicationsFolder))")
        // Discover apps using the latest hidden/background choices so the first render is accurate.
        refreshLauncherItems()

        LaunchyLogger.log("bootstrap: applying launcher mode")
        // Prepare the launcher window in the background so the hotkey can surface it instantly.
        applyLauncherMode(shouldPresentWindow: false)

        LaunchyLogger.log("bootstrap: configuring hotkeys")
        // Wire global hotkeys after settings are loaded so they reflect the latest bindings.
        configureHotkeyManagers()

        LaunchyLogger.log("bootstrap: refreshing UI chrome and monitoring")
        updateStatusItemVisibility()
        updateHotCornerMonitoring()
        observeSettingsChanges()
        observeArrangementResetRequests()
        observeAppearanceChanges()
        showIntroductionIfNeeded()
        observeMainMenuChanges()
        observeSparkleUpdateNotifications()
        setupMemoryPressureMonitoring()
        setupMemoryMaintenanceTimer()
    }

    /// Double-checks that unused menu bar items are stripped even if AppKit rebuilds the menu.
    private func enforceMinimalMainMenu() {
        removeDefaultMainMenuItems()

        Task { @MainActor [weak self] in
            await Task.yield()
            self?.removeDefaultMainMenuItems()
        }
    }

    /// Presents the launcher shortly after launch when floaty is selected so the app does not feel hung.
    private func scheduleFloatyStartupPresentationIfNeeded() {
        guard currentSettings.selectedLauncherMode == .floaty else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.launcherWindowManager == nil {
                self.applyLauncherMode(shouldPresentWindow: false)
            }
            guard let controller = self.launcherWindowManager else { return }
            if controller.window?.isVisible == true {
                return
            }
            self.activateApplicationForCurrentModeIfNeeded()
            self.presentLauncherWindow(reason: "startup-floaty")
            self.prefetchMinimalIconsForVisibleLauncher()
            NotificationCenter.default.post(name: .launcherDidShow, object: nil)
            self.markLauncherDidShow()
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

    /// Listens for Sparkle UI presentation so we can gracefully hide the launcher first.
    private func observeSparkleUpdateNotifications() {
        sparkleUpdateObserver = NotificationCenter.default.addObserver(
            forName: .sparkleWillPresentUpdateUI,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleSparkleWillPresentUpdateUI()
            }
        }
    }

    /// Rebuilds appearance-sensitive caches when macOS toggles light/dark mode.
    private func observeAppearanceChanges() {
        appearanceObservation?.invalidate()
        appearanceObservation = NSApp.observe(
            \.effectiveAppearance,
            options: [.new]
        ) { [weak self] _, change in
            Task { @MainActor [weak self] in
                guard let self else { return }
                applicationDiscovery.handleAppearanceChange(NSApp.effectiveAppearance)
                if launcherWindowManager?.window?.isVisible == true {
                    prefetchMinimalIconsForVisibleLauncher()
                }
            }
        }
    }

    /// Closes the launcher before Sparkle presents a modal to avoid overlapping windows.
    private func handleSparkleWillPresentUpdateUI() {
        suppressLauncherRevealOnNextActivation = true

        guard let window = launcherWindowManager?.window, window.isVisible else {
            return
        }
        hideLauncherWindow(restoreFocus: false)
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

    /// Responds to system memory pressure by trimming caches and canceling warmups.
    private func setupMemoryPressureMonitoring() {
        memoryPressureSource?.cancel()
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            self.handleMemoryPressure(event: source.data)
        }
        source.resume()
        memoryPressureSource = source
    }

    /// Clears expensive caches and cancels in-flight warmups when the system signals low memory.
    private func handleMemoryPressure(event: DispatchSource.MemoryPressureEvent) {
        LaunchyLogger.log("memory pressure event: \(event.rawValue)")
        visiblePageWarmupTask?.cancel()
        applicationDiscovery.shrinkCachesForHiddenLauncher()
        NotificationCenter.default.post(name: .launcherShouldPurgeVisualCaches, object: nil)
    }

    /// Periodically trims caches while the launcher is idle so the footprint stays bounded over time.
    private func setupMemoryMaintenanceTimer() {
        memoryMaintenanceTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + idleTrimGracePeriod, repeating: memoryMaintenanceInterval)
        timer.setEventHandler { [weak self] in
            self?.performScheduledMemoryMaintenance()
        }
        timer.resume()
        memoryMaintenanceTimer = timer
    }

    /// Applies gentle or aggressive cache trimming based on visibility and current footprint.
    private func performScheduledMemoryMaintenance() {
        let now = Date()
        let footprint = MemoryFootprint.currentResidentSize()
        let isLauncherVisible = launcherWindowManager?.window?.isVisible == true
        let idleDuration = now.timeIntervalSince(lastLauncherVisibilityChange)
        let aggressive = (footprint ?? 0) >= criticalMemoryThreshold
        let aboveTarget = (footprint ?? 0) >= elevatedMemoryThreshold

        let shouldTrimWhileVisible = aggressive || (aboveTarget && idleDuration >= visibleTrimGracePeriod)
        let shouldTrimWhileHidden = isLauncherVisible == false && idleDuration >= idleTrimGracePeriod
        let shouldTrim = shouldTrimWhileVisible || shouldTrimWhileHidden

        guard shouldTrim else { return }

        let cacheLimitScale: Double
        if aggressive {
            cacheLimitScale = isLauncherVisible ? 0.38 : 0.3
        } else if aboveTarget {
            cacheLimitScale = isLauncherVisible ? 0.55 : 0.42
        } else {
            cacheLimitScale = isLauncherVisible ? 0.8 : 0.6
        }
        applicationDiscovery.applyCacheLimitScaling(cacheLimitScale)

        let keepLimit = isLauncherVisible
            ? LauncherGridConfiguration.pageCapacity
            : max(LauncherGridConfiguration.pageCapacity / 2, 8)
        let keepApps = prioritizedAppsForPrefetch(limit: keepLimit)
        let keepBundleIDs = Set(keepApps.map(\.bundleIdentifier))
        let idleInterval = isLauncherVisible ? visibleTrimGracePeriod : idleTrimGracePeriod

        applicationDiscovery.trimCaches(
            keeping: keepBundleIDs,
            aggressively: aggressive,
            idleOnlyAfter: idleInterval
        )

        if aggressive {
            visiblePageWarmupTask?.cancel()
            NotificationCenter.default.post(name: .launcherShouldPurgeVisualCaches, object: nil)
        }

        let footprintInMB = footprint.map { $0 / 1_048_576 } ?? 0
        let scaleLabel = String(format: "%.2f", cacheLimitScale)
        LaunchyLogger.log("memory maintenance trimmed caches (aggressive=\(aggressive) footprintMB=\(footprintInMB) keep=\(keepBundleIDs.count) limitScale=\(scaleLabel))")
    }

    /// Applies the current launcher mode, rebuilding the window when the persisted value changes.
    func applyLauncherMode(shouldPresentWindow: Bool = true) {
        LaunchyLogger.log("applyLauncherMode: mode=\(currentSettings.selectedLauncherMode) shouldPresentWindow=\(shouldPresentWindow)")
        let mode = currentSettings.selectedLauncherMode
        let modeChanged = currentLauncherMode != mode
        currentLauncherMode = mode
        if modeChanged {
            hasUsedFloatyFallback = false
            pendingFloatyVisibilityCheckID = nil
        }
        shouldAutoPresentOnFirstActivation = mode == .floaty || (currentSettings.isDockIconHidden && currentSettings.isMenuBarIconHidden)
        let shouldActivateApp = shouldPresentWindow && (modeChanged || launcherWindowManager?.window?.isVisible == true)
        updateActivationPolicy(for: mode, shouldActivate: shouldActivateApp)

        if modeChanged == false, let controller = launcherWindowManager {
            LaunchyLogger.log("applyLauncherMode: updating existing window controller")
            controller.update(rootView: buildLauncherView())
        } else {
            LaunchyLogger.log("applyLauncherMode: rebuilding window controller for mode \(mode)")
            rebuildWindow(for: mode, shouldPresentWindow: shouldPresentWindow)
        }

        preheatIconsForCurrentLayout()
        if shouldPresentWindow == false {
            scheduleRunloopProbes(label: "post-apply-\(mode.rawValue)")
        }
    }

    /// Creates a fresh `LauncherWindowController` using the provided mode.
    private func rebuildWindow(for mode: LauncherMode, shouldPresentWindow: Bool) {
        let view = buildLauncherView()
        let controller = launcherWindowController(for: mode, rootView: view)
        let previousController = launcherWindowManager
        launcherWindowManager = controller

        if shouldPresentWindow {
            let skipAnimation = previousController?.window?.isVisible == true
            presentLauncherWindow(skipEntranceAnimation: skipAnimation, reason: "rebuildWindow")
            prefetchMinimalIconsForVisibleLauncher()
            NotificationCenter.default.post(name: .launcherDidShow, object: nil)
            markLauncherDidShow()
            previousController?.window?.orderOut(nil)
        }
    }

    /// Returns a cached launcher controller when available, reusing window instances per mode.
    private func launcherWindowController(for mode: LauncherMode, rootView: LauncherView) -> LauncherWindowController {
        if let existing = launcherWindowControllersByMode[mode] {
            existing.update(rootView: rootView)
            return existing
        }
        let controller = LauncherWindowController(rootView: rootView, launcherMode: mode)
        launcherWindowControllersByMode[mode] = controller
        return controller
    }

    /// Presents the launcher window and verifies floaty presentation so the app does not appear hung.
    private func presentLauncherWindow(
        skipEntranceAnimation: Bool = false,
        reason: String
    ) {
        guard let controller = launcherWindowManager else { return }
        controller.presentWindow(skipEntranceAnimation: skipEntranceAnimation)
        verifyFloatyVisibilityIfNeeded(reason: reason, controller: controller)
        scheduleRunloopProbes(label: "post-present-\(reason)")
        if let window = controller.window {
            logWindowIfHidden(window, reason: reason)
        }
    }

    /// Checks whether the floaty panel actually became visible; falls back to fullscreen if not.
    private func verifyFloatyVisibilityIfNeeded(
        reason: String,
        controller: LauncherWindowController
    ) {
        guard controller.mode == .floaty else {
            pendingFloatyVisibilityCheckID = nil
            return
        }
        guard hasUsedFloatyFallback == false else { return }

        let checkID = UUID()
        pendingFloatyVisibilityCheckID = checkID

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self, weak controller] in
            guard let self else { return }
            guard self.pendingFloatyVisibilityCheckID == checkID else { return }
            guard let window = controller?.window else { return }

            let isVisible = window.isVisible
            let isOnscreen = window.occlusionState.contains(.visible)
            let alpha = window.alphaValue

            if isVisible && isOnscreen && alpha > 0.8 {
                self.pendingFloatyVisibilityCheckID = nil
                return
            }

            window.alphaValue = 1
            window.makeKeyAndOrderFront(nil)
            self.pendingFloatyVisibilityCheckID = nil
            self.hasUsedFloatyFallback = true
            LaunchyLogger.error("Floaty window did not appear after present (\(reason)); visible=\(isVisible) onscreen=\(isOnscreen) alpha=\(alpha)")
            self.fallbackToFullscreenAfterFloatyFailure(trigger: reason, window: window)
        }
    }

    /// Switches to fullscreen mode when floaty fails to surface so users are not stuck with no UI.
    private func fallbackToFullscreenAfterFloatyFailure(trigger: String, window: NSWindow? = nil) {
        guard currentSettings.selectedLauncherMode == .floaty else { return }

        LaunchyLogger.error("Falling back to fullscreen because floaty presentation failed (\(trigger))")
        currentSettings.selectedLauncherMode = .fullscreen
        LauncherSettingsPersistence.setLauncherMode(.fullscreen)
        applyLauncherMode()
        ensureEscapeHatchUI(lastWindow: window)
    }

    /// Ensures at least one UI affordance remains reachable even when floaty fails.
    private func ensureEscapeHatchUI(lastWindow: NSWindow?) {
        updateStatusItemVisibility()
        NSApp.setActivationPolicy(.regular)
        if lastWindow?.isVisible != true {
            NSApp.activate(ignoringOtherApps: true)
        }
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
        LaunchyLogger.log("updateStatusItemVisibility: menuBarIconVisible=\(currentSettings.isMenuBarIconVisible)")
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
        LaunchyLogger.log("status item created")
        if statusBarItem == nil || statusBarItem?.button == nil || statusBarItem?.button?.image == nil {
            let button = statusBarItem?.button
            let image = button?.image
            let size = image?.size ?? .zero
            LaunchyLogger.error("Status item missing visuals statusItem=\(statusBarItem != nil) button=\(button != nil) image=\(image != nil) size=\(size)")
        }
    }

    /// Removes the status bar item if one has been created.
    private func removeStatusItem() {
        if let item = statusBarItem {
            NSStatusBar.system.removeStatusItem(item)
            statusBarItem = nil
        }
        statusBarMenu = nil
        LaunchyLogger.log("status item removed")
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

    /// Schedules quick main-thread probes to confirm the run loop is advancing.
    private func scheduleRunloopProbes(label: String) {
        guard hasScheduledRunloopProbe == false else { return }
        hasScheduledRunloopProbe = true
        DispatchQueue.main.async {
            LaunchyLogger.log("runloop probe immediate \(label)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            LaunchyLogger.log("runloop probe delayed \(label)")
        }
    }

    /// Logs window state when it fails to become visible after presentation.
    private func logWindowIfHidden(_ window: NSWindow, reason: String) {
        guard window.isVisible == false || window.occlusionState.contains(.visible) == false else { return }
        guard loggedHiddenWindowReasons.insert(reason).inserted else { return }

        LaunchyLogger.error(
            "Window hidden after present (\(reason)) visible=\(window.isVisible) mini=\(window.isMiniaturized) alpha=\(window.alphaValue) occlusion=\(window.occlusionState.rawValue) level=\(window.level.rawValue) behaviors=\(window.collectionBehavior.rawValue) canKey=\(window.canBecomeKey) canMain=\(window.canBecomeMain)"
        )
    }

    /// Handles work that needs to happen after settings mutate elsewhere.
    @MainActor
    private func handleSettingsChange() {
        let previousHidden = Set(currentSettings.hiddenBundleIDs)
        let previousGapSetting = currentSettings.fillsGapsAutomatically
        let previousUserApplicationsScan = currentSettings.shouldScanUserApplicationsFolder
        let previousSpecialHiddenEntries = Set(currentSettings.hiddenSpecialEntryIDs)
        let previousLauncherHotkey = currentSettings.launcherHotkey
        let previousLayoutHotkey = currentSettings.layoutToggleHotkey
        currentSettings = LauncherSettingsPersistence.loadSettings()
        LaunchAtLoginManager.setEnabled(currentSettings.launchesAtLogin)
        let hiddenChanged = previousHidden != Set(currentSettings.hiddenBundleIDs)
        let gapSettingChanged = previousGapSetting != currentSettings.fillsGapsAutomatically
        let scanSettingChanged = previousUserApplicationsScan != currentSettings.shouldScanUserApplicationsFolder
        let specialEntryChanged = previousSpecialHiddenEntries != Set(currentSettings.hiddenSpecialEntryIDs)
        let hotkeysChanged = previousLauncherHotkey != currentSettings.launcherHotkey
            || previousLayoutHotkey != currentSettings.layoutToggleHotkey
        if scanSettingChanged {
            configureApplicationDirectoryMonitoring()
        }
        if hiddenChanged || gapSettingChanged || scanSettingChanged || specialEntryChanged {
            refreshLauncherItems()
        }
        applyLauncherMode()
        updateStatusItemVisibility()
        if hotkeysChanged {
            refreshHotkeyRegistrations()
        }
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
            directories: directories,
            pollingInterval: 12
        ) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                let isVisible = self.launcherWindowManager?.window?.isVisible == true
                let didChange = self.refreshLauncherItems(shouldPreheatIcons: isVisible)
                if didChange {
                    self.launcherWindowManager?.update(rootView: self.buildLauncherView())
                }
            }
        }
    }

    /// Mirrors the same directories AppDiscoveryService inspects.
    private func monitoredApplicationDirectories() -> [URL] {
        var directories: [URL] = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true)
        ]

        let cryptexPaths = [
            "/System/Volumes/Preboot/Cryptexes/App/System/Applications",
            "/System/Cryptexes/App/System/Applications"
        ]
        for path in cryptexPaths {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) {
                directories.append(url)
            }
        }

        if currentSettings.shouldScanUserApplicationsFolder {
            let userApps = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications", isDirectory: true)
            directories.append(userApps)
        }

        directories.append(coreServicesDirectory)

        return uniqueDirectories(from: directories)
    }

    private func uniqueDirectories(from directories: [URL]) -> [URL] {
        var seen: Set<String> = []
        var unique: [URL] = []
        for directory in directories {
            let standardized = directory.standardizedFileURL
            guard seen.insert(standardized.path).inserted else { continue }
            unique.append(standardized)
        }
        return unique
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
        LaunchyLogger.log("configureHotkeyManagers: launcherHotkey=\(String(describing: currentSettings.launcherHotkey)) layoutHotkey=\(String(describing: currentSettings.layoutToggleHotkey))")
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
        LaunchyLogger.log("refreshHotkeyRegistrations: applying hotkeys")
        launcherHotkeyManager.update(descriptor: currentSettings.launcherHotkey)
        launcherHotkeyManager.activate()

        layoutHotkeyManager.update(descriptor: currentSettings.layoutToggleHotkey)
        layoutHotkeyManager.activate()
    }

    /// Enables or disables the hot-corner trigger using the latest settings payload.
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

    private func markLauncherDidShow() {
        applicationDiscovery.applyCacheLimitScaling(1)
        lastLauncherVisibilityChange = Date()
    }

    private func markLauncherDidHide() {
        lastLauncherVisibilityChange = Date()
    }

    /// Shows or hides the launcher window whenever the hotkey fires.
    private func toggleLauncherVisibility() {
        if launcherWindowManager == nil {
            applyLauncherMode(shouldPresentWindow: false)
        }

        guard let launcherWindowManager else { return }

        guard let window = launcherWindowManager.window else {
            recordFrontmostApplicationForRestoration()
            presentLauncherWindow(reason: "toggleVisibility-windowMissing")
            prefetchMinimalIconsForVisibleLauncher()
            markLauncherDidShow()
            return
        }

        if window.isVisible {
            hideLauncherWindow(restoreFocus: true)
        } else {
            recordFrontmostApplicationForRestoration()
            activateApplicationForCurrentModeIfNeeded()
            presentLauncherWindow(reason: "toggleVisibility-show")
            prefetchMinimalIconsForVisibleLauncher()
            NotificationCenter.default.post(name: .launcherDidShow, object: nil)
            markLauncherDidShow()
        }
    }

    /// Hides the launcher window and optionally restores the previously focused app.
    private func hideLauncherWindow(restoreFocus: Bool) {
        pendingFloatyVisibilityCheckID = nil
        fadeOutLauncherWindow(restoreFocus: restoreFocus)
    }

    /// Animates the launcher window out and handles cache/focus cleanup.
    func fadeOutLauncherWindow(
        restoreFocus: Bool,
        completion: @escaping @MainActor () -> Void = {}
    ) {
        guard let controller = launcherWindowManager,
              let window = controller.window,
              window.isVisible else {
            completion()
            return
        }
        guard isAnimatingLauncherHide == false else {
            completion()
            return
        }

        isAnimatingLauncherHide = true
        controller.fadeOutWindow { @MainActor [weak self] in
            guard let self else { return }
            isAnimatingLauncherHide = false
            shrinkIconCachesForHiddenLauncher()
            markLauncherDidHide()
            NotificationCenter.default.post(name: .launcherDidHide, object: nil)
            if restoreFocus {
                focusPreferredApplicationAfterLauncherHides()
            }
            completion()
        }
    }

    /// Shows the launcher after the system activates the app (e.g., via Cmd+Tab).
    private func showLauncherWindowAfterActivation() {
        if launcherWindowManager == nil {
            applyLauncherMode(shouldPresentWindow: false)
        }

        guard let controller = launcherWindowManager else { return }

        if let window = controller.window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return
        }

        activateApplicationForCurrentModeIfNeeded()
        presentLauncherWindow(reason: "activation")
        prefetchMinimalIconsForVisibleLauncher()
        NotificationCenter.default.post(name: .launcherDidShow, object: nil)
        markLauncherDidShow()
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
        presentLauncherWindow(reason: "statusItem-show")
        prefetchMinimalIconsForVisibleLauncher()
        NotificationCenter.default.post(name: .launcherDidShow, object: nil)
        markLauncherDidShow()
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

    /// Releases cached icon memory after the launcher hides.
    func shrinkIconCachesForHiddenLauncher() {
        applicationDiscovery.shrinkCachesForHiddenLauncher()
    }

    /// Warms a tiny set of low/medium icons so the first page appears quickly after reopening.
    private func prefetchMinimalIconsForVisibleLauncher() {
        let limit = LauncherGridConfiguration.pageCapacity
        let apps = prioritizedAppsForPrefetch(limit: limit)
        guard apps.isEmpty == false else { return }
        applicationDiscovery.preheatIcons(
            for: apps,
            targetDimension: preferredIconRenderDimension(for: currentSettings.selectedLauncherMode),
            qualities: [.low],
            limit: limit
        )
    }

    /// Warms icons for the currently visible pages to avoid visual pop-in while paging.
    private func warmVisiblePageIcons(_ apps: [AppItem]) {
        visiblePageWarmupTask?.cancel()
        let uniqueApps = uniqueAppsByBundleID(apps)
        guard uniqueApps.isEmpty == false else { return }
        let dimension = preferredIconRenderDimension(for: currentSettings.selectedLauncherMode)
        let limit = min(uniqueApps.count, LauncherGridConfiguration.pageCapacity * 2)
        visiblePageWarmupTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard Task.isCancelled == false else { return }
            let slice = Array(uniqueApps.prefix(limit))
            applicationDiscovery.preheatIcons(
                for: slice,
                targetDimension: dimension,
                qualities: [.low, .medium],
                limit: limit
            )
        }
    }

    /// Deduplicates apps by bundle identifier while preserving the first occurrence order.
    private func uniqueAppsByBundleID(_ apps: [AppItem]) -> [AppItem] {
        var seen = Set<String>()
        var unique: [AppItem] = []
        for app in apps {
            if seen.insert(app.bundleIdentifier).inserted {
                unique.append(app)
            }
        }
        return unique
    }

    /// Flattens folders and root items into a bundle-ID keyed dictionary.
    private func appsByBundleID(from items: [LauncherItem]) -> [String: AppItem] {
        var lookup: [String: AppItem] = [:]
        for item in items {
            switch item {
            case .app(let app):
                lookup[app.bundleIdentifier] = app
            case .folder(let folder):
                for app in folder.apps {
                    lookup[app.bundleIdentifier] = app
                }
            }
        }
        return lookup
    }

    /// Discards temporary grace-period entries whose deadlines have elapsed.
    private func purgeExpiredPendingRemovals(referenceDate: Date) -> Set<String> {
        let expired = pendingRemovalDeadlines.filter { $0.value <= referenceDate }.map(\.key)
        for bundleID in expired {
            pendingRemovalDeadlines[bundleID] = nil
            pendingRemovalApps[bundleID] = nil
        }
        return Set(expired)
    }

    /// Schedules a timer to re-run discovery once pending removals are past their grace window.
    private func scheduleRemovalConfirmationTimer() {
        removalConfirmationTimer?.cancel()
        removalConfirmationTimer = nil
        guard let soonestDeadline = pendingRemovalDeadlines.values.min() else { return }
        let delay = max(soonestDeadline.timeIntervalSinceNow, 0)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + delay + 0.05, repeating: .never)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.removalConfirmationTimer?.cancel()
            self.removalConfirmationTimer = nil
            self.refreshLauncherItems()
        }
        timer.resume()
        removalConfirmationTimer = timer
    }

    /// Opens the settings window regardless of activation policy.
    func showSettingsWindow(selecting tab: SettingsTab = .visuals) {
        settingsWindowPresenter.showWindowAndActivate(selecting: tab)
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
    @discardableResult
    private func refreshLauncherItems(
        preservingCustomNames names: [String: String] = [:],
        shouldPreheatIcons: Bool = true
    ) -> Bool {
        LaunchyLogger.log("refreshLauncherItems: preserving names=\(names.count)")
        let previousItems = orderedItems
        let previousPageSizes = pageSizes
        let now = Date()
        let expiredPendingRemovals = purgeExpiredPendingRemovals(referenceDate: now)
        var previouslyVisibleApps = appsByBundleID(from: orderedItems)
        for bundleID in expiredPendingRemovals {
            previouslyVisibleApps.removeValue(forKey: bundleID)
        }
        let hiddenBundleIDs = Set(currentSettings.hiddenBundleIDs)
        for bundleID in hiddenBundleIDs {
            pendingRemovalDeadlines[bundleID] = nil
            pendingRemovalApps[bundleID] = nil
        }
        let includeUserApplications = currentSettings.shouldScanUserApplicationsFolder
        let (baseApps, userApps) = applicationDiscovery.reloadApps(
            includeUserApplicationsFolder: includeUserApplications,
            hiddenBundleIDs: hiddenBundleIDs
        )
        let discoveredApps = baseApps + userApps
        let discoveredBundleIDs = Set(discoveredApps.map(\.bundleIdentifier))

        for bundleID in discoveredBundleIDs {
            pendingRemovalDeadlines[bundleID] = nil
            pendingRemovalApps[bundleID] = nil
        }

        let missingBundleIDs = Set(previouslyVisibleApps.keys)
            .subtracting(discoveredBundleIDs)
            .subtracting(hiddenBundleIDs)
        for bundleID in missingBundleIDs {
            if includeUserApplications == false,
               previouslyVisibleApps[bundleID]?.isUserApplication == true {
                continue
            }
            guard pendingRemovalDeadlines[bundleID] == nil else { continue }
            pendingRemovalDeadlines[bundleID] = now.addingTimeInterval(removalGracePeriod)
            pendingRemovalApps[bundleID] = previouslyVisibleApps[bundleID]
        }

        let graceApps = pendingRemovalApps.compactMap { entry -> AppItem? in
            let (bundleID, app) = entry
            guard discoveredBundleIDs.contains(bundleID) == false else { return nil }
            guard let deadline = pendingRemovalDeadlines[bundleID], deadline > now else { return nil }
            return app
        }
        LaunchyLogger.log("app discovery results: base=\(baseApps.count), user=\(userApps.count)")
        let decoratedBaseApps = baseApps + graceApps.filter { $0.isUserApplication == false }
        let decoratedUserApps = (userApps + graceApps.filter(\.isUserApplication)).map { app -> AppItem in
            var modified = app
            if let custom = names[app.bundleIdentifier] {
                modified.customName = custom
            }
            return modified
        }
        let coreServicesApps = decoratedBaseApps.filter(\.isCoreServiceApplication)
        let coreServicesWithIcon = coreServicesApps.filter(\.hasCustomIcon)
        let systemToolsApps = coreServicesApps.filter { $0.hasCustomIcon == false }
        let arrangedBaseApps = decoratedBaseApps.filter { $0.isCoreServiceApplication == false }
        let arrangementSource = arrangedBaseApps + decoratedUserApps

        let (items, sizes) = itemOrderStore.arrangedItems(
            from: arrangementSource,
            pageCapacity: LauncherGridConfiguration.pageCapacity,
            fillsGapsAutomatically: currentSettings.fillsGapsAutomatically,
            preferredCustomNames: names
        )

        var arrangedItems = items
        var arrangedSizes = sizes
        let hiddenSpecialEntries = Set(currentSettings.hiddenSpecialEntryIDs)
        let isCoreServicesFolderHidden = hiddenSpecialEntries.contains(HiddenSpecialEntryIdentifiers.coreServicesFolder)
        let isSystemToolsFolderHidden = hiddenSpecialEntries.contains(HiddenSpecialEntryIdentifiers.systemToolsFolder)
        arrangedItems.removeAll { item in
            if case .folder(let folder) = item {
                return folder.id == coreServicesFolderID || folder.id == systemToolsFolderID
            }
            return false
        }

        if isCoreServicesFolderHidden == false,
           coreServicesWithIcon.isEmpty == false
        {
            let folder = FolderItem(
                id: coreServicesFolderID,
                name: "macOS",
                apps: coreServicesWithIcon
            )
            arrangedItems.append(.folder(folder))
            arrangedSizes = pageSizesAfterAppendingItem(arrangedSizes)
        }

        if isSystemToolsFolderHidden == false,
           systemToolsApps.isEmpty == false
        {
            let folder = FolderItem(
                id: systemToolsFolderID,
                name: "macOS system tools",
                apps: systemToolsApps
            )
            arrangedItems.append(.folder(folder))
            arrangedSizes = pageSizesAfterAppendingItem(arrangedSizes)
        }

        orderedItems = arrangedItems
        pageSizes = arrangedSizes
        let didChange = orderedItems != previousItems || pageSizes != previousPageSizes
        LaunchyLogger.log("refreshLauncherItems: totalLauncherItems=\(orderedItems.count), pages=\(pageSizes.count)")
        if shouldPreheatIcons {
            preheatIconsForCurrentLayout()
        }
        scheduleRemovalConfirmationTimer()
        return didChange
    }

    private func preheatIconsForCurrentLayout() {
        let dimension = preferredIconRenderDimension(for: currentSettings.selectedLauncherMode)
        let limit = LauncherGridConfiguration.pageCapacity * 2
        let apps = prioritizedAppsForPrefetch(limit: limit)
        guard apps.isEmpty == false else { return }
        applicationDiscovery.preheatIcons(
            for: apps,
            targetDimension: dimension,
            qualities: [.low, .medium],
            limit: limit
        )
    }

    private func preferredIconRenderDimension(for mode: LauncherMode) -> CGFloat {
        switch mode {
        case .floaty:
            return 102
        case .fullscreen:
            return 140
        }
    }

    private func prioritizedAppsForPrefetch(limit: Int) -> [AppItem] {
        var seen = Set<String>()
        var prioritized: [AppItem] = []

        func appendIfNeeded(_ app: AppItem) {
            guard prioritized.count < limit else { return }
            if seen.insert(app.bundleIdentifier).inserted {
                prioritized.append(app)
            }
        }

        for item in orderedItems {
            switch item {
            case .app(let app):
                appendIfNeeded(app)
            case .folder(let folder):
                for app in folder.apps {
                    appendIfNeeded(app)
                }
            }
            if prioritized.count >= limit {
                break
            }
        }

        return prioritized
    }

    private func pageSizesAfterAppendingItem(_ sizes: [Int]) -> [Int] {
        var updated = sizes
        let capacity = LauncherGridConfiguration.pageCapacity
        guard capacity > 0 else {
            return updated
        }

        if updated.isEmpty {
            return [1]
        }

        if let last = updated.last, last < capacity {
            updated[updated.count - 1] += 1
        } else {
            updated.append(1)
        }

        return updated
    }

    private func itemsExcludingAutoGeneratedFolders(from items: [LauncherItem]) -> [LauncherItem] {
        items.filter { item in
            if case .folder(let folder) = item {
                return folder.id != coreServicesFolderID && folder.id != systemToolsFolderID
            }
            return true
        }
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
            },
            onAppInfoRequested: { [weak self] in
                self?.showSettingsWindow(selecting: .about)
            },
            onItemOrderChange: { [weak self] reorderedItems, newPageSizes in
                guard let self else { return }
                self.orderedItems = reorderedItems
                self.pageSizes = newPageSizes
                let filteredItems = self.itemsExcludingAutoGeneratedFolders(from: reorderedItems)
                self.itemOrderStore.saveOrderedItems(filteredItems, pageSizes: newPageSizes)
            },
            onVisiblePagesChanged: { [weak self] apps in
                self?.warmVisiblePageIcons(apps)
            },
            iconProvider: { [weak self] app, dimension, quality in
                guard let self else { return nil }
                return self.applicationDiscovery.preparedIcon(
                    for: app,
                    targetDimension: dimension,
                    quality: quality
                )
            }
        )
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
