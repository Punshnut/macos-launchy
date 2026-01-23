import Foundation
import AppKit

/// Identifiers used for special entries that don’t correspond to individual apps.
/// IDs used to represent auto-generated folders (core services and tools) in settings and persistence.
enum HiddenSpecialEntryIdentifiers {
    static let coreServicesFolder = "launchy.hidden.core-services-folder"
    static let systemToolsFolder = "launchy.hidden.system-tools-folder"
}

/// Represents an application bundle that Launchy can surface and start.
struct AppItem: Identifiable, Hashable {
    /// Stable identifier backed by a `UUID` so SwiftUI lists animate cleanly.
    let id: UUID
    /// Human-friendly app name shown in the launcher grid.
    let displayName: String
    /// Localized app name resolved using the system language, if available.
    let localizedDisplayName: String?
    /// Optional custom label supplied by the user.
    var customName: String?
    /// Bundle identifier used both for hiding apps and launching them.
    let bundleIdentifier: String
    /// Lazily-discovered icon cached on disk or nil if missing.
    let iconImage: NSImage?
    /// File URL pointing at the actual `.app` bundle.
    let bundleURL: URL?
    /// Whether the bundle originates from the user-owned `~/Applications` folder.
    let isUserApplication: Bool
    /// Marks items discovered under `/System/Library/CoreServices`.
    let isCoreServiceApplication: Bool
    /// Tracks whether a non-placeholder icon was available.
    let hasCustomIcon: Bool

    init(
        id: UUID,
        displayName: String,
        localizedDisplayName: String? = nil,
        customName: String? = nil,
        bundleIdentifier: String,
        iconImage: NSImage?,
        bundleURL: URL?,
        isUserApplication: Bool = false,
        isCoreServiceApplication: Bool = false,
        hasCustomIcon: Bool = true
    ) {
        self.id = id
        self.displayName = displayName
        self.localizedDisplayName = localizedDisplayName
        self.customName = customName
        self.bundleIdentifier = bundleIdentifier
        self.iconImage = iconImage
        self.bundleURL = bundleURL
        self.isUserApplication = isUserApplication
        self.isCoreServiceApplication = isCoreServiceApplication
        self.hasCustomIcon = hasCustomIcon
    }

    static func == (lhs: AppItem, rhs: AppItem) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    /// Returns the best display name, preferring the override if present.
    var resolvedDisplayName: String {
        if let trimmedCustom = normalizedCustomName {
            return trimmedCustom
        }

        if let localized = normalizedLocalizedDisplayName {
            return localized
        }

        return normalizedDisplayName
    }

    /// All candidate names used for search and filtering without duplicates.
    var searchableNames: [String] {
        let candidates = [
            normalizedCustomName,
            normalizedLocalizedDisplayName,
            normalizedDisplayName
        ]

        return candidates
            .compactMap { $0 }
            .reduce(into: [String]()) { unique, name in
                let alreadyAdded = unique.contains { existing in
                    existing.compare(name, options: .caseInsensitive) == .orderedSame
                }
                if alreadyAdded == false {
                    unique.append(name)
                }
            }
    }

    /// Primary name used when sorting lists for display.
    var sortingName: String {
        normalizedLocalizedDisplayName ?? normalizedDisplayName
    }

    /// Checks if the item matches the provided search query across names and bundle ID.
    func matches(query: String) -> Bool {
        let normalizedQuery = normalizedSearchValue(query)
        guard normalizedQuery.isEmpty == false else { return true }
        return searchableNames.contains { normalizedSearchValue($0).contains(normalizedQuery) }
            || normalizedSearchValue(bundleIdentifier).contains(normalizedQuery)
    }

    private var normalizedCustomName: String? {
        let trimmed = customName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private var normalizedLocalizedDisplayName: String? {
        guard let localizedDisplayName else { return nil }
        let trimmed = localizedDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Trims the base display name while keeping the original when empty.
    private var normalizedDisplayName: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? displayName : trimmed
    }

    private func normalizedSearchValue(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
    }
}

/// Represents anything the launcher can display such as apps or folders.
enum LauncherItem: Identifiable, Hashable {
    case app(AppItem)
    case folder(FolderItem)

    var id: UUID {
        switch self {
        case .app(let app):
            return app.id
        case .folder(let folder):
            return folder.id
        }
    }

    /// Title used in the grid and search for both apps and folders.
    var displayName: String {
        switch self {
        case .app(let app):
            return app.resolvedDisplayName
        case .folder(let folder):
            return folder.name
        }
    }

