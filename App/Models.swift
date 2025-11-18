import Foundation
import AppKit

/// Represents an application that can be launched through Launchy.
struct AppItem: Identifiable, Hashable {
    let id: UUID
    let name: String
    let bundleIdentifier: String
    let icon: NSImage?
    let url: URL?
}

/// User-configurable settings for how the launcher behaves.
struct LauncherSettings: Hashable {
    enum PreferredBackgroundStyle: String, CaseIterable, Hashable {
        case automatic
        case transparent
        case solid
    }

    var showOnAllSpaces: Bool
    var launchAtLogin: Bool
    var hiddenBundleIdentifiers: [String]
    var preferredBackgroundStyle: PreferredBackgroundStyle
}
