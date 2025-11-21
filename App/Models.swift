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
    static let defaultName = "unnamed"

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
    case fullscreenOldMac
    case floaty

    /// User-facing description shown in pickers.
    var displayName: String {
        switch self {
        case .fullscreenOldMac:
            return "Fullscreen"
        case .floaty:
            return "Floaty Panel"
        }
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
            case .system: return "System"
            case .graphite: return "Graphite"
            case .blue: return "Blue"
            case .green: return "Green"
            case .orange: return "Orange"
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
                return "Standard"
            case .light:
                return "Light Blur"
            case .transparent:
                return "Transparent"
            case .solid:
                return "Solid Color"
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
    /// Determines whether Launchy should keep a Dock icon around while in floaty mode.
    var isFloatyDockIconVisible: Bool
    /// Placeholder text describing the user’s preferred hotkey.
    var globalHotkeyDescription: String
    /// Whether the grid should collapse gaps by pulling items forward.
    var fillsGapsAutomatically: Bool

    init(
        isVisibleOnAllSpaces: Bool,
        launchesAtLogin: Bool,
        hiddenBundleIDs: [String],
        backgroundStylePreference: PreferredBackgroundStyle,
        solidBackgroundColor: SolidBackgroundColor,
        selectedLauncherMode: LauncherMode,
        isMenuBarIconVisible: Bool,
        isFloatyDockIconVisible: Bool,
        globalHotkeyDescription: String,
        fillsGapsAutomatically: Bool
    ) {
        self.isVisibleOnAllSpaces = isVisibleOnAllSpaces
        self.launchesAtLogin = launchesAtLogin
        self.hiddenBundleIDs = hiddenBundleIDs
        self.backgroundStylePreference = backgroundStylePreference
        self.solidBackgroundColor = solidBackgroundColor
        self.selectedLauncherMode = selectedLauncherMode
        self.isMenuBarIconVisible = isMenuBarIconVisible
        self.isFloatyDockIconVisible = isFloatyDockIconVisible
        self.globalHotkeyDescription = globalHotkeyDescription
        self.fillsGapsAutomatically = fillsGapsAutomatically
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
            selectedLauncherMode: .fullscreenOldMac,
            isMenuBarIconVisible: true,
            isFloatyDockIconVisible: true,
            globalHotkeyDescription: "Cmd+Shift+Space",
            fillsGapsAutomatically: false
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
        case isFloatyDockIconVisible = "isDockIconVisible"
        case globalHotkeyDescription
        case fillsGapsAutomatically
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            isVisibleOnAllSpaces: try container.decodeIfPresent(Bool.self, forKey: .isVisibleOnAllSpaces) ?? false,
            launchesAtLogin: try container.decodeIfPresent(Bool.self, forKey: .launchesAtLogin) ?? false,
            hiddenBundleIDs: try container.decodeIfPresent([String].self, forKey: .hiddenBundleIDs) ?? [],
            backgroundStylePreference: PreferredBackgroundStyle.from(
                rawValue: try container.decodeIfPresent(String.self, forKey: .backgroundStylePreference)
            ),
            solidBackgroundColor: try container.decodeIfPresent(SolidBackgroundColor.self, forKey: .solidBackgroundColor) ?? .system,
            selectedLauncherMode: try container.decodeIfPresent(LauncherMode.self, forKey: .selectedLauncherMode) ?? .fullscreenOldMac,
            isMenuBarIconVisible: try container.decodeIfPresent(Bool.self, forKey: .isMenuBarIconVisible) ?? true,
            isFloatyDockIconVisible: try container.decodeIfPresent(Bool.self, forKey: .isFloatyDockIconVisible) ?? true,
            globalHotkeyDescription: try container.decodeIfPresent(String.self, forKey: .globalHotkeyDescription) ?? "Cmd+Shift+Space",
            fillsGapsAutomatically: try container.decodeIfPresent(Bool.self, forKey: .fillsGapsAutomatically) ?? false
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
        try container.encode(isFloatyDockIconVisible, forKey: .isFloatyDockIconVisible)
        try container.encode(globalHotkeyDescription, forKey: .globalHotkeyDescription)
        try container.encode(fillsGapsAutomatically, forKey: .fillsGapsAutomatically)
    }
}