    /// Bundle identifiers contained within the item, useful for persistence.
    var bundleIdentifiers: [String] {
        switch self {
        case .app(let app):
            return [app.bundleIdentifier]
        case .folder(let folder):
            return folder.apps.map(\.bundleIdentifier)
        }
    }

    static func == (lhs: LauncherItem, rhs: LauncherItem) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// Simple grouping of multiple apps into a single launcher cell.
struct FolderItem: Identifiable, Hashable {
    static var defaultName: String {
        String(localized: "unnamed")
    }

    let id: UUID
    var name: String
    var apps: [AppItem]

    init(id: UUID = UUID(), name: String = FolderItem.defaultName, apps: [AppItem]) {
        self.id = id
        self.name = name
        self.apps = apps
    }
}

/// Determines the overall presentation style of the launcher UI.
enum LauncherMode: String, CaseIterable, Hashable, Codable {
    case fullscreen
    case floaty

    private static let legacyFullscreenRawValue = "fullscreenOldMac"

    /// User-facing description shown in pickers.
    var displayName: String {
        switch self {
        case .fullscreen:
            return String(localized: "Fullscreen")
        case .floaty:
            return String(localized: "Floaty Panel")
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try? container.decode(String.self)
        self = LauncherMode.map(from: rawValue)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private static func map(from rawValue: String?) -> LauncherMode {
        if rawValue == legacyFullscreenRawValue {
            return .fullscreen
        }

        if let rawValue, let mode = LauncherMode(rawValue: rawValue) {
            return mode
        }

        return .fullscreen
    }
}

/// Identifies which hot corner should trigger Launchy when enabled.
enum HotCornerPosition: String, CaseIterable, Hashable, Codable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    var displayName: String {
        switch self {
        case .topLeft:
            return String(localized: "Top Left")
        case .topRight:
            return String(localized: "Top Right")
        case .bottomLeft:
            return String(localized: "Bottom Left")
        case .bottomRight:
            return String(localized: "Bottom Right")
        }
    }
}

/// User-facing grid density for the launcher icons.
enum IconSizePreference: String, CaseIterable, Hashable, Codable {
    case small
    case medium
    case large

    var displayName: String {
        switch self {
        case .small:
            return String(localized: "Small (Original)")
        case .medium:
            return String(localized: "Medium")
        case .large:
            return String(localized: "Large")
        }
    }

    var sliderPosition: Double {
        switch self {
        case .small: return 0
        case .medium: return 1
        case .large: return 2
        }
    }

    static func fromSliderPosition(_ value: Double) -> IconSizePreference {
        switch Int(value.rounded()) {
        case 0: return .small
        case 2: return .large
        default: return .medium
        }
    }

    /// Returns a size that can be safely applied to the provided launcher mode.
    func effectivePreference(for mode: LauncherMode) -> IconSizePreference {
        if mode == .floaty, self == .large {
            return .medium
        }
        return self
    }
}

/// Configures whether paging moves horizontally or vertically.
enum PagingOrientation: String, CaseIterable, Hashable, Codable {
    case horizontal
    case vertical

    var displayName: String {
        switch self {
        case .horizontal:
            return String(localized: "Horizontal")
        case .vertical:
            return String(localized: "Vertical")
        }
    }
}

/// Sorting strategy applied when rebuilding the grid from scratch.
enum ArrangementResetSorting: String, CaseIterable, Hashable, Codable {
    case alphabetical
    case discovery

    /// User-facing label for settings UI.
    var displayName: String {
        switch self {
        case .alphabetical:
            return String(localized: "Alphabetical")
        case .discovery:
            return String(localized: "Discovery order")
        }
    }

    /// Short description shown in confirmation dialogs.
    var summary: String {
        switch self {
        case .alphabetical:
            return String(localized: "A → Z by app name")
        case .discovery:
            return String(localized: "As Launchy finds them")
        }
    }
}

/// User-configurable settings for how the launcher behaves.
struct LauncherSettings: Hashable, Codable {
    /// Available solid background colors when the solid style is chosen.
    enum SolidBackgroundColor: String, CaseIterable, Hashable, Codable {
        case system
        case graphite
        case indigo
        case blue
        case cyan
        case teal
        case green
        case mint
        case yellow
        case orange
        case pink
        case purple

        /// User-facing label.
        var displayName: String {
            switch self {
            case .system: return String(localized: "System")
            case .graphite: return String(localized: "Graphite")
            case .indigo: return String(localized: "Indigo")
            case .blue: return String(localized: "Blue")
            case .cyan: return String(localized: "Cyan")
            case .teal: return String(localized: "Teal")
            case .green: return String(localized: "Green")
            case .mint: return String(localized: "Mint")
            case .yellow: return String(localized: "Yellow")
            case .orange: return String(localized: "Orange")
            case .purple: return String(localized: "Purple")
            case .pink: return String(localized: "Pink")
            }
        }

