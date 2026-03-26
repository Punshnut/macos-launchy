import SwiftUI

/// Tabs available in the settings window sidebar.
enum SettingsTab: Int, CaseIterable, Identifiable {
    case visuals
    case shortcuts
    case hiddenApps
    case about

    var id: Int { rawValue }

    /// SF Symbol used in the sidebar for the tab.
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

    /// Localized title shown next to the tab icon.
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

/// Centralizes sizing constants for the settings window so both SwiftUI and AppKit code agree.
struct SettingsWindowMetrics {
    static let defaultContentWidth: CGFloat = 900
    static let visualsHeight: CGFloat = 805
    static let shortcutsHeight: CGFloat = 652
    static let hiddenAppsHeight: CGFloat = 680
    static let aboutHeight: CGFloat = 720
    static let minimumContentSize = CGSize(width: 640, height: 520)

    static var defaultContentSize: CGSize {
        CGSize(width: defaultContentWidth, height: visualsHeight)
    }

    /// Returns the preferred height for each tab, letting us resize when the selection changes.
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
