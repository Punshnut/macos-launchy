import SwiftUI

/// Coordinates tab selection and keeps SwiftUI state in sync with AppKit's window lifecycle.
@MainActor
final class SettingsWindowCoordinator: ObservableObject {
    @Published var activeTab: SettingsTab = .visuals

    /// Keeps the active tab binding in sync with sidebar selections.
    func selectTab(_ tab: SettingsTab) {
        activeTab = tab
    }
}

/// SwiftUI-based macOS settings window content that drives `LauncherSettings`.
struct SettingsWindow: View {
    /// Backing store powering the macOS settings UI.
    @StateObject private var settingsStore: SettingsWindowStore
    @ObservedObject private var coordinator: SettingsWindowCoordinator
    @State private var hostingWindow: AnyObject?
    @State private var hasAppliedInitialWindowSizing = false
    @Namespace private var tabSelectionNamespace
    @Environment(\.colorScheme) private var colorScheme

    init(
        store: SettingsWindowStore = SettingsWindowStore(),
        coordinator: SettingsWindowCoordinator = SettingsWindowCoordinator()
    ) {
        _settingsStore = StateObject(wrappedValue: store)
        _coordinator = ObservedObject(wrappedValue: coordinator)
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
                    applyWindowConfiguration(for: window)
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
        .onChange(of: coordinator.activeTab) { newValue in
            resizeWindow(for: newValue, animated: true)
        }
        .onAppear {
            settingsStore.resumeIfDormant()
        }
        .onDisappear {
            settingsStore.prepareForDormancy()
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
        let isSelected = coordinator.activeTab == tab
        return Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                coordinator.selectTab(tab)
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
        switch coordinator.activeTab {
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
                    (applicationIconImage() ?? Image(systemName: "app"))
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
                iconSizeSlider
                panelDivider
                pagingOrientationPicker
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
                hiddenAppsOrderToggle
            }
        }
    }

