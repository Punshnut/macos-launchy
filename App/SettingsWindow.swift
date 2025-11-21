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

// MARK: - Settings Window UI

private enum SettingsTab: Int, CaseIterable, Identifiable {
    case applauncher
    case about

    var id: Int { rawValue }

    var iconName: String {
        switch self {
        case .applauncher:
            return "rocket.launch"
        case .about:
            return "info.circle"
        }
    }

    var title: String {
        switch self {
        case .applauncher:
            return "Applauncher"
        case .about:
            return "About"
        }
    }
}

/// SwiftUI-based macOS settings window content that drives `LauncherSettings`.
struct SettingsWindow: View {
    /// Backing store powering the macOS settings UI.
    @StateObject private var settingsStore: SettingsWindowStore
    @State private var activeTab: SettingsTab = .applauncher
    @State private var hostingWindow: NSWindow?
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
                    updateWindowChrome(for: window)
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
        case .applauncher:
            applauncherTab
        case .about:
            aboutTab
        }
    }

    // MARK: - Applauncher Content

    private var applauncherTab: some View {
        VStack(spacing: 16) {
            settingsPanel(
                icon: "rocket.launch.fill",
                title: "Launcher",
                subtitle: "Launch at login, layouts, and background styling.",
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
                    dockIconSection
                    panelDivider
                    backgroundStyleSection
                    panelDivider
                    autoGapToggle
                }
            }

            settingsPanel(
                icon: "keyboard.fill",
                title: "Keyboard",
                subtitle: "Global shortcuts and quick reset tools."
            ) {
                VStack(alignment: .leading, spacing: 14) {
                    hotkeySection
                    panelDivider
                    resetSection
                }
            }

            settingsPanel(
                icon: "eye.slash.fill",
                title: "Hidden Apps",
                subtitle: "Choose which applications stay out of the launcher grid."
            ) {
                hiddenAppsList
            }
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

    private var dockIconSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Show Dock icon (Floaty mode only)", isOn: Binding(
                get: { settingsStore.settingsSnapshot.isFloatyDockIconVisible },
                set: { settingsStore.setFloatyDockIconVisible($0) }
            ))
            .disabled(settingsStore.settingsSnapshot.selectedLauncherMode != .floaty)

            if settingsStore.settingsSnapshot.selectedLauncherMode == .floaty {
                Text("Hide the Dock icon to keep Launchy out of the way when using the floaty panel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Dock icon always shows in fullscreen mode, so this toggle is temporarily disabled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
                title: "Toggle Launchy",
                message: "Works everywhere. Press Delete to clear or Reset to restore Cmd+Shift+Space.",
                hotkey: settingsStore.settingsSnapshot.launcherHotkey,
                placeholder: "Click to record",
                onChange: { settingsStore.setLauncherHotkey($0) },
                onReset: { settingsStore.resetLauncherHotkeyToDefault() }
            )

            HotkeyRecorderRow(
                title: "Switch fullscreen <-> floaty",
                message: "Pick a shortcut if you want to flip layouts quickly. Leave empty to disable.",
                hotkey: settingsStore.settingsSnapshot.layoutToggleHotkey,
                placeholder: "Add shortcut",
                onChange: { settingsStore.setLayoutToggleHotkey($0) },
                showResetButton: false
            )
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

            Text("Deletes your saved ordering and folders, then rebuilds pages from scratch. Type RESET to confirm.")
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
            title: "About Launchy",
            subtitle: "Version details, credits, and useful links."
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
                title: "Project Website",
                urlString: "https://github.com/Punshnut/macos-launchy"
            )

            aboutLinkRow(
                icon: "sparkle.magnifyingglass",
                title: "Report an Issue",
                urlString: "https://github.com/Punshnut/macos-launchy/issues"
            )

            aboutLinkRow(
                icon: "envelope",
                title: "Support Email",
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
        return "Version \(version)"
    }

    private func developerSummary() -> String {
        if let copyright = Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String {
            return copyright
        }
        return "Built by the Launchy team"
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
            placeholderString = "Press shortcut..."
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
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 620),
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
        window.title = "Launchy Settings"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.toolbarStyle = .unifiedCompact
        window.isReleasedWhenClosed = false
        // Keep the settings window visible above the launcher UI, even in fullscreen.
        window.level = .screenSaver
        window.collectionBehavior.insert(.fullScreenAuxiliary)
        window.collectionBehavior.insert(.canJoinAllSpaces)
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.contentMinSize = NSSize(width: 620, height: 520)
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
