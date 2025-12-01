import SwiftUI

enum SettingsTab: Int, CaseIterable, Identifiable {
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

struct SettingsWindowMetrics {
    static let defaultContentWidth: CGFloat = 720
    static let visualsHeight: CGFloat = 650
    static let shortcutsHeight: CGFloat = 520
    static let hiddenAppsHeight: CGFloat = 700
    static let aboutHeight: CGFloat = 700
    static let minimumContentSize = CGSize(width: 640, height: shortcutsHeight)

    static var defaultContentSize: CGSize {
        CGSize(width: defaultContentWidth, height: visualsHeight)
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