    private var userApplicationsFolderToggle: some View {
        let userApplicationsPath = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Applications")
            .path

        return VStack(alignment: .leading, spacing: 6) {
            Toggle(String(localized: "Include user Applications folder"), isOn: Binding(
                get: { settingsStore.settingsSnapshot.shouldScanUserApplicationsFolder },
                set: { settingsStore.setShouldScanUserApplicationsFolder($0) }
            ))
            .toggleStyle(.switch)

            Text(String(format: String(localized: "Launchy searches %@ for apps when enabled."), userApplicationsPath))
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var launchAtLoginToggle: some View {
        Toggle(String(localized: "Launch at login"), isOn: Binding(
            get: { settingsStore.settingsSnapshot.launchesAtLogin },
            set: { settingsStore.setLaunchAtLogin($0) }
        ))
        .toggleStyle(.switch)
    }

    private var launcherLayoutPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Launcher layout"))
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

            Text(String(localized: "Add a layout toggle shortcut below to flip modes instantly from anywhere."))
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var iconSizeSlider: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Icon size"))
                .font(.subheadline)
                .fontWeight(.semibold)

            Slider(
                value: Binding(
                    get: { settingsStore.settingsSnapshot.iconSizePreference.sliderPosition },
                    set: { settingsStore.setIconSizePreference(IconSizePreference.fromSliderPosition($0)) }
                ),
                in: 0...2,
                step: 1
            )

            HStack {
                Text(IconSizePreference.small.displayName)
                Spacer()
                Text(IconSizePreference.medium.displayName)
                Spacer()
                Text(IconSizePreference.large.displayName)
            }
            .font(.caption)
            .foregroundColor(.secondary)

            Text(String(localized: "Large icon size applies to fullscreen only; floaty uses medium."))
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var pagingOrientationPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(String(localized: "Paging direction"))
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text(String(localized: "Beta"))
                    .font(.caption2)
                    .fontWeight(.bold)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15))
                    .foregroundColor(Color.accentColor)
                    .clipShape(Capsule())
            }

            Picker("", selection: Binding(
                get: { settingsStore.settingsSnapshot.pagingOrientation },
                set: { settingsStore.setPagingOrientation($0) }
            )) {
                ForEach(PagingOrientation.allCases, id: \.self) { orientation in
                    Text(orientation.displayName).tag(orientation)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            Text(String(localized: "Vertical paging moves pages up and down. Indicators move to the left in fullscreen and stay at the bottom in floaty."))
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var iconVisibilitySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(String(localized: "Hide Dock icon"), isOn: Binding(
                get: { settingsStore.settingsSnapshot.isDockIconHidden },
                set: { settingsStore.setDockIconHidden($0) }
            ))

            Toggle(String(localized: "Hide menu bar icon"), isOn: Binding(
                get: { settingsStore.settingsSnapshot.isMenuBarIconHidden },
                set: { settingsStore.setMenuBarIconHidden($0) }
            ))

            Text(String(localized: "If both icons are hidden, Launchy keeps the toggle shortcut enabled so you can still open it."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var backgroundStyleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "Background style"))
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
            Text(String(localized: "Solid color"))
                .font(.caption)
                .foregroundColor(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 32), spacing: 12)], spacing: 12) {
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
        Toggle(String(localized: "Icons move up when there's space"), isOn: Binding(
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
            Toggle(String(localized: "Enable hot corner toggle"), isOn: Binding(
                get: { settingsStore.settingsSnapshot.hotCornerEnabled },
                set: { settingsStore.setHotCornerEnabled($0) }
            ))
            .toggleStyle(.switch)

            Text(String(localized: "Move the cursor into the selected corner to show or hide Launchy."))
                .font(.caption)
                .foregroundColor(.secondary)

            if settingsStore.settingsSnapshot.hotCornerEnabled {
                HStack {
                    Text(String(localized: "Corner"))
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

                Text(String(localized: "macOS may prompt for Input Monitoring the first time you enable this; if it doesn’t, add Launchy in System Settings → Privacy & Security → Input Monitoring."))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var resetSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                confirmArrangementReset()
            } label: {
                Label(String(localized: "Reset icon arrangement..."), systemImage: "arrow.counterclockwise.circle")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)

            Text(String(localized: "Deletes your saved ordering and folders, then rebuilds pages from scratch. Custom app names stay, hidden apps stay hidden."))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var hiddenAppsList: some View {
        VStack(spacing: 0) {
            HStack {
                Text(String(localized: "Application"))
                Spacer(minLength: 0)
                Text(String(localized: "Hidden"))
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

            let orderedEntries = settingsStore.orderedHiddenEntries
            if settingsStore.discoveredApps.isEmpty {
                hiddenAppsEmptyState
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
            } else if orderedEntries.isEmpty {
                hiddenAppsEmptyState
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(orderedEntries.enumerated()), id: \.element.id) { index, entry in
                            hiddenEntryRow(entry: entry)

                            if index < orderedEntries.count - 1 {
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

    private var hiddenAppsOrderToggle: some View {
        Toggle(String(localized: "Show hidden apps first"), isOn: Binding(
            get: { settingsStore.settingsSnapshot.showHiddenAppsFirst },
            set: { settingsStore.setShowHiddenAppsFirst($0) }
        ))
        .toggleStyle(.checkbox)
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var hiddenAppsEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "app")
                .font(.system(size: 30, weight: .medium))
                .foregroundColor(.secondary)
            Text(String(localized: "Scanning for applications..."))
                .multilineTextAlignment(.center)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    private func hiddenEntryRow(entry: HiddenAppsListEntry) -> some View {
        HStack(alignment: .center, spacing: 12) {
            iconView(for: entry)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                if let subtitle = entry.subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Toggle(isOn: Binding(
                get: { entry.isHidden },
                set: { entry.toggle($0) }
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

    private func iconView(for entry: HiddenAppsListEntry) -> some View {
        Group {
            if let image = entry.icon {
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
            (applicationIconImage() ?? Image(systemName: "app"))
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
                urlString: "https://www.launchy.space"
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
                Label(String(localized: "Revisit Introduction..."), systemImage: "sparkles")
            }
            .buttonStyle(.bordered)

            Spacer()

            Button {
                if let url = URL(string: "https://github.com/Punshnut/macos-launchy") {
                    SettingsWindowAppKitBridge.openURL(url)
                }
            } label: {
                Label(String(localized: "View on GitHub"), systemImage: "chevron.right.circle")
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
            if let image = settingsStore.icon(for: app) {
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

    /// Launches the onboarding flow from the About tab without marking completion.
    private func openIntroduction() {
        IntroductionWindowController.shared.present(startingAt: 0, markCompletionOnFinish: false)
    }

    /// Shows a confirmation dialog requiring "RESET" before clearing the saved arrangement.
    private func confirmArrangementReset() {
        SettingsWindowAlertPresenter.confirmArrangementReset(
            hostingWindow: hostingWindow,
            initialSorting: settingsStore.arrangementResetSorting,
            onConfirm: { @MainActor [weak settingsStore] sorting in
                settingsStore?.setArrangementResetSorting(sorting)
                settingsStore?.requestArrangementReset(using: sorting)
            }
        )
    }

    // MARK: - Window Configuration

    /// Applies one-time window styling and initial sizing when the NSWindow becomes available.
    private func applyWindowConfiguration(for window: AnyObject?) {
        SettingsWindowHostManager.applyConfiguration(to: window)
        guard hasAppliedInitialWindowSizing == false else { return }
        hasAppliedInitialWindowSizing = true
        SettingsWindowHostManager.resize(window: window, for: coordinator.activeTab, animated: false)
    }

    private func resizeWindow(for tab: SettingsTab, animated: Bool) {
        SettingsWindowHostManager.resize(window: hostingWindow, for: tab, animated: animated)
    }

    private var borderStrokeColor: Color {
        Color.white.opacity(0.12)
    }

    private func performWindowAction(for kind: WindowControlKind) {
        SettingsWindowHostManager.performWindowAction(kind, on: hostingWindow)
    }

    private var topChromeHeight: CGFloat {
        34
    }

    private var topChromeControlInset: CGFloat {
        12
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
        let rawVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "--"
        return String(format: String(localized: "Version %@"), rawVersion)
    }

    private func developerSummary() -> String {
        if let copyright = Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String {
            return copyright
        }
        return String(localized: "Built by the Launchy team")
    }

    private func applicationIconImage() -> Image? {
        SettingsWindowAppKitBridge.applicationIconImage()
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
    @State private var cancelToken: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline)
            HStack(spacing: 10) {
                HotkeyRecorderField(
                    hotkey: hotkey,
                    placeholder: placeholder,
                    cancelToken: cancelToken,
                    onChange: onChange
                )
                .frame(width: 240, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.02))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1.6)
                )
                .shadow(color: Color.accentColor.opacity(0.18), radius: 6, y: 1)

                HStack(spacing: 6) {
                    if showResetButton, let onReset {
                        Button(String(localized: "Reset")) {
                            cancelToken += 1
                            onReset()
                        }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                    }

                    Button(String(localized: "Clear")) {
                        cancelToken += 1
                        onChange(nil)
                    }
                    .disabled(hotkey == nil)
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.05))
                )
            }
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(LinearGradient(
                    colors: [Color.white.opacity(0.25), Color.white.opacity(0.06)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ), lineWidth: 1)
        )
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
