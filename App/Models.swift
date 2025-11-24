import Foundation
import AppKit

/// Represents an application bundle that Launchy can surface and start.
struct AppItem: Identifiable, Hashable {
    /// Stable identifier backed by a `UUID` so SwiftUI lists animate cleanly.
    let id: UUID
    /// Human-friendly app name shown in the launcher grid.
    let displayName: String
    /// Optional custom label supplied by the user.
    var customName: String?
    /// Bundle identifier used both for hiding apps and launching them.
    let bundleIdentifier: String
    /// Lazily-discovered icon cached on disk or nil if missing.
    let iconImage: NSImage?
    /// File URL pointing at the actual `.app` bundle.
    let bundleURL: URL?

    init(
        id: UUID,
        displayName: String,
        customName: String? = nil,
        bundleIdentifier: String,
        iconImage: NSImage?,
        bundleURL: URL?
    ) {
        self.id = id
        self.displayName = displayName
        self.customName = customName
        self.bundleIdentifier = bundleIdentifier
        self.iconImage = iconImage
        self.bundleURL = bundleURL
    }

    static func == (lhs: AppItem, rhs: AppItem) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    /// Returns the best display name, preferring the override if present.
    var resolvedDisplayName: String {
        let trimmed = customName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? displayName : trimmed
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

/// User-configurable settings for how the launcher behaves.
struct LauncherSettings: Hashable, Codable {
    /// Available solid background colors when the solid style is chosen.
    enum SolidBackgroundColor: String, CaseIterable, Hashable, Codable {
        case system
        case graphite
        case blue
        case green
        case orange

        /// User-facing label.
        var displayName: String {
            switch self {
            case .system: return String(localized: "System")
            case .graphite: return String(localized: "Graphite")
            case .blue: return String(localized: "Blue")
            case .green: return String(localized: "Green")
            case .orange: return String(localized: "Orange")
            }
        }

        /// Native NSColor that matches the selected swatch.
        var nsColor: NSColor {
            switch self {
            case .system:
                return .windowBackgroundColor
            case .graphite:
                return NSColor(calibratedWhite: 0.16, alpha: 1.0)
            case .blue:
                return NSColor(calibratedRed: 0.12, green: 0.26, blue: 0.54, alpha: 1.0)
            case .green:
                return NSColor(calibratedRed: 0.13, green: 0.42, blue: 0.24, alpha: 1.0)
            case .orange:
                return NSColor(calibratedRed: 0.72, green: 0.39, blue: 0.07, alpha: 1.0)
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
    /// Whether the grid should collapse gaps by pulling items forward.
    var fillsGapsAutomatically: Bool
    /// Whether the user has already gone through the Launchy introduction.
    var hasCompletedIntroduction: Bool
    init(
        isVisibleOnAllSpaces: Bool,
        launchesAtLogin: Bool,
        hiddenBundleIDs: [String],
        backgroundStylePreference: PreferredBackgroundStyle,
        solidBackgroundColor: SolidBackgroundColor,
        selectedLauncherMode: LauncherMode,
        isMenuBarIconVisible: Bool,
        isDockIconVisible: Bool,
        launcherHotkey: HotkeyDescriptor?,
        layoutToggleHotkey: HotkeyDescriptor?,
        fillsGapsAutomatically: Bool,
        hasCompletedIntroduction: Bool
    ) {
        self.isVisibleOnAllSpaces = isVisibleOnAllSpaces
        self.launchesAtLogin = launchesAtLogin
        self.hiddenBundleIDs = hiddenBundleIDs
        self.backgroundStylePreference = backgroundStylePreference
        self.solidBackgroundColor = solidBackgroundColor
        self.selectedLauncherMode = selectedLauncherMode
        self.isMenuBarIconVisible = isMenuBarIconVisible
        self.isDockIconVisible = isDockIconVisible
        self.launcherHotkey = launcherHotkey
        self.layoutToggleHotkey = layoutToggleHotkey
        self.fillsGapsAutomatically = fillsGapsAutomatically
        self.hasCompletedIntroduction = hasCompletedIntroduction
    }
}

extension LauncherSettings {
    /// Provides a baseline set of settings used when nothing has been persisted yet.
    static var defaults: LauncherSettings {
        LauncherSettings(
            isVisibleOnAllSpaces: false,
            launchesAtLogin: false,
            hiddenBundleIDs: [],
            backgroundStylePreference: .standard,
            solidBackgroundColor: .system,
            selectedLauncherMode: .fullscreen,
            isMenuBarIconVisible: true,
            isDockIconVisible: true,
            launcherHotkey: .toggleLauncher,
            layoutToggleHotkey: nil,
            fillsGapsAutomatically: false,
            hasCompletedIntroduction: false
        )
    }
}

extension LauncherSettings {
    private enum CodingKeys: String, CodingKey {
        case isVisibleOnAllSpaces
        case launchesAtLogin
        case hiddenBundleIDs
        case backgroundStylePreference
        case solidBackgroundColor
        case selectedLauncherMode
        case isMenuBarIconVisible
        case isDockIconVisible
        case launcherHotkey
        case layoutToggleHotkey
        case fillsGapsAutomatically
        case hasCompletedIntroduction
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
            backgroundStylePreference: PreferredBackgroundStyle.from(
                rawValue: try container.decodeIfPresent(String.self, forKey: .backgroundStylePreference)
            ),
            solidBackgroundColor: try container.decodeIfPresent(SolidBackgroundColor.self, forKey: .solidBackgroundColor) ?? .system,
            selectedLauncherMode: try container.decodeIfPresent(LauncherMode.self, forKey: .selectedLauncherMode) ?? .fullscreen,
            isMenuBarIconVisible: try container.decodeIfPresent(Bool.self, forKey: .isMenuBarIconVisible) ?? true,
            isDockIconVisible: try container.decodeIfPresent(Bool.self, forKey: .isDockIconVisible) ?? true,
            launcherHotkey: decodedLauncherHotkey,
            layoutToggleHotkey: try container.decodeIfPresent(HotkeyDescriptor.self, forKey: .layoutToggleHotkey),
            fillsGapsAutomatically: try container.decodeIfPresent(Bool.self, forKey: .fillsGapsAutomatically) ?? false,
            hasCompletedIntroduction: try container.decodeIfPresent(Bool.self, forKey: .hasCompletedIntroduction) ?? false
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isVisibleOnAllSpaces, forKey: .isVisibleOnAllSpaces)
        try container.encode(launchesAtLogin, forKey: .launchesAtLogin)
        try container.encode(hiddenBundleIDs, forKey: .hiddenBundleIDs)
        try container.encode(backgroundStylePreference, forKey: .backgroundStylePreference)
        try container.encode(solidBackgroundColor, forKey: .solidBackgroundColor)
        try container.encode(selectedLauncherMode, forKey: .selectedLauncherMode)
        try container.encode(isMenuBarIconVisible, forKey: .isMenuBarIconVisible)
        try container.encode(isDockIconVisible, forKey: .isDockIconVisible)
        try container.encode(launcherHotkey, forKey: .launcherHotkey)
        try container.encode(layoutToggleHotkey, forKey: .layoutToggleHotkey)
        try container.encode(fillsGapsAutomatically, forKey: .fillsGapsAutomatically)
        try container.encode(hasCompletedIntroduction, forKey: .hasCompletedIntroduction)
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
