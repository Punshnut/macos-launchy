import SwiftUI

/// Entry point for the Launchy application that wires SwiftUI to the app delegate.
@main
struct LaunchyApp: App {
    /// Keeps the legacy `NSApplicationDelegate` alive so AppKit-specific features work.
    @NSApplicationDelegateAdaptor(LaunchyAppDelegate.self) private var appDelegate

    /// Declares the macOS settings scene and wires custom commands for Launchy.
    ///
    /// This `Settings` scene exists only to anchor the app-menu "Settings…" item/Cmd+, for
    /// the `.commands` block below, the real settings window is the custom AppKit window
    /// `showSettingsWindow()` presents. Since Launchy declares no `WindowGroup`, AppKit
    /// treats this scene as the app's de-facto main window and auto-presents its own
    /// plain-chrome instance of it on every launch; `LaunchyAppDelegate` closes that stray
    /// window shortly after launch (see `closeStrayAutoPresentedSettingsWindowIfNeeded()`)
    /// since `SceneBuilder` in this SDK doesn't support conditionally applying
    /// `.defaultLaunchBehavior(.suppressed)` (macOS 15+) without raising the deployment target.
    var body: some Scene {
        Settings {
            SettingsWindow()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button(String(localized: "MenuItemSettings")) {
                    appDelegate.showSettingsWindow()
                }
                .keyboardShortcut(",", modifiers: [.command])
            }

            CommandGroup(after: .appInfo) {
                Button(String(localized: "MenuItemCheckUpdates")) {
                    appDelegate.checkForUpdatesFromMenu()
                }
            }

            CommandGroup(after: .appSettings) {
                Button(String(localized: "SettingsFloatyToggleLabel")) {
                    appDelegate.toggleLauncherModeShortcut()
                }
            }
        }
    }
}