        /// Native NSColor that matches the selected swatch.
        var nsColor: NSColor {
            switch self {
            case .system:
                return .windowBackgroundColor
            case .graphite:
                return NSColor(calibratedRed: 0.12, green: 0.13, blue: 0.15, alpha: 1.0)
            case .indigo:
                return NSColor(calibratedRed: 0.36, green: 0.38, blue: 0.82, alpha: 1.0)
            case .blue:
                return NSColor(calibratedRed: 0.16, green: 0.38, blue: 0.93, alpha: 1.0)
            case .cyan:
                return NSColor(calibratedRed: 0.16, green: 0.68, blue: 0.86, alpha: 1.0)
            case .teal:
                return NSColor(calibratedRed: 0.04, green: 0.62, blue: 0.60, alpha: 1.0)
            case .green:
                return NSColor(calibratedRed: 0.10, green: 0.55, blue: 0.46, alpha: 1.0)
            case .mint:
                return NSColor(calibratedRed: 0.52, green: 0.82, blue: 0.60, alpha: 1.0)
            case .yellow:
                return NSColor(calibratedRed: 0.98, green: 0.82, blue: 0.32, alpha: 1.0)
            case .orange:
                return NSColor(calibratedRed: 0.90, green: 0.42, blue: 0.17, alpha: 1.0)
            case .purple:
                return NSColor(calibratedRed: 0.52, green: 0.38, blue: 0.89, alpha: 1.0)
            case .pink:
                return NSColor(calibratedRed: 0.94, green: 0.36, blue: 0.62, alpha: 1.0)
            }
        }
    }

    /// How the window draws its background behind the grid.
    enum PreferredBackgroundStyle: String, CaseIterable, Hashable, Codable {
        case standard
        case light
        case transparent
        case solid

        /// Converts internal cases into nicer labels for use in pickers.
        var displayName: String {
            switch self {
            case .standard:
                return String(localized: "Standard")
            case .light:
                return String(localized: "Light Blur")
            case .transparent:
                return String(localized: "Transparent")
            case .solid:
                return String(localized: "Solid Color")
            }
        }

        /// Safely resolves raw values, mapping legacy persisted cases to current ones.
        static func from(rawValue: String?) -> PreferredBackgroundStyle {
            guard let rawValue else { return .standard }
            if let style = PreferredBackgroundStyle(rawValue: rawValue) {
                return style
            }
            // Older builds saved "automatic", which now maps to "standard".
            if rawValue == "automatic" {
                return .standard
            }
            return .standard
        }
    }

