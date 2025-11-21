import SwiftUI
import Combine
import AppKit

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
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let discoveredApps = discoveryEngine.reloadApps().map(discoveryEngine.loadIcon)
            Task { @MainActor [weak self] in
                self?.discoveredApps = discoveredApps
            }
        }
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

    /// Persists whether the Dock icon should remain visible in floaty mode.
    func setFloatyDockIconVisible(_ isVisible: Bool) {
        guard settingsSnapshot.isFloatyDockIconVisible != isVisible else { return }
        settingsSnapshot.isFloatyDockIconVisible = isVisible
        LauncherSettingsPersistence.setShowFloatyDockIcon(isVisible)
    }

    /// Persists the stubbed hotkey text.
    func setHotkeyDisplay(_ value: String) {
        guard settingsSnapshot.globalHotkeyDescription != value else { return }
        settingsSnapshot.globalHotkeyDescription = value
        LauncherSettingsPersistence.setGlobalHotkeyDisplay(value)
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
        settingsSnapshot = LauncherSettingsPersistence.loadSettings()
    }
}

/// SwiftUI-based macOS settings window content that drives `LauncherSettings`.
struct SettingsWindow: View {
    /// Backing store powering the macOS settings UI.
    @StateObject private var settingsStore: SettingsWindowStore

    init(store: SettingsWindowStore = SettingsWindowStore()) {
        _settingsStore = StateObject(wrappedValue: store)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                formContent
                Divider()
                hiddenAppsHeader
                hiddenAppsList
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .frame(minWidth: 560, minHeight: 520)
    }

    /// Section containing the simple toggles and dropdowns.
    private var formContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            launcherLayoutPicker

            dockIconSection

            Toggle("Launch at login", isOn: Binding(
                get: { settingsStore.settingsSnapshot.launchesAtLogin },
                set: { settingsStore.setLaunchAtLogin($0) }
            ))

            Picker("Background style", selection: Binding(
                get: { settingsStore.settingsSnapshot.backgroundStylePreference },
                set: { settingsStore.setPreferredBackgroundStyle($0) }
            )) {
                ForEach(LauncherSettings.PreferredBackgroundStyle.allCases, id: \.self) { style in
                    Text(style.displayName).tag(style)
                }
            }
            .pickerStyle(.menu)
            if settingsStore.settingsSnapshot.backgroundStylePreference == .solid {
                solidColorPalette
            }

            Toggle("Icons move up when there's space", isOn: Binding(
                get: { settingsStore.settingsSnapshot.fillsGapsAutomatically },
                set: { settingsStore.setFillsGapsAutomatically($0) }
            ))

