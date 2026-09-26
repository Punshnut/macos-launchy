import SwiftUI
import Security

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
            return String(localized: "SettingsTabVisuals")
        case .shortcuts:
            return String(localized: "SettingsTabShortcuts")
        case .hiddenApps:
            return String(localized: "SettingsTabHiddenApps")
        case .about:
            return String(localized: "SettingsTabAbout")
        }
    }
}

/// Centralizes sizing constants for the settings window so both SwiftUI and AppKit code agree.
struct SettingsWindowMetrics {
    static let defaultContentWidth: CGFloat = 900
    static let visualsHeight: CGFloat = 752
    static let shortcutsHeight: CGFloat = 605
    static let hiddenAppsHeight: CGFloat = 632
    static let aboutHeight: CGFloat = 625
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

/// Distinguishes an officially signed/notarized release from a copy someone
/// built themselves (e.g. via `scripts/build_app.sh`, `swift build`, or
/// `swift run`). Self-built copies are unsigned or ad-hoc signed, so the
/// running app's code-signature Team ID is a tamper-resistant signal that
/// can't be spoofed via a build-time flag. Used by the About tab and the
/// settings top bar to show a "homemade" hint.
enum BuildProvenance {
    /// Jan's Developer ID Team ID, as printed by `print_team_id.sh`
    /// against a signed release build.
    private static let expectedTeamID = "JHV68VH5AC"

    static let isOfficialBuild: Bool = {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else {
            return false
        }
        guard SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess else {
            return false
        }
        var signingInformation: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &signingInformation) == errSecSuccess,
              let info = signingInformation as? [String: Any],
              let teamID = info[kSecCodeInfoTeamIdentifier as String] as? String else {
            return false
        }
        return teamID == expectedTeamID
    }()
}
