import Foundation

/// Persists and loads `LauncherSettings` via `UserDefaults`.
enum LauncherSettingsPersistence {
    private enum Keys {
        static let settingsPayload = "launcher.settings.payload"
        static let arrangementResetSorting = "launcher.reset.sorting"
    }

    /// Seeds defaults on first run.
    static func registerDefaults(userDefaults: UserDefaults = .standard) {
        guard userDefaults.data(forKey: Keys.settingsPayload) == nil else { return }
        saveSettings(
            LauncherSettings.defaults,
            userDefaults: userDefaults,
            notify: false
        )
    }

    /// Resets all settings to defaults.
    static func resetSettings(userDefaults: UserDefaults = .standard) {
        saveSettings(LauncherSettings.defaults, userDefaults: userDefaults)
    }

    /// Returns current launcher mode.
    static func launcherMode(userDefaults: UserDefaults = .standard) -> LauncherMode {
        loadSettings(userDefaults: userDefaults).selectedLauncherMode
    }

    /// Saves launcher mode.
    static func setLauncherMode(_ mode: LauncherMode, userDefaults: UserDefaults = .standard) {
        updateSettings(userDefaults: userDefaults) { settings in
            settings.selectedLauncherMode = mode
        }
    }

    /// Returns whether menu bar icon is visible.
    static func showMenuBarIcon(userDefaults: UserDefaults = .standard) -> Bool {
        loadSettings(userDefaults: userDefaults).isMenuBarIconVisible
    }

    /// Saves menu bar icon visibility.
    static func setShowMenuBarIcon(_ isVisible: Bool, userDefaults: UserDefaults = .standard) {
        updateSettings(userDefaults: userDefaults) { settings in
            settings.isMenuBarIconVisible = isVisible
        }
    }

    /// Convenience setter for hidden menu bar icon state.
    static func setMenuBarIconHidden(_ isHidden: Bool, userDefaults: UserDefaults = .standard) {
        setShowMenuBarIcon(!isHidden, userDefaults: userDefaults)
    }

    /// Returns whether Dock icon is visible.
    static func showDockIcon(userDefaults: UserDefaults = .standard) -> Bool {
        loadSettings(userDefaults: userDefaults).isDockIconVisible
    }

    /// Saves Dock icon visibility.
    static func setDockIconVisible(_ isVisible: Bool, userDefaults: UserDefaults = .standard) {
        updateSettings(userDefaults: userDefaults) { settings in
            settings.isDockIconVisible = isVisible
        }
    }

    /// Convenience setter for hidden Dock icon state.
    static func setDockIconHidden(_ isHidden: Bool, userDefaults: UserDefaults = .standard) {
        setDockIconVisible(!isHidden, userDefaults: userDefaults)
    }

    /// Returns Dock menu grouping preference.
    static func sortsDockMenuFoldersLast(userDefaults: UserDefaults = .standard) -> Bool {
        loadSettings(userDefaults: userDefaults).sortsDockMenuFoldersLast
    }

    /// Saves Dock menu grouping preference.
    static func setSortsDockMenuFoldersLast(
        _ value: Bool,
        userDefaults: UserDefaults = .standard
    ) {
        updateSettings(userDefaults: userDefaults) { settings in
            settings.sortsDockMenuFoldersLast = value
        }
    }

    /// Returns launch-at-login preference.
    static func launchAtLogin(userDefaults: UserDefaults = .standard) -> Bool {
        loadSettings(userDefaults: userDefaults).launchesAtLogin
    }

    /// Saves launch-at-login preference.
    static func setLaunchAtLogin(_ launchAtLogin: Bool, userDefaults: UserDefaults = .standard) {
        updateSettings(userDefaults: userDefaults) { settings in
            settings.launchesAtLogin = launchAtLogin
        }
    }

    /// Returns hidden app bundle IDs.
    static func hiddenBundleIdentifiers(userDefaults: UserDefaults = .standard) -> [String] {
        loadSettings(userDefaults: userDefaults).hiddenBundleIDs
    }

    /// Saves hidden app bundle IDs.
    static func setHiddenBundleIdentifiers(
        _ identifiers: [String],
        userDefaults: UserDefaults = .standard
    ) {
        updateSettings(userDefaults: userDefaults) { settings in
            settings.hiddenBundleIDs = identifiers
        }
    }

    /// Returns hidden special entry IDs.
    static func hiddenSpecialEntryIdentifiers(
        userDefaults: UserDefaults = .standard
    ) -> [String] {
        loadSettings(userDefaults: userDefaults).hiddenSpecialEntryIDs
    }

    /// Saves hidden special entry IDs.
    static func setHiddenSpecialEntryIdentifiers(
        _ identifiers: [String],
        userDefaults: UserDefaults = .standard
    ) {
        updateSettings(userDefaults: userDefaults) { settings in
            settings.hiddenSpecialEntryIDs = identifiers
        }
    }

