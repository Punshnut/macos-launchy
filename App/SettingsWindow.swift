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
            FrostedBackgroundView(material: .hudWindow)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topChromeSpacer
                tabBar
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: 8) {
                        tabContent
                            .transaction { $0.animation = nil }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
            }
            .frame(minWidth: 640, minHeight: 560)
            .overlay(
                HostingWindowFinder { window in
                    hostingWindow = window
                    applyWindowConfiguration(for: window)
                }
                .allowsHitTesting(false)
            )
            .overlay(alignment: .topLeading) {
                windowControls
                    .padding(.top, topChromeControlInset)
                    .padding(.leading, 22)
                    .padding(.trailing, 22)
            }
        }
        .ignoresSafeArea(.all, edges: .top)
        .overlay(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .stroke(borderStrokeColor, lineWidth: 1)
                .allowsHitTesting(false)
                .ignoresSafeArea()
        )
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
                    .padding(.horizontal, 60)
                    .padding(.top, 6)
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

        return HStack(spacing: 8) {
            Text(appDisplayName())
                .font(.system(size: 16, weight: .heavy, design: .rounded))
                .foregroundColor(titleColor)
            Text(versionSummary())
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(subtitleColor)
        }
        .allowsHitTesting(false)
    }

    // MARK: - Tabs

    private var tabBar: some View {
        HStack(spacing: 6) {
            ForEach(SettingsTab.allCases) { tab in
                tabButton(for: tab)
            }
        }
        .padding(5)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.primary.opacity(0.09))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
                )
        )
        .shadow(color: Color.black.opacity(0.08), radius: 4, y: 2)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    /// Renders a sidebar tab button. Hover state is owned locally by `TabButtonView`
    /// so only the individual pill re-renders on hover, not the whole settings view.
    private func tabButton(for tab: SettingsTab) -> some View {
        TabButtonView(
            tab: tab,
            isSelected: coordinator.activeTab == tab,
            namespace: tabSelectionNamespace
        ) {
            SettingsWindowAppKitBridge.performTabSelectionHaptic()
            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                coordinator.selectTab(tab)
            }
        }
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
            title: String(localized: "SettingsLauncherSectionTitle"),
            subtitle: String(localized: "SettingsLauncherSectionBody"),
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
            VStack(alignment: .leading, spacing: 8) {
                launchAtLoginToggle
                panelDivider
                launcherLayoutPicker
                panelDivider
                backgroundStyleSection
                panelDivider
                iconSizeSlider
                panelDivider
                pagingOrientationPicker
                iconBehaviorListSection
            }
        }
    }

    // MARK: - Shortcuts Content

    private var shortcutsTab: some View {
        settingsPanel(
            icon: "keyboard.fill",
            title: String(localized: "SettingsKeyboardSectionTitle"),
            subtitle: String(localized: "SettingsKeyboardSectionBody")
        ) {
            VStack(alignment: .leading, spacing: 8) {
                hotkeySection
                hotCornerSection
                panelDivider
                resetSection
                panelDivider
                backupSection
            }
            .frame(maxWidth: 540)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    // MARK: - Hidden Apps Content

    private var hiddenAppsTab: some View {
        settingsPanel(
            icon: "eye.slash.fill",
            title: String(localized: "SettingsTabHiddenApps"),
            subtitle: String(localized: "SettingsHiddenAppsSectionBody")
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
            Toggle(String(localized: "SettingsUserAppsFolderToggle"), isOn: Binding(
                get: { settingsStore.settingsSnapshot.shouldScanUserApplicationsFolder },
                set: { settingsStore.setShouldScanUserApplicationsFolder($0) }
            ))
            .toggleStyle(.switch)

            Text(String(format: String(localized: "SettingsUserAppsFolderBody"), userApplicationsPath))
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var launchAtLoginToggle: some View {
        Toggle(String(localized: "SettingsLaunchAtLoginToggle"), isOn: Binding(
            get: { settingsStore.settingsSnapshot.launchesAtLogin },
            set: { settingsStore.setLaunchAtLogin($0) }
        ))
        .toggleStyle(.switch)
    }

    private var launcherLayoutPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(String(localized: "SettingsLayoutPickerLabel"))
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text("BETA")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }

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
            .frame(maxWidth: 320)
            .frame(maxWidth: .infinity, alignment: .center)

            Text(String(localized: "SettingsLayoutPickerHelpText"))
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var iconSizeSlider: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "SettingsIconSizeLabel"))
                .font(.subheadline)
                .fontWeight(.semibold)

            VStack(spacing: 3) {
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
            }
            .frame(maxWidth: 320)
            .frame(maxWidth: .infinity, alignment: .center)

            Text(String(localized: "SettingsIconSizeLargeNote"))
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var pagingOrientationPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "SettingsPagingDirectionLabel"))
                .font(.subheadline)
                .fontWeight(.semibold)

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
            .frame(maxWidth: 220)
            .frame(maxWidth: .infinity, alignment: .center)

            Text(String(localized: "SettingsPagingDirectionBody"))
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var iconBehaviorListSection: some View {
        VStack(spacing: 0) {
            HStack {
                Text(String(localized: "SettingsDockIconToggle"))
                Spacer()
                Toggle("", isOn: Binding(
                    get: { settingsStore.settingsSnapshot.isDockIconHidden },
                    set: { settingsStore.setDockIconHidden($0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            Divider().overlay(Color.white.opacity(0.06))

            HStack {
                Text(String(localized: "SettingsMenuBarIconToggle"))
                Spacer()
                Toggle("", isOn: Binding(
                    get: { settingsStore.settingsSnapshot.isMenuBarIconHidden },
                    set: { settingsStore.setMenuBarIconHidden($0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            Text(String(localized: "SettingsIconsHiddenHelpText"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)

            Divider().overlay(Color.white.opacity(0.06))

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "SettingsDockFolderGroupToggle"))
                    Text(String(localized: "SettingsDockFolderGroupBody"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { settingsStore.settingsSnapshot.sortsDockMenuFoldersLast },
                    set: { settingsStore.setSortsDockMenuFoldersLast($0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            Divider().overlay(Color.white.opacity(0.06))

            HStack {
                Text(String(localized: "SettingsIconsFloatToggle"))
                Spacer()
                Toggle("", isOn: Binding(
                    get: { settingsStore.settingsSnapshot.fillsGapsAutomatically },
                    set: { settingsStore.setFillsGapsAutomatically($0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 0.8)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var backgroundStyleSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "SettingsBackgroundStyleLabel"))
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
            .frame(maxWidth: 400)
            .frame(maxWidth: .infinity, alignment: .center)

            if settingsStore.settingsSnapshot.backgroundStylePreference == .solid {
                solidColorPalette
            }
        }
    }

    private var solidColorPalette: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "SettingsSolidColorPickerLabel"))
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

    private var hotkeySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HotkeyRecorderRow(
                title: String(localized: "SettingsToggleLaunchyLabel"),
                message: String(localized: "SettingsToggleLaunchyBody"),
                hotkey: settingsStore.settingsSnapshot.launcherHotkey,
                placeholder: String(localized: "SettingsShortcutClickToRecord"),
                onChange: { settingsStore.setLauncherHotkey($0) },
                onReset: { settingsStore.resetLauncherHotkeyToDefault() }
            )

            HotkeyRecorderRow(
                title: String(localized: "SettingsLayoutToggleShortcutLabel"),
                message: String(localized: "SettingsLayoutToggleShortcutBody"),
                hotkey: settingsStore.settingsSnapshot.layoutToggleHotkey,
                placeholder: String(localized: "SettingsAddShortcutButton"),
                onChange: { settingsStore.setLayoutToggleHotkey($0) },
                showResetButton: false
            )
        }
    }

    private var hotCornerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(String(localized: "SettingsHotCornerToggle"), isOn: Binding(
                get: { settingsStore.settingsSnapshot.hotCornerEnabled },
                set: { settingsStore.setHotCornerEnabled($0) }
            ))
            .toggleStyle(.switch)

            Text(String(localized: "SettingsHotCornerBody"))
                .font(.caption)
                .foregroundColor(.secondary)

            if settingsStore.settingsSnapshot.hotCornerEnabled {
                HStack {
                    Text(String(localized: "SettingsHotCornerPickerLabel"))
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

                Text(String(localized: "SettingsHotCornerPermissionNote"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var resetSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                confirmArrangementReset()
            } label: {
                Label(String(localized: "SettingsResetArrangementButton"), systemImage: "arrow.counterclockwise.circle")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)

            Text(String(localized: "SettingsResetArrangementBody"))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var backupSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "BackupRestoreSectionTitle"))
                .font(.subheadline)
                .fontWeight(.semibold)

            Text(String(localized: "BackupRestoreSectionBody"))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button {
                    settingsStore.exportBackup(hostingWindow: hostingWindow)
                } label: {
                    Label(String(localized: "BackupExportButton"), systemImage: "arrow.down.doc.fill")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    settingsStore.importBackup(hostingWindow: hostingWindow)
                } label: {
                    Label(String(localized: "BackupRestoreButton"), systemImage: "arrow.up.doc.fill")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var hiddenAppsList: some View {
        VStack(spacing: 0) {
            HStack {
                Text(String(localized: "SettingsHiddenAppsColumnApp"))
                Spacer(minLength: 0)
                Text(String(localized: "SettingsHiddenAppsColumnHidden"))
            }
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .textCase(.uppercase)
            .foregroundColor(Color.primary.opacity(0.65))
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
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
        Toggle(String(localized: "SettingsShowHiddenAppsFirstToggle"), isOn: Binding(
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
            Text(String(localized: "SettingsScanningAppsStatus"))
                .multilineTextAlignment(.center)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    /// Renders one hide/show row in the hidden apps list.
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
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.02))
        )
    }

    /// Shows either the discovered app icon or a fallback symbol.
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
            title: String(localized: "SettingsAboutTitle"),
            subtitle: String(localized: "SettingsAboutBody")
        ) {
            VStack(spacing: 14) {
                aboutHeader
                aboutLinks
                aboutSupportCallout
                aboutActions
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var aboutHeader: some View {
        VStack(spacing: 8) {
            (applicationIconImage() ?? Image(systemName: "app"))
                .resizable()
                .scaledToFit()
                .frame(width: 80, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: Color.black.opacity(0.22), radius: 8, x: 0, y: 4)

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
        VStack(spacing: 0) {
            aboutLinkRow(
                icon: "link",
                title: String(localized: "SettingsAboutWebsiteButton"),
                urlString: "https://feuerbacher.me/projects/launchy"
            )
            Divider().overlay(Color.white.opacity(0.08))
            aboutLinkRow(
                icon: "sparkle.magnifyingglass",
                title: String(localized: "SettingsAboutReportIssueButton"),
                urlString: "https://github.com/Punshnut/macos-launchy/issues"
            )
            Divider().overlay(Color.white.opacity(0.08))
            aboutLinkRow(
                icon: "envelope",
                title: String(localized: "SettingsAboutSupportEmailButton"),
                urlString: "https://github.com/Punshnut/macos-launchy"
            )
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 0.8)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    /// Builds a consistent clickable link row for the About section.
    private func aboutLinkRow(icon: String, title: String, urlString: String) -> some View {
        if let url = URL(string: urlString) {
            Link(destination: url) {
                HStack(spacing: 12) {
                    Image(systemName: icon)
                        .frame(width: 18)
                        .foregroundColor(.secondary)
                    Text(title)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .imageScale(.small)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 11)
                .padding(.horizontal, 14)
            }
            .buttonStyle(.plain)
        }
    }

    private var aboutActions: some View {
        HStack(spacing: 10) {
            Button {
                openIntroduction()
            } label: {
                Label(String(localized: "SettingsAboutRevisitIntroButton"), systemImage: "sparkles")
            }
            .buttonStyle(.bordered)

            Button {
                if let url = URL(string: "https://github.com/Punshnut/macos-launchy") {
                    SettingsWindowAppKitBridge.openURL(url)
                }
            } label: {
                Label(String(localized: "SettingsAboutGitHubButton"), systemImage: "chevron.right.circle")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var aboutSupportCallout: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "heart.fill")
                    .foregroundColor(Color(red: 1.0, green: 0.38, blue: 0.38))
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.white.opacity(0.12))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "SettingsAboutSupportTitle"))
                        .font(.headline)
                    Text(String(localized: "SettingsAboutSupportBody"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Button {
                if let url = URL(string: "https://ko-fi.com/janfeuerbacher") {
                    SettingsWindowAppKitBridge.openURL(url)
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "cup.and.saucer.fill")
                        .imageScale(.medium)
                    Text(String(localized: "SettingsAboutDonateButton"))
                        .fontWeight(.semibold)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .imageScale(.small)
                        .foregroundColor(.white.opacity(0.85))
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                .foregroundColor(.white)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.16, green: 0.56, blue: 1.0),
                                    Color(red: 0.48, green: 0.24, blue: 0.9)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .shadow(color: Color.black.opacity(0.25), radius: 10, x: 0, y: 6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.white.opacity(0.22), lineWidth: 1)
                        )
                )
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.08),
                            Color.white.opacity(0.02)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 0.8)
                )
        )
    }

    // MARK: - Shared Helpers

    private var panelDivider: some View {
        Divider()
            .overlay(Color.white.opacity(0.08))
    }

    private func settingsPanel<Content: View>(
        icon: String,
        title: String,
        subtitle: String? = nil,
        customIcon: (() -> AnyView)? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
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
        .padding(12)
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

    /// Displays app icon artwork in lists with a symbol fallback.
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

    /// Shared translucent card background for list-style settings panes.
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

    /// Requests tab-specific window sizing through the AppKit bridge.
    private func resizeWindow(for tab: SettingsTab, animated: Bool) {
        SettingsWindowHostManager.resize(window: hostingWindow, for: tab, animated: animated)
    }

    private var borderStrokeColor: Color {
        Color.white.opacity(0.12)
    }

    /// Delegates close/minimize/zoom actions to the host window helper.
    private func performWindowAction(for kind: WindowControlKind) {
        SettingsWindowHostManager.performWindowAction(kind, on: hostingWindow)
    }

    private var topChromeHeight: CGFloat {
        36
    }

    private var topChromeControlInset: CGFloat {
        7
    }

    /// Reads bundle display name with a safe fallback for previews/tests.
    private func appDisplayName() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Launchy"
    }

    /// Formats version/build metadata for the About tab.
    private func versionSummary() -> String {
        let rawVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "--"
        return String(format: String(localized: "SettingsAboutVersionFormat"), rawVersion)
    }

    /// Resolves developer attribution text for About.
    private func developerSummary() -> String {
        if let copyright = Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String {
            return copyright
        }
        return String(localized: "SettingsAboutBuiltByLabel")
    }

    /// Retrieves the app icon through AppKit bridge helpers.
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
                        Button(String(localized: "SettingsShortcutResetButton")) {
                            cancelToken += 1
                            onReset()
                        }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                    }

                    Button(String(localized: "SettingsShortcutClearButton")) {
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
        .padding(10)
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

    var symbolName: String {
        switch self {
        case .close:    return "xmark"
        case .minimize: return "minus"
        case .zoom:     return ""
        }
    }
}

/// Self-contained tab button whose hover state is local, preventing full-view re-renders.
private struct TabButtonView: View {
    let tab: SettingsTab
    let isSelected: Bool
    let namespace: Namespace.ID
    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: tab.iconName)
                    .font(.system(size: 15, weight: .semibold))
                Text(tab.title)
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundColor(
                isSelected ? Color.accentColor : Color.primary.opacity(isHovered ? 0.92 : 0.68)
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                ZStack {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.accentColor.opacity(0.28))
                            .matchedGeometryEffect(id: "tabSelection", in: namespace)
                            .shadow(color: Color.accentColor.opacity(0.25), radius: 5, y: 2)
                    } else if isHovered {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.primary.opacity(0.10))
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(
                        isSelected ? Color.accentColor.opacity(0.50) : Color.clear,
                        lineWidth: 1.5
                    )
            )
        }
        .buttonStyle(TabPressStyle())
        .onHover { hovering in
            withAnimation(.spring(response: 0.18, dampingFraction: 0.80)) {
                isHovered = hovering
            }
        }
        .accessibilityLabel(Text(tab.title))
    }
}

/// Flat press style: scales down slightly and dims — no shadows.
private struct TabPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1.0)
            .opacity(configuration.isPressed ? 0.75 : 1.0)
            .animation(.spring(response: 0.15, dampingFraction: 0.72), value: configuration.isPressed)
    }
}

private struct ZoomHoverIcon: View {
    var body: some View {
        Canvas { ctx, size in
            let t: CGFloat = 3.5
            var ul = Path()
            ul.move(to: .init(x: 0, y: t))
            ul.addLine(to: .init(x: 0, y: 0))
            ul.addLine(to: .init(x: t, y: 0))
            ul.closeSubpath()
            var lr = Path()
            lr.move(to: .init(x: size.width - t, y: size.height))
            lr.addLine(to: .init(x: size.width, y: size.height))
            lr.addLine(to: .init(x: size.width, y: size.height - t))
            lr.closeSubpath()
            let shade = GraphicsContext.Shading.color(Color.black.opacity(0.45))
            ctx.fill(ul, with: shade)
            ctx.fill(lr, with: shade)
        }
        .frame(width: 6, height: 6)
    }
}

struct WindowControlDot: View {
    let kind: WindowControlKind
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(kind.color)
                .frame(width: 14, height: 14)
                .overlay {
                    if isHovering {
                        if kind == .zoom {
                            ZoomHoverIcon()
                        } else {
                            Image(systemName: kind.symbolName)
                                .font(.system(size: 7, weight: .semibold))
                                .foregroundColor(Color.black.opacity(0.65))
                        }
                    }
                }
                .overlay(
                    Circle().stroke(Color.black.opacity(0.12), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Scroll Background Helper

struct GlassListScrollBackground: ViewModifier {
    /// Wraps tab content in shared panel spacing and transition defaults.
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
    /// Applies platform-correct translucent background for scrolling list sections.
    func glassListScrollBackground() -> some View {
        modifier(GlassListScrollBackground())
    }
}
