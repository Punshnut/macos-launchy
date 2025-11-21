import SwiftUI
import Combine
import AppKit
import Carbon

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

    /// Persists the selected global hotkey used to toggle Launchy.
    func setLauncherHotkey(_ descriptor: HotkeyDescriptor?) {
        guard settingsSnapshot.launcherHotkey != descriptor else { return }
        settingsSnapshot.launcherHotkey = descriptor
        LauncherSettingsPersistence.setLauncherHotkey(descriptor)
    }

    /// Persists the shortcut used to flip between floaty and fullscreen layouts.
    func setLayoutToggleHotkey(_ descriptor: HotkeyDescriptor?) {
        guard settingsSnapshot.layoutToggleHotkey != descriptor else { return }
        settingsSnapshot.layoutToggleHotkey = descriptor
        LauncherSettingsPersistence.setLayoutToggleHotkey(descriptor)
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

            hotkeySection

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

            Text("Add a layout toggle shortcut below to flip modes instantly from anywhere.")
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

    /// Section that captures global shortcuts for launching and toggling layouts.
    private var hotkeySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Keyboard shortcuts")
                .font(.headline)

            HotkeyRecorderRow(
                title: "Toggle Launchy",
                message: "Works everywhere. Press Delete to clear or Reset to restore Cmd+Shift+Space.",
                hotkey: settingsStore.settingsSnapshot.launcherHotkey,
                placeholder: "Click to record",
                onChange: { settingsStore.setLauncherHotkey($0) },
                onReset: { settingsStore.resetLauncherHotkeyToDefault() }
            )

            HotkeyRecorderRow(
                title: "Switch fullscreen ⇄ floaty",
                message: "Pick a shortcut if you want to flip layouts quickly. Leave empty to disable.",
                hotkey: settingsStore.settingsSnapshot.layoutToggleHotkey,
                placeholder: "Add shortcut",
                onChange: { settingsStore.setLayoutToggleHotkey($0) },
                showResetButton: false
            )
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

private struct HotkeyRecorderRow: View {
    let title: String
    let message: String
    let hotkey: HotkeyDescriptor?
    let placeholder: String
    let onChange: (HotkeyDescriptor?) -> Void
    var onReset: (() -> Void)?
    var showResetButton: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline)
            HStack(spacing: 8) {
                HotkeyRecorderField(hotkey: hotkey, placeholder: placeholder, onChange: onChange)
                    .frame(width: 220, height: 30)

                if showResetButton, let onReset {
                    Button("Reset") {
                        onReset()
                    }
                }

                Button("Clear") {
                    onChange(nil)
                }
                .disabled(hotkey == nil)
            }
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

private struct HotkeyRecorderField: NSViewRepresentable {
    var hotkey: HotkeyDescriptor?
    var placeholder: String
    var onChange: (HotkeyDescriptor?) -> Void

    func makeNSView(context: Context) -> HotkeyRecorderTextField {
        let view = HotkeyRecorderTextField()
        view.placeholderText = placeholder
        view.onHotkeyChange = onChange
        view.hotkey = hotkey
        return view
    }

    func updateNSView(_ nsView: HotkeyRecorderTextField, context: Context) {
        nsView.placeholderText = placeholder
        nsView.hotkey = hotkey
        nsView.onHotkeyChange = onChange
    }
}

private final class HotkeyRecorderTextField: NSTextField {
    var hotkey: HotkeyDescriptor? {
        didSet { updateDisplay() }
    }

    var placeholderText: String = "Click to record" {
        didSet { updateDisplay() }
    }

    var onHotkeyChange: ((HotkeyDescriptor?) -> Void)?

    private var isRecording = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = true
        isEditable = false
        isSelectable = false
        drawsBackground = true
        backgroundColor = .controlBackgroundColor
        focusRingType = .default
        alignment = .center
        font = .systemFont(ofSize: NSFont.systemFontSize)
        cell?.wraps = false
        cell?.isScrollable = true
        updateDisplay()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let success = super.becomeFirstResponder()
        isRecording = true
        updateDisplay()
        return success
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        updateDisplay()
        return super.resignFirstResponder()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isRecording = true
        updateDisplay()
    }

    override func keyDown(with event: NSEvent) {
        handleKeyEvent(event)
    }

    private func handleKeyEvent(_ event: NSEvent) {
        let deleteKeyCodes: Set<UInt16> = [
            UInt16(kVK_Delete),
            UInt16(kVK_ForwardDelete)
        ]

        if event.keyCode == UInt16(kVK_Escape) {
            isRecording = false
            window?.makeFirstResponder(nil)
            updateDisplay()
            return
        }

        if deleteKeyCodes.contains(event.keyCode) {
            hotkey = nil
            onHotkeyChange?(nil)
            isRecording = false
            window?.makeFirstResponder(nil)
            updateDisplay()
            return
        }

        guard let descriptor = HotkeyDescriptor(event: event) else {
            NSSound.beep()
            return
        }

        hotkey = descriptor
        onHotkeyChange?(descriptor)
        isRecording = false
        window?.makeFirstResponder(nil)
        updateDisplay()
    }

    private func updateDisplay() {
        if isRecording {
            stringValue = ""
            placeholderString = "Press shortcut…"
            return
        }

        if let hotkey {
            stringValue = hotkey.displayString
            placeholderString = placeholderText
        } else {
            stringValue = ""
            placeholderString = placeholderText
        }
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
