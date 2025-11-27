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
        let includeUserApplications = settingsSnapshot.shouldScanUserApplicationsFolder
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let (mainApps, userApps) = discoveryEngine.reloadApps(
                includeUserApplicationsFolder: includeUserApplications
            )
            let discoveredApps = (mainApps + userApps).map(discoveryEngine.loadIcon)
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

// MARK: - Settings Window UI

private enum SettingsTab: Int, CaseIterable, Identifiable {
    case visuals
    case shortcuts
    case hiddenApps
    case about

    var id: Int { rawValue }

    var iconName: String {
        switch self {
        case .visuals:
            return "paintpalette.fill"
        case .shortcuts:
            return "keyboard.fill"
        case .hiddenApps:
            return "eye.slash.fill"
        case .about:
            return "info.circle"
        }
    }

    var title: String {
        switch self {
        case .visuals:
            return String(localized: "Visuals")
        case .shortcuts:
            return String(localized: "Shortcuts")
        case .hiddenApps:
            return String(localized: "Hidden Apps")
        case .about:
            return String(localized: "About")
        }
    }
}

private enum SettingsWindowMetrics {
    static let defaultContentWidth: CGFloat = 720
    static let visualsHeight: CGFloat = 560
    static let shortcutsHeight: CGFloat = 520
    static let hiddenAppsHeight: CGFloat = 640
    static let aboutHeight: CGFloat = 720
    static let minimumContentSize = NSSize(width: 640, height: shortcutsHeight)

    static var defaultContentSize: NSSize {
        NSSize(width: defaultContentWidth, height: visualsHeight)
    }

    static func preferredContentHeight(for tab: SettingsTab) -> CGFloat {
        switch tab {
        case .visuals:
            return visualsHeight
        case .shortcuts:
            return shortcutsHeight
        case .hiddenApps:
            return hiddenAppsHeight
        case .about:
            return aboutHeight
        }
    }
}

/// SwiftUI-based macOS settings window content that drives `LauncherSettings`.
struct SettingsWindow: View {
    /// Backing store powering the macOS settings UI.
    @StateObject private var settingsStore: SettingsWindowStore
    @State private var activeTab: SettingsTab = .visuals
    @State private var hostingWindow: NSWindow?
    @State private var hasAppliedInitialWindowSizing = false
    @Namespace private var tabSelectionNamespace
    @Environment(\.colorScheme) private var colorScheme

    init(store: SettingsWindowStore = SettingsWindowStore()) {
        _settingsStore = StateObject(wrappedValue: store)
    }