            VStack(alignment: .leading, spacing: 8) {
                Button {
                    confirmArrangementReset()
                } label: {
                    Text("Reset icon arrangement…")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)

                Text("Deletes your saved ordering and folders, then rebuilds pages from scratch. Type RESET to confirm.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Global hotkey")
                    .font(.headline)
                HStack {
                    TextField("Cmd+Shift+Space", text: Binding(
                        get: { settingsStore.settingsSnapshot.globalHotkeyDescription },
                        set: { settingsStore.setHotkeyDisplay($0) }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)

                    Text("Shortcut capture is not implemented yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Displays the segmented control for switching between floaty and fullscreen modes.
    private var launcherLayoutPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Launcher layout")
                .font(.headline)

            Picker("", selection: Binding(
                get: { settingsStore.settingsSnapshot.selectedLauncherMode },
                set: { settingsStore.setLauncherMode($0) }
            )) {
                ForEach(LauncherMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            Text("Use Cmd+Option+F to toggle layouts instantly from the menu bar.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    /// Toggle that manages the Dock icon visibility when running in floaty mode.
    private var dockIconSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Show Dock icon (Floaty mode only)", isOn: Binding(
                get: { settingsStore.settingsSnapshot.isFloatyDockIconVisible },
                set: { settingsStore.setFloatyDockIconVisible($0) }
            ))
            .disabled(settingsStore.settingsSnapshot.selectedLauncherMode != .floaty)

            if settingsStore.settingsSnapshot.selectedLauncherMode == .floaty {
                Text("Hide the Dock icon to keep Launchy out of the way when using the floaty panel.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("Dock icon always shows in fullscreen mode, so this toggle is temporarily disabled.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Swatch selector for solid background colors.
    private var solidColorPalette: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Solid color")
                .font(.headline)
            HStack(spacing: 12) {
                ForEach(LauncherSettings.SolidBackgroundColor.allCases, id: \.self) { colorOption in
                    let isSelected = settingsStore.settingsSnapshot.solidBackgroundColor == colorOption
                    Button {
                        settingsStore.setSolidBackgroundColor(colorOption)
                    } label: {
                        Circle()
                            .fill(Color(nsColor: colorOption.nsColor))
                            .frame(width: 28, height: 28)
                            .overlay(
                                Circle()
                                    .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.25), lineWidth: isSelected ? 3 : 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(colorOption.displayName)
                }
            }
        }
    }

    /// Header area above the list of hidden apps.
    private var hiddenAppsHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Hidden apps")
                .font(.headline)
            Text("Use the checkboxes to hide applications from the launcher grid.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    /// Scrollable list of discovered apps where each entry has a hide checkbox.
    private var hiddenAppsList: some View {
        Group {
            if settingsStore.discoveredApps.isEmpty {
                Text("Scanning for applications...")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(settingsStore.discoveredApps.enumerated()), id: \.element.id) { index, app in
                        Toggle(isOn: Binding(
                            get: { settingsStore.isHidden(app) },
                            set: { settingsStore.setHidden($0, for: app) }
                        )) {
                            HStack(spacing: 12) {
                                iconView(for: app)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(app.resolvedDisplayName)
                                    Text(app.bundleIdentifier)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)

                        if index < settingsStore.discoveredApps.count - 1 {
                            Divider()
                                .padding(.leading, 44)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.5))
                )
            }
        }
        .frame(maxWidth: .infinity, minHeight: 280, alignment: .leading)
    }

    /// Shows the discovered icon or a fallback placeholder.
    private func iconView(for app: AppItem) -> some View {
        Group {
            if let image = app.iconImage {
                Image(nsImage: image)
                    .resizable()
            } else {
                Image(systemName: "app.fill")
                    .resizable()
                    .foregroundColor(.secondary)
            }
        }
        .aspectRatio(contentMode: .fit)
        .frame(width: 32, height: 32)
        .cornerRadius(6)
    }

    /// Shows a confirmation dialog before wiping the saved arrangement.
    private func confirmArrangementReset() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Reset icon arrangement?"
        alert.informativeText = "This deletes your saved ordering, folders, and page layout. Type RESET to continue."

        let field = NSTextField(string: "")
        field.placeholderString = "RESET"
        field.frame = NSRect(x: 0, y: 0, width: 220, height: 24)
        alert.accessoryView = field

        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        let token = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard token == "RESET" else { return }
        settingsStore.requestArrangementReset()
    }
}

/// Wraps the SwiftUI settings content inside a reusable macOS window controller.
final class SettingsWindowController: NSWindowController {
    private let hostingController: NSHostingController<SettingsWindow>

    init() {
        let view = SettingsWindow()
        hostingController = NSHostingController(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
            styleMask: [
                .titled,
                .closable,
                .miniaturizable
            ],
            backing: .buffered,
            defer: false
        )
        window.title = "Launchy Settings"
        window.isReleasedWhenClosed = false
        // Keep the settings window visible above the launcher UI, even in fullscreen.
        window.level = .screenSaver
        window.collectionBehavior.insert(.fullScreenAuxiliary)
        window.collectionBehavior.insert(.canJoinAllSpaces)
        window.center()
        window.contentViewController = hostingController
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Brings the settings window to the front and activates the app if needed.
    func showWindowAndActivate() {
        guard let window else { return }
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

#Preview {
    SettingsWindow(
        store: SettingsWindowStore(
            discoveryService: AppDiscoveryService(
                applicationDirectories: [
                    FileManager.default.homeDirectoryForCurrentUser
                ]
            )
        )
    )
}
