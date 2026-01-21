import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Row model representing an app in the Hidden Apps preferences list.
struct HiddenAppsListEntry: Identifiable {
    let id: String
    let icon: NSImage?
    let title: String
    let subtitle: String?
    let isHidden: Bool
    let toggle: (Bool) -> Void
}

/// Backing store responsible for loading apps and persisting launcher settings toggles.
@MainActor
final class SettingsWindowStore: NSObject, ObservableObject {
    /// Latest persisted settings payload mirrored into memory for the UI.
    @Published private(set) var settingsSnapshot: LauncherSettings
    /// Collection of applications discovered on disk for the hidden-apps table.
    @Published private(set) var discoveredApps: [AppItem] = []

    private let appDiscoveryService: AppDiscoveryService
    private var settingsStreamTask: Task<Void, Never>?
    private var isDormant = true

    /// Configures the store with dependencies (mainly useful for previews/tests) and preloads data.
    init(discoveryService: AppDiscoveryService = AppDiscoveryService()) {
        self.appDiscoveryService = discoveryService
        self.settingsSnapshot = LauncherSettingsPersistence.loadSettings()
        super.init()
    }

    @MainActor deinit {
        prepareForDormancy()
    }

    /// Reloads the list of apps on a background queue.
    func reloadApps() {
        guard isDormant == false else { return }
        // AppDiscoveryService leans on AppKit types and shared caches, so keep calls on the main
        // actor to avoid thread-hopping crashes that happen when the settings window reloads.
        let includeUserApplications = settingsSnapshot.shouldScanUserApplicationsFolder
        let (mainApps, userApps) = appDiscoveryService.reloadApps(
            includeUserApplicationsFolder: includeUserApplications
        )
        discoveredApps = mainApps + userApps
    }

