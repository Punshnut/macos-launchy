import AppKit
import Combine
import SwiftUI

/// Backing store responsible for loading apps and persisting launcher settings toggles.
@MainActor
final class SettingsWindowStore: NSObject, ObservableObject {
    /// Latest persisted settings payload mirrored into memory for the UI.
    @Published private(set) var settingsSnapshot: LauncherSettings
    /// Collection of applications discovered on disk for the hidden-apps table.
    @Published private(set) var discoveredApps: [AppItem] = []

    private let appDiscoveryService: AppDiscoveryService
    private var settingsStreamTask: Task<Void, Never>?

    /// Configures the store with dependencies (mainly useful for previews/tests) and preloads data.
    init(discoveryService: AppDiscoveryService = AppDiscoveryService()) {
        self.appDiscoveryService = discoveryService
        self.settingsSnapshot = LauncherSettingsPersistence.loadSettings()
        super.init()
        reloadApps()
        observeSettingsChanges()
    }

    deinit {
        settingsStreamTask?.cancel()
    }

    /// Reloads the list of apps on a background queue.
    func reloadApps() {
        let discoveryEngine = appDiscoveryService
        let includeUserApplications = settingsSnapshot.shouldScanUserApplicationsFolder
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let (mainApps, userApps) = discoveryEngine.reloadApps(
                includeUserApplicationsFolder: includeUserApplications
            )
            let discoveredApps = mainApps + userApps
            Task { @MainActor [weak self] in
                self?.discoveredApps = discoveredApps
            }
        }
    }

    /// Resolves the cached icon for the given app without storing it permanently.
    func icon(for app: AppItem) -> NSImage? {
        appDiscoveryService.resolveIcon(for: app)
    }

    /// Persists the launch-at-login preference and updates the in-memory copy.
    func setLaunchAtLogin(_ newValue: Bool) {
        guard settingsSnapshot.launchesAtLogin != newValue else { return }
        settingsSnapshot.launchesAtLogin = newValue
        LaunchAtLoginManager.setEnabled(newValue)
        LauncherSettingsPersistence.setLaunchAtLogin(newValue)
    }

    /// Persists the preferred background style.
    func setPreferredBackgroundStyle(_ style: LauncherSettings.PreferredBackgroundStyle) {
        guard settingsSnapshot.backgroundStylePreference != style else { return }
        settingsSnapshot.backgroundStylePreference = style
        LauncherSettingsPersistence.setPreferredBackgroundStyle(style)
    }

    /// Persists the chosen solid background color.
    func setSolidBackgroundColor(_ color: LauncherSettings.SolidBackgroundColor) {
        guard settingsSnapshot.solidBackgroundColor != color else { return }
        settingsSnapshot.solidBackgroundColor = color
        LauncherSettingsPersistence.setSolidBackgroundColor(color)
    }

    /// Persists the launcher mode selection.
    func setLauncherMode(_ mode: LauncherMode) {
        guard settingsSnapshot.selectedLauncherMode != mode else { return }
        settingsSnapshot.selectedLauncherMode = mode
        LauncherSettingsPersistence.setLauncherMode(mode)
    }

    /// Persists whether the Dock icon should be hidden in any mode.
    func setDockIconHidden(_ isHidden: Bool) {
        guard settingsSnapshot.isDockIconHidden != isHidden else { return }
        let resolvedHotkey = resolvedLauncherHotkey(
            forDockHidden: isHidden,
            menuHidden: settingsSnapshot.isMenuBarIconHidden,
            requestedHotkey: settingsSnapshot.launcherHotkey
        )
        settingsSnapshot.isDockIconHidden = isHidden
        if settingsSnapshot.launcherHotkey != resolvedHotkey {
            settingsSnapshot.launcherHotkey = resolvedHotkey
        }
        LauncherSettingsPersistence.setDockIconHidden(isHidden)
    }

    /// Persists whether the menu bar status item should be hidden.
    func setMenuBarIconHidden(_ isHidden: Bool) {
        guard settingsSnapshot.isMenuBarIconHidden != isHidden else { return }
        let resolvedHotkey = resolvedLauncherHotkey(
            forDockHidden: settingsSnapshot.isDockIconHidden,
            menuHidden: isHidden,
            requestedHotkey: settingsSnapshot.launcherHotkey
        )
        settingsSnapshot.isMenuBarIconHidden = isHidden
        if settingsSnapshot.launcherHotkey != resolvedHotkey {
            settingsSnapshot.launcherHotkey = resolvedHotkey
        }
        LauncherSettingsPersistence.setMenuBarIconHidden(isHidden)
    }

    /// Persists the selected global hotkey used to toggle Launchy.
    func setLauncherHotkey(_ descriptor: HotkeyDescriptor?) {
        let resolvedHotkey = resolvedLauncherHotkey(requestedHotkey: descriptor)
        guard settingsSnapshot.launcherHotkey != resolvedHotkey else { return }
        settingsSnapshot.launcherHotkey = resolvedHotkey
        LauncherSettingsPersistence.setLauncherHotkey(resolvedHotkey)
    }

    /// Persists the shortcut used to flip between floaty and fullscreen layouts.
    func setLayoutToggleHotkey(_ descriptor: HotkeyDescriptor?) {
        guard settingsSnapshot.layoutToggleHotkey != descriptor else { return }
        settingsSnapshot.layoutToggleHotkey = descriptor
        LauncherSettingsPersistence.setLayoutToggleHotkey(descriptor)
    }

    /// Enables or disables the hot corner trigger.
    func setHotCornerEnabled(_ value: Bool) {
        guard settingsSnapshot.hotCornerEnabled != value else { return }
        settingsSnapshot.hotCornerEnabled = value
        LauncherSettingsPersistence.setHotCornerEnabled(value)
    }

    /// Persists the hot corner selection.
    func setHotCornerPosition(_ position: HotCornerPosition) {
        guard settingsSnapshot.hotCornerPosition != position else { return }
        settingsSnapshot.hotCornerPosition = position
        LauncherSettingsPersistence.setHotCornerPosition(position)
    }

    /// Restores the launcher hotkey back to its default value.
    func resetLauncherHotkeyToDefault() {
        setLauncherHotkey(.toggleLauncher)
    }

    /// Persists whether gaps should be collapsed automatically.
    func setFillsGapsAutomatically(_ value: Bool) {
        guard settingsSnapshot.fillsGapsAutomatically != value else { return }
        settingsSnapshot.fillsGapsAutomatically = value
        LauncherSettingsPersistence.setFillsGapsAutomatically(value)
    }

    /// Requests a full reset of the saved launcher arrangement.
    func requestArrangementReset() {
        NotificationCenter.default.post(name: .launcherArrangementResetRequested, object: nil)
    }

    /// Toggles the bundle identifier in the hidden apps list.
    func setHidden(_ isHidden: Bool, for app: AppItem) {
        var identifiers = Set(settingsSnapshot.hiddenBundleIDs)
        if isHidden {
            identifiers.insert(app.bundleIdentifier)
        } else {
            identifiers.remove(app.bundleIdentifier)
        }
        let sortedIdentifiers = identifiers.sorted()
        guard settingsSnapshot.hiddenBundleIDs != sortedIdentifiers else { return }
        settingsSnapshot.hiddenBundleIDs = sortedIdentifiers
        LauncherSettingsPersistence.setHiddenBundleIdentifiers(sortedIdentifiers)
    }

    /// Determines whether a specific app should be treated as hidden.
    func isHidden(_ app: AppItem) -> Bool {
        settingsSnapshot.hiddenBundleIDs.contains(app.bundleIdentifier)
    }

    /// Controls whether the user's Applications folder is indexed for hidden apps.
    func setShouldScanUserApplicationsFolder(_ value: Bool) {
        guard settingsSnapshot.shouldScanUserApplicationsFolder != value else { return }
        settingsSnapshot.shouldScanUserApplicationsFolder = value
        LauncherSettingsPersistence.setShouldScanUserApplicationsFolder(value)
        reloadApps()
    }

    /// Observes cross-process setting updates and mirrors them locally.
    private func observeSettingsChanges() {
        settingsStreamTask?.cancel()
        settingsStreamTask = Task.detached { [weak self] in
            let notifications = NotificationCenter.default.notifications(named: .launcherSettingsDidChange)
            for await _ in notifications {
                guard let self else { continue }
                await self.reloadSettingsFromDisk()
            }
        }
    }

    /// Reloads the latest settings payload from persistence.
    private func reloadSettingsFromDisk() {
        let previousIncludeUserApplications = settingsSnapshot.shouldScanUserApplicationsFolder
        let updatedSettings = LauncherSettingsPersistence.loadSettings()
        settingsSnapshot = updatedSettings
        if previousIncludeUserApplications != updatedSettings.shouldScanUserApplicationsFolder {
            reloadApps()
        }
    }

    private func resolvedLauncherHotkey(
        forDockHidden dockHidden: Bool? = nil,
        menuHidden: Bool? = nil,
        requestedHotkey: HotkeyDescriptor?
    ) -> HotkeyDescriptor? {
        let dockHiddenValue = dockHidden ?? settingsSnapshot.isDockIconHidden
        let menuHiddenValue = menuHidden ?? settingsSnapshot.isMenuBarIconHidden
        if dockHiddenValue && menuHiddenValue && requestedHotkey == nil {
            return .toggleLauncher
        }
        return requestedHotkey
    }
}