    /// Whether the panel should be visible across every macOS Space.
    var isVisibleOnAllSpaces: Bool
    /// Indicates if Launchy should start automatically when the user signs in.
    var launchesAtLogin: Bool
    /// Bundle identifiers that should be hidden from the grid UI.
    var hiddenBundleIDs: [String]
    /// Special hidden entries like auto-created folders.
    var hiddenSpecialEntryIDs: [String]
    /// When enabled, keeps hidden apps pinned to the top of the hidden Apps list.
    var showHiddenAppsFirst: Bool
    /// Selected background styling preference for the launcher UI.
    var backgroundStylePreference: PreferredBackgroundStyle
    /// Solid color selected when the solid background is active.
    var solidBackgroundColor: SolidBackgroundColor
    /// Which presentation mode (panel vs fullscreen) is active.
    var selectedLauncherMode: LauncherMode
    /// Toggles the presence of the menu bar shortcut icon.
    var isMenuBarIconVisible: Bool
    /// Determines whether Launchy should keep a Dock icon around while the app is running.
    var isDockIconVisible: Bool
    /// Global hotkey used to show or hide Launchy.
    var launcherHotkey: HotkeyDescriptor?
    /// Optional shortcut for toggling between floaty and fullscreen layouts.
    var layoutToggleHotkey: HotkeyDescriptor?
    /// Whether a hot corner is configured to toggle Launchy.
    var hotCornerEnabled: Bool
    /// Corner that toggles Launchy when hot corner support is enabled.
    var hotCornerPosition: HotCornerPosition
    /// Whether the grid should collapse gaps by pulling items forward.
    var fillsGapsAutomatically: Bool
    /// Whether the user has already gone through the Launchy introduction.
    var hasCompletedIntroduction: Bool
    /// When enabled, Launchy also indexes `~/Applications`.
    var shouldScanUserApplicationsFolder: Bool
    /// Preferred icon sizing for the launcher grid.
    var iconSizePreference: IconSizePreference
    /// Whether launcher paging should move horizontally or vertically.
    var pagingOrientation: PagingOrientation
    init(
        isVisibleOnAllSpaces: Bool,
        launchesAtLogin: Bool,
        hiddenBundleIDs: [String],
        hiddenSpecialEntryIDs: [String],
        showHiddenAppsFirst: Bool,
        backgroundStylePreference: PreferredBackgroundStyle,
        solidBackgroundColor: SolidBackgroundColor,
        selectedLauncherMode: LauncherMode,
        isMenuBarIconVisible: Bool,
        isDockIconVisible: Bool,
        launcherHotkey: HotkeyDescriptor?,
        layoutToggleHotkey: HotkeyDescriptor?,
        hotCornerEnabled: Bool,
        hotCornerPosition: HotCornerPosition,
        fillsGapsAutomatically: Bool,
        hasCompletedIntroduction: Bool,
        shouldScanUserApplicationsFolder: Bool,
        iconSizePreference: IconSizePreference,
        pagingOrientation: PagingOrientation
    ) {
        self.isVisibleOnAllSpaces = isVisibleOnAllSpaces
        self.launchesAtLogin = launchesAtLogin
        self.hiddenBundleIDs = hiddenBundleIDs
        self.hiddenSpecialEntryIDs = hiddenSpecialEntryIDs
        self.showHiddenAppsFirst = showHiddenAppsFirst
        self.backgroundStylePreference = backgroundStylePreference
        self.solidBackgroundColor = solidBackgroundColor
        self.selectedLauncherMode = selectedLauncherMode
        self.isMenuBarIconVisible = isMenuBarIconVisible
        self.isDockIconVisible = isDockIconVisible
        self.launcherHotkey = launcherHotkey
        self.layoutToggleHotkey = layoutToggleHotkey
        self.hotCornerEnabled = hotCornerEnabled
        self.hotCornerPosition = hotCornerPosition
        self.fillsGapsAutomatically = fillsGapsAutomatically
        self.hasCompletedIntroduction = hasCompletedIntroduction
        self.shouldScanUserApplicationsFolder = shouldScanUserApplicationsFolder
        self.iconSizePreference = iconSizePreference
        self.pagingOrientation = pagingOrientation
    }
}

extension LauncherSettings {
    /// Provides a baseline set of settings used when nothing has been persisted yet.
    static var defaults: LauncherSettings {
        LauncherSettings(
            isVisibleOnAllSpaces: false,
            launchesAtLogin: false,
            hiddenBundleIDs: [],
            hiddenSpecialEntryIDs: [HiddenSpecialEntryIdentifiers.systemToolsFolder],
            showHiddenAppsFirst: false,
            backgroundStylePreference: .standard,
            solidBackgroundColor: .system,
            selectedLauncherMode: .fullscreen,
            isMenuBarIconVisible: true,
            isDockIconVisible: true,
            launcherHotkey: .toggleLauncher,
            layoutToggleHotkey: nil,
            hotCornerEnabled: false,
            hotCornerPosition: .bottomRight,
            fillsGapsAutomatically: false,
            hasCompletedIntroduction: false,
            shouldScanUserApplicationsFolder: true,
            iconSizePreference: .small,
            pagingOrientation: .horizontal
        )
    }
}

extension LauncherSettings {
    private enum CodingKeys: String, CodingKey {
        case isVisibleOnAllSpaces
        case launchesAtLogin
        case hiddenBundleIDs
        case hiddenSpecialEntryIDs
        case showHiddenAppsFirst
        case backgroundStylePreference
        case solidBackgroundColor
        case selectedLauncherMode
        case isMenuBarIconVisible
        case isDockIconVisible
        case launcherHotkey
        case layoutToggleHotkey
        case hotCornerEnabled
        case hotCornerPosition
        case fillsGapsAutomatically
        case hasCompletedIntroduction
        case shouldScanUserApplicationsFolder
        case iconSizePreference
        case pagingOrientation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedLauncherHotkey: HotkeyDescriptor?
        if container.contains(.launcherHotkey) {
            decodedLauncherHotkey = try container.decodeIfPresent(HotkeyDescriptor.self, forKey: .launcherHotkey)
        } else {
            decodedLauncherHotkey = .toggleLauncher
        }

