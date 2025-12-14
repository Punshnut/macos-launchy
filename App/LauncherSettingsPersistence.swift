import Foundation

/// Simple persistence helpers for `LauncherSettings` values backed by `UserDefaults`.
enum LauncherSettingsPersistence {
    private enum Keys {
        static let settingsPayload = "launcher.settings.payload"
    }

    /// Registers the default values so future reads always produce `.fullscreen` until changed.
    static func registerDefaults(userDefaults: UserDefaults = .standard) {
        guard userDefaults.data(forKey: Keys.settingsPayload) == nil else { return }
        saveSettings(
            LauncherSettings.defaults,
            userDefaults: userDefaults,
            notify: false
        )
    }

    /// Reverts all persisted settings back to their defaults.
    static func resetSettings(userDefaults: UserDefaults = .standard) {
        saveSettings(LauncherSettings.defaults, userDefaults: userDefaults)
    }

    /// Reads the persisted launcher mode, falling back to `.fullscreen` if nothing has been saved.
    static func launcherMode(userDefaults: UserDefaults = .standard) -> LauncherMode {
        loadSettings(userDefaults: userDefaults).selectedLauncherMode
    }

    /// Persists the provided launcher mode for future sessions.
    static func setLauncherMode(_ mode: LauncherMode, userDefaults: UserDefaults = .standard) {
        updateSettings(userDefaults: userDefaults) { settings in
            settings.selectedLauncherMode = mode
        }
    }

    /// Reads a persisted boolean indicating whether the menu bar icon should be visible.
    static func showMenuBarIcon(userDefaults: UserDefaults = .standard) -> Bool {
        loadSettings(userDefaults: userDefaults).isMenuBarIconVisible
    }

    /// Persists the visibility selection for the menu bar icon.
    static func setShowMenuBarIcon(_ isVisible: Bool, userDefaults: UserDefaults = .standard) {
        updateSettings(userDefaults: userDefaults) { settings in
            settings.isMenuBarIconVisible = isVisible
        }
    }

    /// Persists whether the menu bar icon should be hidden.
    static func setMenuBarIconHidden(_ isHidden: Bool, userDefaults: UserDefaults = .standard) {
        setShowMenuBarIcon(!isHidden, userDefaults: userDefaults)
    }

    /// Reads a persisted boolean indicating whether the Dock icon should remain visible.
    static func showDockIcon(userDefaults: UserDefaults = .standard) -> Bool {
        loadSettings(userDefaults: userDefaults).isDockIconVisible
    }

    /// Persists the Dock icon visibility preference.
    static func setDockIconVisible(_ isVisible: Bool, userDefaults: UserDefaults = .standard) {
        updateSettings(userDefaults: userDefaults) { settings in
            settings.isDockIconVisible = isVisible
        }
    }

    /// Persists whether the Dock icon should be hidden.
    static func setDockIconHidden(_ isHidden: Bool, userDefaults: UserDefaults = .standard) {
        setDockIconVisible(!isHidden, userDefaults: userDefaults)
    }

    /// Reads whether the launcher should be added to login items.
    static func launchAtLogin(userDefaults: UserDefaults = .standard) -> Bool {
        loadSettings(userDefaults: userDefaults).launchesAtLogin
    }

    /// Persists the launch at login toggle for future sessions.
    static func setLaunchAtLogin(_ launchAtLogin: Bool, userDefaults: UserDefaults = .standard) {
        updateSettings(userDefaults: userDefaults) { settings in
            settings.launchesAtLogin = launchAtLogin
        }
    }

    /// Returns the list of bundle identifiers the user marked as hidden.
    static func hiddenBundleIdentifiers(userDefaults: UserDefaults = .standard) -> [String] {
        loadSettings(userDefaults: userDefaults).hiddenBundleIDs
    }

    /// Persists the hidden bundles list.
    static func setHiddenBundleIdentifiers(
        _ identifiers: [String],
        userDefaults: UserDefaults = .standard
    ) {
        updateSettings(userDefaults: userDefaults) { settings in
            settings.hiddenBundleIDs = identifiers
        }
    }

    /// Reads identifiers for special entries that can be hidden.
    static func hiddenSpecialEntryIdentifiers(
        userDefaults: UserDefaults = .standard
    ) -> [String] {
        loadSettings(userDefaults: userDefaults).hiddenSpecialEntryIDs
    }

    /// Persists the hidden state of special entries such as auto-generated folders.
    static func setHiddenSpecialEntryIdentifiers(
        _ identifiers: [String],
        userDefaults: UserDefaults = .standard
    ) {
        updateSettings(userDefaults: userDefaults) { settings in
            settings.hiddenSpecialEntryIDs = identifiers
        }
    }

    /// Reads whether hidden apps should be anchored at the top of the list.
    static func showHiddenAppsFirst(userDefaults: UserDefaults = .standard) -> Bool {
        loadSettings(userDefaults: userDefaults).showHiddenAppsFirst
    }

    /// Persists the hidden-apps ordering preference.
    static func setShowHiddenAppsFirst(
        _ value: Bool,
        userDefaults: UserDefaults = .standard
    ) {
        updateSettings(userDefaults: userDefaults) { settings in
            settings.showHiddenAppsFirst = value
        }
    }

    /// Reads whether the user's Applications folder is scanned for installed apps.
    static func shouldScanUserApplicationsFolder(
        userDefaults: UserDefaults = .standard
    ) -> Bool {
        loadSettings(userDefaults: userDefaults).shouldScanUserApplicationsFolder
    }

    /// Persists whether the user's Applications folder should be indexed.
    static func setShouldScanUserApplicationsFolder(
        _ value: Bool,
        userDefaults: UserDefaults = .standard
    ) {
        updateSettings(userDefaults: userDefaults) { settings in
            settings.shouldScanUserApplicationsFolder = value
        }
    }

