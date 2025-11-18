import Foundation
import AppKit

/// Represents an application bundle that Launchy can surface and start.
struct AppItem: Identifiable, Hashable {
    /// Stable identifier backed by a `UUID` so SwiftUI lists animate cleanly.
    let id: UUID
    /// Human-friendly app name shown in the launcher grid.
    let displayName: String
    /// Bundle identifier used both for hiding apps and launching them.
    let bundleIdentifier: String
    /// Lazily-discovered icon cached on disk or nil if missing.
    let iconImage: NSImage?
    /// File URL pointing at the actual `.app` bundle.
    let bundleURL: URL?
}

/// Determines the overall presentation style of the launcher UI.
enum LauncherMode: String, CaseIterable, Hashable, Codable {
    case floaty
    case fullscreenOldMac

    /// User-facing description shown in pickers.
    var displayName: String {
        switch self {
        case .floaty:
            return "Floaty Panel"
        case .fullscreenOldMac:
            return "Fullscreen"
        }
    }
}

/// User-configurable settings for how the launcher behaves.
struct LauncherSettings: Hashable, Codable {
    /// How the window draws its background behind the grid.
    enum PreferredBackgroundStyle: String, CaseIterable, Hashable, Codable {
        case automatic
        case transparent
        case solid

        /// Converts internal cases into nicer labels for use in pickers.
        var displayName: String {
            switch self {
            case .automatic:
                return "Automatic"
            case .transparent:
                return "Transparent"
            case .solid:
                return "Solid Color"
            }
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
    /// Which presentation mode (panel vs fullscreen) is active.
    var selectedLauncherMode: LauncherMode
    /// Toggles the presence of the menu bar shortcut icon.
    var isMenuBarIconVisible: Bool
    /// Determines whether Launchy should keep a Dock icon around while in floaty mode.
    var isDockIconVisible: Bool
    /// Placeholder text describing the user’s preferred hotkey.
    var globalHotkeyDescription: String

    init(
        isVisibleOnAllSpaces: Bool,
        launchesAtLogin: Bool,
        hiddenBundleIDs: [String],
        backgroundStylePreference: PreferredBackgroundStyle,
        selectedLauncherMode: LauncherMode,
        isMenuBarIconVisible: Bool,
        isDockIconVisible: Bool,
        globalHotkeyDescription: String
    ) {
        self.isVisibleOnAllSpaces = isVisibleOnAllSpaces
        self.launchesAtLogin = launchesAtLogin
        self.hiddenBundleIDs = hiddenBundleIDs
        self.backgroundStylePreference = backgroundStylePreference
        self.selectedLauncherMode = selectedLauncherMode
        self.isMenuBarIconVisible = isMenuBarIconVisible
        self.isDockIconVisible = isDockIconVisible
        self.globalHotkeyDescription = globalHotkeyDescription
    }
}

extension LauncherSettings {
    /// Provides a baseline set of settings used when nothing has been persisted yet.
    static var defaults: LauncherSettings {
        LauncherSettings(
            isVisibleOnAllSpaces: false,
            launchesAtLogin: false,
            hiddenBundleIDs: [],
            backgroundStylePreference: .automatic,
            selectedLauncherMode: .floaty,
            isMenuBarIconVisible: true,
            isDockIconVisible: true,
            globalHotkeyDescription: "Cmd+Shift+Space"
        )
    }
}

extension LauncherSettings {
    private enum CodingKeys: String, CodingKey {
        case isVisibleOnAllSpaces
        case launchesAtLogin
        case hiddenBundleIDs
        case backgroundStylePreference
        case selectedLauncherMode
        case isMenuBarIconVisible
        case isDockIconVisible
        case globalHotkeyDescription
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            isVisibleOnAllSpaces: try container.decodeIfPresent(Bool.self, forKey: .isVisibleOnAllSpaces) ?? false,
            launchesAtLogin: try container.decodeIfPresent(Bool.self, forKey: .launchesAtLogin) ?? false,
            hiddenBundleIDs: try container.decodeIfPresent([String].self, forKey: .hiddenBundleIDs) ?? [],
            backgroundStylePreference: try container.decodeIfPresent(PreferredBackgroundStyle.self, forKey: .backgroundStylePreference) ?? .automatic,
            selectedLauncherMode: try container.decodeIfPresent(LauncherMode.self, forKey: .selectedLauncherMode) ?? .floaty,
            isMenuBarIconVisible: try container.decodeIfPresent(Bool.self, forKey: .isMenuBarIconVisible) ?? true,
            isDockIconVisible: try container.decodeIfPresent(Bool.self, forKey: .isDockIconVisible) ?? true,
            globalHotkeyDescription: try container.decodeIfPresent(String.self, forKey: .globalHotkeyDescription) ?? "Cmd+Shift+Space"
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isVisibleOnAllSpaces, forKey: .isVisibleOnAllSpaces)
        try container.encode(launchesAtLogin, forKey: .launchesAtLogin)
        try container.encode(hiddenBundleIDs, forKey: .hiddenBundleIDs)
        try container.encode(backgroundStylePreference, forKey: .backgroundStylePreference)
        try container.encode(selectedLauncherMode, forKey: .selectedLauncherMode)
        try container.encode(isMenuBarIconVisible, forKey: .isMenuBarIconVisible)
        try container.encode(isDockIconVisible, forKey: .isDockIconVisible)
        try container.encode(globalHotkeyDescription, forKey: .globalHotkeyDescription)
    }
}