    /// Returns hidden-app ordering preference.
    static func showHiddenAppsFirst(userDefaults: UserDefaults = .standard) -> Bool {
        loadSettings(userDefaults: userDefaults).showHiddenAppsFirst
    }

    /// Saves hidden-app ordering preference.
    static func setShowHiddenAppsFirst(
        _ value: Bool,
        userDefaults: UserDefaults = .standard
    ) {
        updateSettings(userDefaults: userDefaults) { settings in
            settings.showHiddenAppsFirst = value
        }
    }

    /// Returns user Applications scan preference.
    static func shouldScanUserApplicationsFolder(
        userDefaults: UserDefaults = .standard
    ) -> Bool {
        loadSettings(userDefaults: userDefaults).shouldScanUserApplicationsFolder
    }

    /// Saves user Applications scan preference.
    static func setShouldScanUserApplicationsFolder(
        _ value: Bool,
        userDefaults: UserDefaults = .standard
    ) {
        updateSettings(userDefaults: userDefaults) { settings in
            settings.shouldScanUserApplicationsFolder = value
        }
    }

    /// Returns icon size preference.
    static func iconSizePreference(userDefaults: UserDefaults = .standard) -> IconSizePreference {
        loadSettings(userDefaults: userDefaults).iconSizePreference
    }

    /// Saves icon size preference.
    static func setIconSizePreference(
        _ preference: IconSizePreference,
        userDefaults: UserDefaults = .standard
    ) {
        updateSettings(userDefaults: userDefaults) { settings in
            settings.iconSizePreference = preference
        }
    }

    /// Returns paging orientation.
    static func pagingOrientation(userDefaults: UserDefaults = .standard) -> PagingOrientation {
        loadSettings(userDefaults: userDefaults).pagingOrientation
    }

    /// Saves paging orientation.
    static func setPagingOrientation(
        _ orientation: PagingOrientation,
        userDefaults: UserDefaults = .standard
    ) {
        updateSettings(userDefaults: userDefaults) { settings in
            settings.pagingOrientation = orientation
        }
    }

    /// Returns background style preference.
    static func preferredBackgroundStyle(
        userDefaults: UserDefaults = .standard
    ) -> LauncherSettings.PreferredBackgroundStyle {
        loadSettings(userDefaults: userDefaults).backgroundStylePreference
    }

    /// Saves background style preference.
    static func setPreferredBackgroundStyle(
        _ style: LauncherSettings.PreferredBackgroundStyle,
        userDefaults: UserDefaults = .standard
    ) {
        updateSettings(userDefaults: userDefaults) { settings in
            settings.backgroundStylePreference = style
        }
    }

    /// Saves solid background color.
    static func setSolidBackgroundColor(
        _ color: LauncherSettings.SolidBackgroundColor,
        userDefaults: UserDefaults = .standard
    ) {
        updateSettings(userDefaults: userDefaults) { settings in
            settings.solidBackgroundColor = color
        }
    }

    /// Returns launcher hotkey.
    static func launcherHotkey(userDefaults: UserDefaults = .standard) -> HotkeyDescriptor? {
        loadSettings(userDefaults: userDefaults).launcherHotkey
    }

    /// Saves launcher hotkey.
    static func setLauncherHotkey(_ value: HotkeyDescriptor?, userDefaults: UserDefaults = .standard) {
        updateSettings(userDefaults: userDefaults) { settings in
            settings.launcherHotkey = value
        }
    }

    /// Returns layout-toggle hotkey.
    static func layoutToggleHotkey(userDefaults: UserDefaults = .standard) -> HotkeyDescriptor? {
        loadSettings(userDefaults: userDefaults).layoutToggleHotkey
    }

    /// Saves layout-toggle hotkey.
    static func setLayoutToggleHotkey(_ value: HotkeyDescriptor?, userDefaults: UserDefaults = .standard) {
        updateSettings(userDefaults: userDefaults) { settings in
            settings.layoutToggleHotkey = value
        }
    }