    /// Resolves the cached icon for the given app without storing it permanently.
    func icon(for app: AppItem) -> NSImage? {
        appDiscoveryService.preparedIcon(
            for: app,
            targetDimension: 64,
            quality: .medium
        )
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

    /// Persists the preferred icon sizing preset.
    func setIconSizePreference(_ preference: IconSizePreference) {
        guard settingsSnapshot.iconSizePreference != preference else { return }
        settingsSnapshot.iconSizePreference = preference
        LauncherSettingsPersistence.setIconSizePreference(preference)
    }

    /// Persists the paging orientation preference.
    func setPagingOrientation(_ orientation: PagingOrientation) {
        guard settingsSnapshot.pagingOrientation != orientation else { return }
        settingsSnapshot.pagingOrientation = orientation
        LauncherSettingsPersistence.setPagingOrientation(orientation)
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

    /// Provides the list of hidden entries (apps plus auto-created folders).
    var orderedHiddenEntries: [HiddenAppsListEntry] {
        let apps = discoveredApps.filter { $0.isCoreServiceApplication == false }
        let hiddenIdentifiers = Set(settingsSnapshot.hiddenBundleIDs)

        let mappedApps = apps.map { app -> HiddenAppsListEntry in
            HiddenAppsListEntry(
                id: app.bundleIdentifier,
                icon: icon(for: app),
                title: app.resolvedDisplayName,
                subtitle: app.bundleIdentifier,
                isHidden: hiddenIdentifiers.contains(app.bundleIdentifier),
                toggle: { [weak self] value in
                    self?.setHidden(value, for: app)
                }
            )
        }

        let orderedApps: [HiddenAppsListEntry]
        if settingsSnapshot.showHiddenAppsFirst {
            let hidden = mappedApps.filter(\.isHidden)
            let visible = mappedApps.filter { $0.isHidden == false }
            orderedApps = hidden + visible
        } else {
            orderedApps = mappedApps
        }

        return orderedApps + specialFolderEntries()
    }

    /// Persists whether hidden apps should float to the top of the list.
    func setShowHiddenAppsFirst(_ value: Bool) {
        guard settingsSnapshot.showHiddenAppsFirst != value else { return }
        settingsSnapshot.showHiddenAppsFirst = value
        LauncherSettingsPersistence.setShowHiddenAppsFirst(value)
    }

    /// Controls whether the user's Applications folder is indexed for hidden apps.
    func setShouldScanUserApplicationsFolder(_ value: Bool) {
        guard settingsSnapshot.shouldScanUserApplicationsFolder != value else { return }
        settingsSnapshot.shouldScanUserApplicationsFolder = value
        LauncherSettingsPersistence.setShouldScanUserApplicationsFolder(value)
        reloadApps()
    }

    /// Persists whether a special entry (like the CoreServices folder) is hidden.
    func setSpecialEntryHidden(_ identifier: String, _ isHidden: Bool) {
        var identifiers = Set(settingsSnapshot.hiddenSpecialEntryIDs)
        if isHidden {
            identifiers.insert(identifier)
        } else {
            identifiers.remove(identifier)
        }
        let sorted = identifiers.sorted()
        guard settingsSnapshot.hiddenSpecialEntryIDs != sorted else { return }
        settingsSnapshot.hiddenSpecialEntryIDs = sorted
        LauncherSettingsPersistence.setHiddenSpecialEntryIdentifiers(sorted)
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

    /// Releases discovery caches and observers while the settings window is closed.
    func prepareForDormancy() {
        guard isDormant == false else { return }
        isDormant = true
        settingsStreamTask?.cancel()
        settingsStreamTask = nil
        discoveredApps = []
        appDiscoveryService.shrinkCachesForHiddenLauncher()
    }

    /// Restores observers and data when the settings window is reopened.
    func resumeIfDormant() {
        guard isDormant else { return }
        isDormant = false
        settingsSnapshot = LauncherSettingsPersistence.loadSettings()
        observeSettingsChanges()
        reloadApps()
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

    private func specialFolderEntries() -> [HiddenAppsListEntry] {
        let coreServiceApps = discoveredApps.filter { $0.isCoreServiceApplication }
        guard coreServiceApps.isEmpty == false else { return [] }
        let hiddenSpecialIDs = Set(settingsSnapshot.hiddenSpecialEntryIDs)

        var entries: [HiddenAppsListEntry] = []
        let knownServices = coreServiceApps.filter(\.hasCustomIcon)
        if knownServices.isEmpty == false {
            entries.append(
                folderEntry(
                    id: HiddenSpecialEntryIdentifiers.coreServicesFolder,
                    title: String(localized: "macOS"),
                    subtitle: String(localized: "Finder, Siri, Spotlight, Game Center, and other CoreServices utilities from /System/Library/CoreServices."),
                    isHidden: hiddenSpecialIDs.contains(HiddenSpecialEntryIdentifiers.coreServicesFolder)
                )
            )
        }

        let systemTools = coreServiceApps.filter { $0.hasCustomIcon == false }
        if systemTools.isEmpty == false {
            entries.append(
                folderEntry(
                    id: HiddenSpecialEntryIdentifiers.systemToolsFolder,
                    title: String(localized: "macOS system tools"),
                    subtitle: String(localized: "Placeholder utilities without custom icons are grouped here."),
                    isHidden: hiddenSpecialIDs.contains(HiddenSpecialEntryIdentifiers.systemToolsFolder)
                )
            )
        }

        return entries
    }

    private func folderEntry(
        id: String,
        title: String,
        subtitle: String,
        isHidden: Bool
    ) -> HiddenAppsListEntry {
        HiddenAppsListEntry(
            id: id,
            icon: folderIcon,
            title: title,
            subtitle: subtitle,
            isHidden: isHidden,
            toggle: { [weak self] value in
                self?.setSpecialEntryHidden(id, value)
            }
        )
    }

    private var folderIcon: NSImage {
        NSWorkspace.shared.icon(for: UTType.folder)
    }

    /// Ensures a hotkey is always set when both Dock and menu bar affordances are hidden.
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