    /// Reads the preferred background style selection.
    static func preferredBackgroundStyle(
        userDefaults: UserDefaults = .standard
    ) -> LauncherSettings.PreferredBackgroundStyle {
        loadSettings(userDefaults: userDefaults).backgroundStylePreference
    }

    /// Persists the selected background style.
    static func setPreferredBackgroundStyle(
        _ style: LauncherSettings.PreferredBackgroundStyle,
        userDefaults: UserDefaults = .standard
    ) {
        updateSettings(userDefaults: userDefaults) { settings in
            settings.backgroundStylePreference = style
        }
    }

    /// Persists the chosen solid background color.
    static func setSolidBackgroundColor(
        _ color: LauncherSettings.SolidBackgroundColor,
        userDefaults: UserDefaults = .standard
    ) {
        updateSettings(userDefaults: userDefaults) { settings in
            settings.solidBackgroundColor = color
        }
    }

    /// Reads the stored launcher hotkey.
    static func launcherHotkey(userDefaults: UserDefaults = .standard) -> HotkeyDescriptor? {
        loadSettings(userDefaults: userDefaults).launcherHotkey
    }

    /// Persists the selected launcher hotkey.
    static func setLauncherHotkey(_ value: HotkeyDescriptor?, userDefaults: UserDefaults = .standard) {
        updateSettings(userDefaults: userDefaults) { settings in
            settings.launcherHotkey = value
        }
    }

    /// Reads the shortcut used to flip between floaty and fullscreen modes.
    static func layoutToggleHotkey(userDefaults: UserDefaults = .standard) -> HotkeyDescriptor? {
        loadSettings(userDefaults: userDefaults).layoutToggleHotkey
    }

    /// Persists the layout toggle shortcut.
    static func setLayoutToggleHotkey(_ value: HotkeyDescriptor?, userDefaults: UserDefaults = .standard) {
        updateSettings(userDefaults: userDefaults) { settings in
            settings.layoutToggleHotkey = value
        }
    }

    /// Reads whether the hot corner trigger is enabled.
    static func hotCornerEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        loadSettings(userDefaults: userDefaults).hotCornerEnabled
    }

    /// Persists whether the launcher should respond to a hot corner.
    static func setHotCornerEnabled(_ value: Bool, userDefaults: UserDefaults = .standard) {
        updateSettings(userDefaults: userDefaults) { settings in
            settings.hotCornerEnabled = value
        }
    }

    /// Reads which hot corner position is configured.
    static func hotCornerPosition(userDefaults: UserDefaults = .standard) -> HotCornerPosition {
        loadSettings(userDefaults: userDefaults).hotCornerPosition
    }

    /// Persists the selected hot corner position.
    static func setHotCornerPosition(
        _ position: HotCornerPosition,
        userDefaults: UserDefaults = .standard
    ) {
        updateSettings(userDefaults: userDefaults) { settings in
            settings.hotCornerPosition = position
        }
    }

    /// Reads whether the grid should collapse gaps.
    static func fillsGapsAutomatically(userDefaults: UserDefaults = .standard) -> Bool {
        loadSettings(userDefaults: userDefaults).fillsGapsAutomatically
    }

    /// Returns true when the user has finished the introduction flow.
    static func hasCompletedIntroduction(userDefaults: UserDefaults = .standard) -> Bool {
        loadSettings(userDefaults: userDefaults).hasCompletedIntroduction
    }

    /// Persists whether the introduction has been completed.
    static func setHasCompletedIntroduction(
        _ value: Bool,
        userDefaults: UserDefaults = .standard
    ) {
        updateSettings(userDefaults: userDefaults) { settings in
            settings.hasCompletedIntroduction = value
        }
    }

    /// Persists the gap collapsing preference.
    static func setFillsGapsAutomatically(_ value: Bool, userDefaults: UserDefaults = .standard) {
        updateSettings(userDefaults: userDefaults) { settings in
            settings.fillsGapsAutomatically = value
        }
    }

    /// Reconstructs a `LauncherSettings` value using the stored toggles.
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

    /// Broadcasts a notification so listeners can react to persistence updates.
    private static func notifyChange() {
        NotificationCenter.default.post(name: .launcherSettingsDidChange, object: nil)
    }

    /// Persists the provided settings, optionally suppressing notifications.
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

    /// Loads, mutates, and saves settings while emitting change notifications.
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

    /// Ensures the launcher remains openable when all affordances are hidden.
    private static func enforceLauncherReachability(_ settings: inout LauncherSettings) {
        guard settings.isDockIconHidden && settings.isMenuBarIconHidden else { return }
        if settings.launcherHotkey == nil {
            settings.launcherHotkey = .toggleLauncher
        }
    }

    /// Auto-hides the generated system tools folder to avoid cluttering the grid by default.
    private static func ensureSystemToolsFolderHidden(_ settings: inout LauncherSettings) {
        guard settings.hiddenSpecialEntryIDs.contains(HiddenSpecialEntryIdentifiers.systemToolsFolder) == false else { return }
        settings.hiddenSpecialEntryIDs.append(HiddenSpecialEntryIdentifiers.systemToolsFolder)
        settings.hiddenSpecialEntryIDs.sort()
    }
}

extension Notification.Name {
    /// Posted each time any launcher setting is persisted.
    static let launcherSettingsDidChange = Notification.Name("LauncherSettingsDidChange")
    /// Posted when the user requests a reset of the saved launcher arrangement.
    static let launcherArrangementResetRequested = Notification.Name("LauncherArrangementResetRequested")
}