    /// Returns hot-corner enabled state.
    static func hotCornerEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        loadSettings(userDefaults: userDefaults).hotCornerEnabled
    }

    /// Saves hot-corner enabled state.
    static func setHotCornerEnabled(_ value: Bool, userDefaults: UserDefaults = .standard) {
        updateSettings(userDefaults: userDefaults) { settings in
            settings.hotCornerEnabled = value
        }
    }

    /// Returns selected hot-corner position.
    static func hotCornerPosition(userDefaults: UserDefaults = .standard) -> HotCornerPosition {
        loadSettings(userDefaults: userDefaults).hotCornerPosition
    }

    /// Saves hot-corner position.
    static func setHotCornerPosition(
        _ position: HotCornerPosition,
        userDefaults: UserDefaults = .standard
    ) {
        updateSettings(userDefaults: userDefaults) { settings in
            settings.hotCornerPosition = position
        }
    }

    /// Returns gap-fill preference.
    static func fillsGapsAutomatically(userDefaults: UserDefaults = .standard) -> Bool {
        loadSettings(userDefaults: userDefaults).fillsGapsAutomatically
    }

    /// Returns introduction completion state.
    static func hasCompletedIntroduction(userDefaults: UserDefaults = .standard) -> Bool {
        loadSettings(userDefaults: userDefaults).hasCompletedIntroduction
    }

    /// Saves introduction completion state.
    static func setHasCompletedIntroduction(
        _ value: Bool,
        userDefaults: UserDefaults = .standard
    ) {
        updateSettings(userDefaults: userDefaults) { settings in
            settings.hasCompletedIntroduction = value
        }
    }

    /// Saves gap-fill preference.
    static func setFillsGapsAutomatically(_ value: Bool, userDefaults: UserDefaults = .standard) {
        updateSettings(userDefaults: userDefaults) { settings in
            settings.fillsGapsAutomatically = value
        }
    }

    /// Returns preferred sorting for arrangement reset.
    static func arrangementResetSorting(userDefaults: UserDefaults = .standard) -> ArrangementResetSorting {
        guard
            let raw = userDefaults.string(forKey: Keys.arrangementResetSorting),
            let sorting = ArrangementResetSorting(rawValue: raw)
        else { return .alphabetical }
        return sorting
    }

    /// Saves reset sorting preference.
    static func setArrangementResetSorting(
        _ sorting: ArrangementResetSorting,
        userDefaults: UserDefaults = .standard
    ) {
        userDefaults.set(sorting.rawValue, forKey: Keys.arrangementResetSorting)
    }

    /// Replaces entire settings payload (for backup restore).
    static func overwriteSettings(
        _ settings: LauncherSettings,
        userDefaults: UserDefaults = .standard
    ) {
        saveSettings(settings, userDefaults: userDefaults)
    }

    /// Loads persisted settings or defaults.
    static func loadSettings(userDefaults: UserDefaults = .standard) -> LauncherSettings {
        guard let data = userDefaults.data(forKey: Keys.settingsPayload) else {
            var defaults = LauncherSettings.defaults
            ensureSystemToolsFolderHidden(&defaults)
            return defaults
        }

        do {
            var settings = try JSONDecoder().decode(LauncherSettings.self, from: data)
            enforceLauncherReachability(&settings)
            ensureSystemToolsFolderHidden(&settings)
            return settings
        } catch {
            var defaults = LauncherSettings.defaults
            ensureSystemToolsFolderHidden(&defaults)
            return defaults
        }
    }

    /// Broadcasts settings-change notification.
    private static func notifyChange() {
        NotificationCenter.default.post(name: .launcherSettingsDidChange, object: nil)
    }

    /// Saves settings, optionally without notification.
    private static func saveSettings(
        _ settings: LauncherSettings,
        userDefaults: UserDefaults = .standard,
        notify: Bool = true
    ) {
        var sanitized = settings
        ensureSystemToolsFolderHidden(&sanitized)
        guard let data = try? JSONEncoder().encode(sanitized) else { return }
        userDefaults.set(data, forKey: Keys.settingsPayload)
        if notify {
            notifyChange()
        }
    }

    /// Loads, mutates, and saves settings.
    private static func updateSettings(
        userDefaults: UserDefaults = .standard,
        mutate: (inout LauncherSettings) -> Void
    ) {
        var mutableSettings = loadSettings(userDefaults: userDefaults)
        mutate(&mutableSettings)
        enforceLauncherReachability(&mutableSettings)
        ensureSystemToolsFolderHidden(&mutableSettings)
        saveSettings(mutableSettings, userDefaults: userDefaults)
    }

    /// Guarantees launcher remains reachable.
    private static func enforceLauncherReachability(_ settings: inout LauncherSettings) {
        guard settings.isDockIconHidden && settings.isMenuBarIconHidden else { return }
        if settings.launcherHotkey == nil {
            settings.launcherHotkey = .toggleLauncher
        }
    }

    /// Keeps generated system-tools folder hidden by default.
    private static func ensureSystemToolsFolderHidden(_ settings: inout LauncherSettings) {
        guard settings.hiddenSpecialEntryIDs.contains(HiddenSpecialEntryIdentifiers.systemToolsFolder) == false else { return }
        settings.hiddenSpecialEntryIDs.append(HiddenSpecialEntryIdentifiers.systemToolsFolder)
        settings.hiddenSpecialEntryIDs.sort()
    }
}

extension Notification.Name {
    /// Fired after settings are persisted.
    static let launcherSettingsDidChange = Notification.Name("LauncherSettingsDidChange")
    /// Fired when arrangement reset is requested.
    static let launcherArrangementResetRequested = Notification.Name("LauncherArrangementResetRequested")
    /// Fired when backup export is requested.
    static let launcherBackupExportRequested = Notification.Name("LauncherBackupExportRequested")
    /// Fired when backup import is requested.
    static let launcherBackupImportRequested = Notification.Name("LauncherBackupImportRequested")
}