    var body: some View {
        ZStack {
            outerBackgroundView
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topChromeSpacer
                tabBar
                Divider()
                    .opacity(0.08)
                    .overlay(Color.white.opacity(0.08))
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: 16) {
                        tabContent
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 20)
                }
            }
            .frame(minWidth: 640, minHeight: 560)
            .background(
                FrostedBackgroundView(material: .hudWindow)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(borderStrokeColor, lineWidth: 1)
                    .allowsHitTesting(false)
            )
            .overlay(
                HostingWindowFinder { window in
                    hostingWindow = window
                    if let window {
                        applyWindowConfiguration(for: window)
                    }
                }
                .allowsHitTesting(false)
            )
            .padding(.horizontal, 6)
            .padding(.bottom, 6)
            .padding(.top, 6)
            .overlay(alignment: .topLeading) {
                windowControls
                    .padding(.top, topChromeControlInset)
                    .padding(.leading, 22)
                    .padding(.trailing, 22)
            }
        }
        .onChange(of: activeTab) { newValue in
            resizeWindow(for: newValue, animated: true)
        }
        .onChange(of: hostingWindow) { window in
            guard let window else { return }
            applyWindowConfiguration(for: window)
        }
    }

    // MARK: - Top Bar

    private var topChromeSpacer: some View {
        Color.clear
            .frame(height: topChromeHeight)
            .overlay(alignment: .center) {
                topBarTitle
                    .padding(.top, 8)
                    .padding(.horizontal, 60)
            }
    }

    private var windowControls: some View {
        HStack(spacing: 8) {
            ForEach(WindowControlKind.allCases) { control in
                WindowControlDot(kind: control) {
                    performWindowAction(for: control)
                }
            }
            Spacer()
        }
        .frame(height: 24, alignment: .leading)
    }

    private var topBarTitle: some View {
        let isDark = colorScheme == .dark
        let titleColor = isDark ? Color.white.opacity(0.96) : Color.primary.opacity(0.9)
        let subtitleColor = isDark ? Color.white.opacity(0.75) : Color.primary.opacity(0.55)
        let capsuleFill = LinearGradient(
            colors: isDark
                ? [Color.black.opacity(0.62), Color.black.opacity(0.45)]
                : [Color.white.opacity(0.95), Color.white.opacity(0.85)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        let capsuleHighlight = LinearGradient(
            colors: isDark
                ? [Color.white.opacity(0.08), Color.white.opacity(0.02)]
                : [Color.white.opacity(0.35), Color.white.opacity(0.15)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        let capsuleStroke = isDark ? Color.white.opacity(0.18) : Color.black.opacity(0.08)
        let outerGlow = isDark ? Color.white.opacity(0.18) : Color.white.opacity(0.35)
        let shadowColor = isDark ? Color.black.opacity(0.55) : Color.black.opacity(0.18)

        return HStack(spacing: 8) {
            Text(appDisplayName())
                .font(.system(size: 16, weight: .heavy, design: .rounded))
                .foregroundColor(titleColor)
            Text(versionSummary())
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(subtitleColor)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
        .background(
            ZStack {
                Capsule(style: .continuous)
                    .fill(capsuleFill)
                Capsule(style: .continuous)
                    .fill(capsuleHighlight)
                    .blendMode(.screen)
                Capsule(style: .continuous)
                    .strokeBorder(capsuleStroke, lineWidth: 1)
                Capsule(style: .continuous)
                    .stroke(outerGlow, lineWidth: 0.8)
                    .blur(radius: 4)
                    .opacity(0.35)
            }
        )
        .shadow(color: shadowColor, radius: 12, y: 6)
        .allowsHitTesting(false)
    }

    // MARK: - Tabs

    private var tabBar: some View {
        HStack(spacing: 14) {
            ForEach(SettingsTab.allCases) { tab in
                tabButton(for: tab)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 10)
    }

    private func tabButton(for tab: SettingsTab) -> some View {
        let isSelected = activeTab == tab
        return Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                activeTab = tab
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: tab.iconName)
                    .font(.system(size: 16, weight: .semibold))
                Text(tab.title)
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundColor(isSelected ? Color.accentColor : Color.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                ZStack {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.accentColor.opacity(0.22))
                            .matchedGeometryEffect(id: "tabSelection", in: tabSelectionNamespace)
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(
                        isSelected ? Color.accentColor : Color.white.opacity(0.12),
                        lineWidth: isSelected ? 1.6 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(tab.title))
    }

    @ViewBuilder
    private var tabContent: some View {
        switch activeTab {
        case .visuals:
            visualsTab
        case .shortcuts:
            shortcutsTab
        case .hiddenApps:
            hiddenAppsTab
        case .about:
            aboutTab
        }
    }

    // MARK: - Visuals Content

    private var visualsTab: some View {
        settingsPanel(
            icon: "rocket.launch.fill",
            title: String(localized: "Launcher"),
            subtitle: String(localized: "Launch at login, layouts, and background styling."),
            customIcon: {
                AnyView(
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 28, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .shadow(color: Color.black.opacity(0.25), radius: 4, y: 2)
                )
            }
        ) {
            VStack(spacing: 18) {
                launchAtLoginToggle
                panelDivider
                launcherLayoutPicker
                panelDivider
                iconVisibilitySection
                panelDivider
                backgroundStyleSection
                panelDivider
                autoGapToggle
            }
        }
    }

    // MARK: - Shortcuts Content

    private var shortcutsTab: some View {
        settingsPanel(
            icon: "keyboard.fill",
            title: String(localized: "Keyboard"),
            subtitle: String(localized: "Global shortcuts and quick reset tools.")
        ) {
            VStack(alignment: .leading, spacing: 14) {
                hotkeySection
                hotCornerSection
                panelDivider
                resetSection
            }
        }
    }

    // MARK: - Hidden Apps Content

    private var hiddenAppsTab: some View {
        settingsPanel(
            icon: "eye.slash.fill",
            title: String(localized: "Hidden Apps"),
            subtitle: String(localized: "Choose which applications stay out of the launcher grid.")
        ) {
            VStack(spacing: 16) {
                userApplicationsFolderToggle
                hiddenAppsList
            }
        }
    }

    private var userApplicationsFolderToggle: some View {
        let userApplicationsPath = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Applications")
            .path

        return VStack(alignment: .leading, spacing: 6) {
            Toggle("Include user Applications folder", isOn: Binding(
                get: { settingsStore.settingsSnapshot.shouldScanUserApplicationsFolder },
                set: { settingsStore.setShouldScanUserApplicationsFolder($0) }
            ))
            .toggleStyle(.switch)

            Text("Launchy searches \(userApplicationsPath) for apps when enabled.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var launchAtLoginToggle: some View {
        Toggle("Launch at login", isOn: Binding(
            get: { settingsStore.settingsSnapshot.launchesAtLogin },
            set: { settingsStore.setLaunchAtLogin($0) }
        ))
        .toggleStyle(.switch)
    }

    private var launcherLayoutPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Launcher layout")
                .font(.subheadline)
                .fontWeight(.semibold)

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
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var iconVisibilitySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Hide Dock icon", isOn: Binding(
                get: { settingsStore.settingsSnapshot.isDockIconHidden },
                set: { settingsStore.setDockIconHidden($0) }
            ))

            Toggle("Hide menu bar icon", isOn: Binding(
                get: { settingsStore.settingsSnapshot.isMenuBarIconHidden },
                set: { settingsStore.setMenuBarIconHidden($0) }
            ))

            Text("If both icons are hidden, Launchy keeps the toggle shortcut enabled so you can still open it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var backgroundStyleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Background style")
                .font(.subheadline)
                .fontWeight(.semibold)

            Picker("", selection: Binding(
                get: { settingsStore.settingsSnapshot.backgroundStylePreference },
                set: { settingsStore.setPreferredBackgroundStyle($0) }
            )) {
                ForEach(LauncherSettings.PreferredBackgroundStyle.allCases, id: \.self) { style in
                    Text(style.displayName).tag(style)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            if settingsStore.settingsSnapshot.backgroundStylePreference == .solid {
                solidColorPalette
            }
        }
    }

    private var solidColorPalette: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Solid color")
                .font(.caption)
                .foregroundColor(.secondary)
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

    private var autoGapToggle: some View {
        Toggle("Icons move up when there's space", isOn: Binding(
            get: { settingsStore.settingsSnapshot.fillsGapsAutomatically },
            set: { settingsStore.setFillsGapsAutomatically($0) }
        ))
        .toggleStyle(.switch)
    }

    private var hotkeySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HotkeyRecorderRow(
                title: String(localized: "Toggle Launchy"),
                message: String(localized: "Works everywhere. Press Delete to clear or Reset to restore Cmd+Shift+Space."),
                hotkey: settingsStore.settingsSnapshot.launcherHotkey,
                placeholder: String(localized: "Click to record"),
                onChange: { settingsStore.setLauncherHotkey($0) },
                onReset: { settingsStore.resetLauncherHotkeyToDefault() }
            )

            HotkeyRecorderRow(
                title: String(localized: "Switch fullscreen <-> floaty"),
                message: String(localized: "Pick a shortcut if you want to flip layouts quickly. Leave empty to disable."),
                hotkey: settingsStore.settingsSnapshot.layoutToggleHotkey,
                placeholder: String(localized: "Add shortcut"),
                onChange: { settingsStore.setLayoutToggleHotkey($0) },
                showResetButton: false
            )
        }
    }

    private var hotCornerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Enable hot corner toggle", isOn: Binding(
                get: { settingsStore.settingsSnapshot.hotCornerEnabled },
                set: { settingsStore.setHotCornerEnabled($0) }
            ))
            .toggleStyle(.switch)

            Text("Move the cursor into the selected corner to show or hide Launchy.")
                .font(.caption)
                .foregroundColor(.secondary)

            if settingsStore.settingsSnapshot.hotCornerEnabled {
                HStack {
                    Text("Corner")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Spacer()
                    Picker("", selection: Binding(
                        get: { settingsStore.settingsSnapshot.hotCornerPosition },
                        set: { settingsStore.setHotCornerPosition($0) }
                    )) {
                        ForEach(HotCornerPosition.allCases, id: \.self) { position in
                            Text(position.displayName).tag(position)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }

                Text("macOS may prompt for Input Monitoring the first time you enable this; if it doesn’t, add Launchy in System Settings → Privacy & Security → Input Monitoring.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var resetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                confirmArrangementReset()
            } label: {
                Label("Reset icon arrangement...", systemImage: "arrow.counterclockwise.circle")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)

            Text("Deletes your saved ordering and folders, then rebuilds pages from scratch. Custom app names stay, hidden apps stay hidden. Type RESET to confirm.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var hiddenAppsList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Application")
                Spacer(minLength: 0)
                Text("Hidden")
            }
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .textCase(.uppercase)
            .foregroundColor(Color.primary.opacity(0.65))
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.08),
                        Color.white.opacity(0.02)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )

            Divider()
                .overlay(Color.white.opacity(0.05))

            if settingsStore.discoveredApps.isEmpty {
                hiddenAppsEmptyState
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(settingsStore.discoveredApps.enumerated()), id: \.element.id) { index, app in
                            hiddenAppRow(app: app)

                            if index < settingsStore.discoveredApps.count - 1 {
                                Divider()
                                    .overlay(Color.white.opacity(0.05))
                                    .padding(.leading, 44)
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
                .frame(minHeight: 200, maxHeight: 320)
                .glassListScrollBackground()
            }
        }
        .background(glassListBackground(cornerRadius: 22, highlight: true))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(LinearGradient(
                    colors: [Color.white.opacity(0.45), Color.white.opacity(0.08)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ), lineWidth: 1.1)
                .blendMode(.plusLighter)
        )
        .shadow(color: Color.black.opacity(0.3), radius: 20, y: 14)
        .padding(.horizontal, 2)
        .padding(.top, 2)
    }

    private var hiddenAppsEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "app")
                .font(.system(size: 30, weight: .medium))
                .foregroundColor(.secondary)
            Text("Scanning for applications...")
                .multilineTextAlignment(.center)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    private func hiddenAppRow(app: AppItem) -> some View {
        HStack(alignment: .center, spacing: 12) {
            iconView(for: app)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.resolvedDisplayName)
                Text(app.bundleIdentifier)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(isOn: Binding(
                get: { settingsStore.isHidden(app) },
                set: { settingsStore.setHidden($0, for: app) }
            )) {
                EmptyView()
            }
            .toggleStyle(.switch)
            .labelsHidden()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.02))
        )
    }

    // MARK: - About Content

    private var aboutTab: some View {
        settingsPanel(
            icon: "info.circle.fill",
            title: String(localized: "About Launchy"),
            subtitle: String(localized: "Version details, credits, and useful links.")
        ) {
            VStack(spacing: 22) {
                aboutHeader
                panelDivider
                aboutLinks
                panelDivider
                aboutActions
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var aboutHeader: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .shadow(color: Color.black.opacity(0.25), radius: 10, x: 0, y: 6)

            Text(appDisplayName())
                .font(.title2)
                .fontWeight(.semibold)

            Text(developerSummary())
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Text(versionSummary())
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var aboutLinks: some View {
        VStack(alignment: .leading, spacing: 12) {
            aboutLinkRow(
                icon: "link",
                title: String(localized: "Project Website"),
                urlString: "https://github.com/Punshnut/macos-launchy"
            )

            aboutLinkRow(
                icon: "sparkle.magnifyingglass",
                title: String(localized: "Report an Issue"),
                urlString: "https://github.com/Punshnut/macos-launchy/issues"
            )

            aboutLinkRow(
                icon: "envelope",
                title: String(localized: "Support Email"),
                urlString: "https://github.com/Punshnut/macos-launchy"
            )
        }
    }

    @ViewBuilder
    private func aboutLinkRow(icon: String, title: String, urlString: String) -> some View {
        if let url = URL(string: urlString) {
            Link(destination: url) {
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .frame(width: 20)
                    Text(title)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .imageScale(.small)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.04))
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var aboutActions: some View {
        HStack(spacing: 14) {
            Button {
                openIntroduction()
            } label: {
                Label("Revisit Introduction...", systemImage: "sparkles")
            }
            .buttonStyle(.bordered)

            Spacer()

            Button {
                if let url = URL(string: "https://github.com/Punshnut/macos-launchy") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Label("View on GitHub", systemImage: "chevron.right.circle")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Shared Helpers

    private var panelDivider: some View {
        Divider()
            .overlay(Color.white.opacity(0.08))
            .padding(.vertical, 1)
    }

    private func settingsPanel<Content: View>(
        icon: String,
        title: String,
        subtitle: String? = nil,
        customIcon: (() -> AnyView)? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                Group {
                    if let customIcon {
                        customIcon()
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.accentColor)
                            .frame(width: 32, height: 32)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.accentColor.opacity(0.15))
                            )
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
            }

            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.03))
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }

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

    private func glassListBackground(cornerRadius: CGFloat = 22, highlight: Bool = false) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
                LinearGradient(
                    colors: highlight
                        ? [Color.white.opacity(0.28), Color.white.opacity(0.05)]
                        : [Color.white.opacity(0.22), Color.white.opacity(0.04)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 0.6)
            )
    }

    private func openIntroduction() {
        IntroductionWindowController.shared.present(startingAt: 0, markCompletionOnFinish: false)
    }

    @MainActor
    private func confirmArrangementReset() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Reset icon arrangement?")
        alert.informativeText = String(localized: "This deletes your saved ordering, folders, and page layout. Type RESET to continue.")

        let confirmationField = NSTextField(string: "")
        confirmationField.placeholderString = String(localized: "RESET")
        confirmationField.frame = NSRect(x: 0, y: 0, width: 220, height: 22)
        alert.accessoryView = confirmationField

        alert.addButton(withTitle: String(localized: "Reset"))
        alert.addButton(withTitle: String(localized: "Cancel"))

        if let window = hostingWindow {
            NSApp.activate(ignoringOtherApps: true)
            alert.beginSheetModal(for: window) { response in
                handleArrangementResetResponse(response, typedValue: confirmationField.stringValue)
            }
            DispatchQueue.main.async {
                window.makeFirstResponder(confirmationField)
            }
        } else {
            let response = presentModalAlert(alert)
            handleArrangementResetResponse(response, typedValue: confirmationField.stringValue)
        }
    }

    @MainActor
    private func handleArrangementResetResponse(_ response: NSApplication.ModalResponse, typedValue: String) {
        let normalized = typedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard response == .alertFirstButtonReturn,
              normalized.caseInsensitiveCompare(String(localized: "RESET")) == .orderedSame else { return }
        settingsStore.requestArrangementReset()
    }

    @MainActor
    private func presentModalAlert(_ alert: NSAlert) -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        let alertWindow = alert.window
        alertWindow.level = .statusBar
        alertWindow.collectionBehavior.insert([.moveToActiveSpace, .fullScreenAuxiliary, .canJoinAllSpaces])
        alertWindow.makeKeyAndOrderFront(nil)
        alertWindow.orderFrontRegardless()

        let response = alert.runModal()

        hostingWindow?.makeKeyAndOrderFront(nil)

        return response
    }

    // MARK: - Window Configuration

    private func applyWindowConfiguration(for window: NSWindow) {
        updateWindowChrome(for: window)

        guard hasAppliedInitialWindowSizing == false else { return }
        hasAppliedInitialWindowSizing = true
        resizeWindow(for: activeTab, in: window, animated: false)
    }

    private func resizeWindow(for tab: SettingsTab, animated: Bool) {
        guard let window = hostingWindow else { return }
        resizeWindow(for: tab, in: window, animated: animated)
    }

    private func resizeWindow(for tab: SettingsTab, in window: NSWindow, animated: Bool) {
        let currentFrame = window.frame
        let currentContentRect = window.contentRect(forFrameRect: currentFrame)
        let targetContentHeight = SettingsWindowMetrics.preferredContentHeight(for: tab)

        guard abs(currentContentRect.height - targetContentHeight) > 0.5 else { return }

        let targetContentSize = NSSize(
            width: currentContentRect.width,
            height: targetContentHeight
        )
        let targetFrameSize = window.frameRect(
            forContentRect: NSRect(origin: .zero, size: targetContentSize)
        ).size

        // Pin resizing to the top-center so the custom chrome stays put.
        let anchorPoint = NSPoint(x: currentFrame.midX, y: currentFrame.maxY)
        let newOrigin = NSPoint(
            x: anchorPoint.x - targetFrameSize.width / 2,
            y: anchorPoint.y - targetFrameSize.height
        )
        let newFrame = NSRect(origin: newOrigin, size: targetFrameSize)
        window.setFrame(newFrame, display: true, animate: animated)
    }

    private var borderStrokeColor: Color {
        Color.white.opacity(0.12)
    }

    private func updateWindowChrome(for window: NSWindow?) {
        guard let window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
    }

    private var topChromeHeight: CGFloat {
        34
    }

    private var topChromeControlInset: CGFloat {
        12
    }

    private func performWindowAction(for kind: WindowControlKind) {
        guard let window = hostingWindow else { return }
        switch kind {
        case .close:
            window.performClose(nil)
        case .minimize:
            window.performMiniaturize(nil)
        case .zoom:
            window.performZoom(nil)
        }
    }

    @ViewBuilder
    private var outerBackgroundView: some View {
        let cornerRadius: CGFloat = 32
        FrostedBackgroundView(material: .hudWindow)
            .overlay(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private func appDisplayName() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Launchy"
    }

    private func versionSummary() -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "--"
        return String(localized: "Version \(version)")
    }

    private func developerSummary() -> String {
        if let copyright = Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String {
            return copyright
        }
        return String(localized: "Built by the Launchy team")
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

    var placeholderText: String = String(localized: "Click to record") {
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
            placeholderString = String(localized: "Press shortcut...")
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
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let hostingController: NSHostingController<SettingsWindow>
    @MainActor
    var onClose: (() -> Void)?

    init() {
        let view = SettingsWindow()
        hostingController = NSHostingController(rootView: view)
        let defaultContentSize = SettingsWindowMetrics.defaultContentSize
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: defaultContentSize.width, height: defaultContentSize.height),
            styleMask: [
                .titled,
                .closable,
                .miniaturizable,
                .resizable,
                .fullSizeContentView
            ],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "Launchy Settings")
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.toolbarStyle = .unifiedCompact
        window.isReleasedWhenClosed = false
        // Keep the settings window visible above the launcher UI, even in fullscreen, while leaving room for alerts.
        window.level = .statusBar
        window.collectionBehavior.insert(.fullScreenAuxiliary)
        window.collectionBehavior.insert(.canJoinAllSpaces)
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.contentMinSize = SettingsWindowMetrics.minimumContentSize
        window.center()
        window.contentViewController = hostingController
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Brings the settings window to the front and activates the app if needed.
    func showWindowAndActivate() {
        guard let window else { return }
        centerWindowOnPreferredScreen()
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func centerWindowOnPreferredScreen() {
        guard let window else { return }
        guard let screen = ScreenProvider.screenUnderMouseOrMain() else { return }

        let contentSize = window.frame.size
        let visible = screen.visibleFrame
        let targetX = visible.midX - contentSize.width / 2
        let targetY = visible.midY - contentSize.height / 2

        let clampedX = min(
            max(targetX, visible.minX),
            max(visible.maxX - contentSize.width, visible.minX)
        )
        let clampedY = min(
            max(targetY, visible.minY),
            max(visible.maxY - contentSize.height, visible.minY)
        )

        window.setFrameOrigin(NSPoint(x: clampedX, y: clampedY))
    }

    func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            onClose?()
        }
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

// MARK: - Frosted Elements and Window Controls

struct FrostedBackgroundView: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.state = .active
        view.blendingMode = .behindWindow
        view.isEmphasized = true
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.state = .active
    }
}

enum WindowControlKind: CaseIterable, Identifiable {
    case close, minimize, zoom

    var id: String {
        switch self {
        case .close:
            return "close"
        case .minimize:
            return "minimize"
        case .zoom:
            return "zoom"
        }
    }

    var color: Color {
        switch self {
        case .close:
            return Color(red: 1.0, green: 0.37, blue: 0.34)
        case .minimize:
            return Color(red: 1.0, green: 0.78, blue: 0.0)
        case .zoom:
            return Color(red: 0.19, green: 0.81, blue: 0.29)
        }
    }
}

struct WindowControlDot: View {
    let kind: WindowControlKind
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(kind.color)
                .frame(width: 12, height: 12)
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
    }
}

struct HostingWindowFinder: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            onResolve(view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            onResolve(nsView.window)
        }
    }
}

// MARK: - Scroll Background Helper

struct GlassListScrollBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        LinearGradient(
                            colors: [Color.white.opacity(0.16), Color.white.opacity(0.04)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.white.opacity(0.05), lineWidth: 0.8)
            )
    }
}

extension View {
    func glassListScrollBackground() -> some View {
        modifier(GlassListScrollBackground())
    }
}