        self.init(
            isVisibleOnAllSpaces: try container.decodeIfPresent(Bool.self, forKey: .isVisibleOnAllSpaces) ?? false,
            launchesAtLogin: try container.decodeIfPresent(Bool.self, forKey: .launchesAtLogin) ?? false,
            hiddenBundleIDs: try container.decodeIfPresent([String].self, forKey: .hiddenBundleIDs) ?? [],
            hiddenSpecialEntryIDs: try container.decodeIfPresent([String].self, forKey: .hiddenSpecialEntryIDs) ?? [],
            showHiddenAppsFirst: try container.decodeIfPresent(Bool.self, forKey: .showHiddenAppsFirst) ?? false,
            backgroundStylePreference: PreferredBackgroundStyle.from(
                rawValue: try container.decodeIfPresent(String.self, forKey: .backgroundStylePreference)
            ),
            solidBackgroundColor: try container.decodeIfPresent(SolidBackgroundColor.self, forKey: .solidBackgroundColor) ?? .system,
            selectedLauncherMode: try container.decodeIfPresent(LauncherMode.self, forKey: .selectedLauncherMode) ?? .fullscreen,
            isMenuBarIconVisible: try container.decodeIfPresent(Bool.self, forKey: .isMenuBarIconVisible) ?? true,
            isDockIconVisible: try container.decodeIfPresent(Bool.self, forKey: .isDockIconVisible) ?? true,
            launcherHotkey: decodedLauncherHotkey,
            layoutToggleHotkey: try container.decodeIfPresent(HotkeyDescriptor.self, forKey: .layoutToggleHotkey),
            hotCornerEnabled: try container.decodeIfPresent(Bool.self, forKey: .hotCornerEnabled) ?? false,
            hotCornerPosition: try container.decodeIfPresent(HotCornerPosition.self, forKey: .hotCornerPosition) ?? .bottomRight,
            fillsGapsAutomatically: try container.decodeIfPresent(Bool.self, forKey: .fillsGapsAutomatically) ?? false,
            hasCompletedIntroduction: try container.decodeIfPresent(Bool.self, forKey: .hasCompletedIntroduction) ?? false,
            shouldScanUserApplicationsFolder: try container.decodeIfPresent(Bool.self, forKey: .shouldScanUserApplicationsFolder) ?? true,
            iconSizePreference: try container.decodeIfPresent(IconSizePreference.self, forKey: .iconSizePreference) ?? .small,
            pagingOrientation: try container.decodeIfPresent(PagingOrientation.self, forKey: .pagingOrientation) ?? .horizontal
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isVisibleOnAllSpaces, forKey: .isVisibleOnAllSpaces)
        try container.encode(launchesAtLogin, forKey: .launchesAtLogin)
        try container.encode(hiddenBundleIDs, forKey: .hiddenBundleIDs)
        try container.encode(showHiddenAppsFirst, forKey: .showHiddenAppsFirst)
        try container.encode(backgroundStylePreference, forKey: .backgroundStylePreference)
        try container.encode(solidBackgroundColor, forKey: .solidBackgroundColor)
        try container.encode(selectedLauncherMode, forKey: .selectedLauncherMode)
        try container.encode(isMenuBarIconVisible, forKey: .isMenuBarIconVisible)
        try container.encode(isDockIconVisible, forKey: .isDockIconVisible)
        try container.encode(launcherHotkey, forKey: .launcherHotkey)
        try container.encode(layoutToggleHotkey, forKey: .layoutToggleHotkey)
        try container.encode(hotCornerEnabled, forKey: .hotCornerEnabled)
        try container.encode(hotCornerPosition, forKey: .hotCornerPosition)
        try container.encode(fillsGapsAutomatically, forKey: .fillsGapsAutomatically)
        try container.encode(hasCompletedIntroduction, forKey: .hasCompletedIntroduction)
        try container.encode(shouldScanUserApplicationsFolder, forKey: .shouldScanUserApplicationsFolder)
        try container.encode(hiddenSpecialEntryIDs, forKey: .hiddenSpecialEntryIDs)
        try container.encode(iconSizePreference, forKey: .iconSizePreference)
        try container.encode(pagingOrientation, forKey: .pagingOrientation)
    }
}

extension LauncherSettings {
    /// Convenience helpers that invert the stored visibility flags.
    var isDockIconHidden: Bool {
        get { isDockIconVisible == false }
        set { isDockIconVisible = !newValue }
    }

    var isMenuBarIconHidden: Bool {
        get { isMenuBarIconVisible == false }
        set { isMenuBarIconVisible = !newValue }
    }
}
