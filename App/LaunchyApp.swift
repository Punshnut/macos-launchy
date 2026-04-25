import SwiftUI

/// Entry point for the Launchy application that wires SwiftUI to the app delegate.
@main
struct LaunchyApp: App {
    /// Keeps the legacy `NSApplicationDelegate` alive so AppKit-specific features work.
    @NSApplicationDelegateAdaptor(LaunchyAppDelegate.self) private var appDelegate

    /// Declares the macOS settings scene and wires custom commands for Launchy.
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
