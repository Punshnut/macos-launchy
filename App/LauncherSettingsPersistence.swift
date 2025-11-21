import Foundation

/// Simple persistence helpers for `LauncherSettings` values backed by `UserDefaults`.
enum LauncherSettingsPersistence {
    private enum Keys {
        static let settingsPayload = "launcher.settings.payload"
    }

    /// Registers the default values so future reads always produce `.fullscreenOldMac` until changed.
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

    /// Reads the persisted launcher mode, falling back to `.fullscreenOldMac` if nothing has been saved.
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

    /// Reads a persisted boolean indicating whether the Dock icon should remain visible in floaty mode.
    static func showFloatyDockIcon(userDefaults: UserDefaults = .standard) -> Bool {
        loadSettings(userDefaults: userDefaults).isFloatyDockIconVisible
    }

    /// Persists the Dock icon visibility preference for floaty mode.
    static func setShowFloatyDockIcon(_ isVisible: Bool, userDefaults: UserDefaults = .standard) {
        updateSettings(userDefaults: userDefaults) { settings in
            settings.isFloatyDockIconVisible = isVisible
        }
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

    /// Reads whether the grid should collapse gaps.
    static func fillsGapsAutomatically(userDefaults: UserDefaults = .standard) -> Bool {
        loadSettings(userDefaults: userDefaults).fillsGapsAutomatically
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
            return LauncherSettings.defaults
        }

        do {
            return try JSONDecoder().decode(LauncherSettings.self, from: data)
        } catch {
            return LauncherSettings.defaults
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
        guard let data = try? JSONEncoder().encode(settings) else { return }
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
        saveSettings(mutableSettings, userDefaults: userDefaults)
    }
}

extension Notification.Name {
    /// Posted each time any launcher setting is persisted.
    static let launcherSettingsDidChange = Notification.Name("LauncherSettingsDidChange")
    /// Posted when the user requests a reset of the saved launcher arrangement.
    static let launcherArrangementResetRequested = Notification.Name("LauncherArrangementResetRequested")
}
