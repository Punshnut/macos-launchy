import SwiftUI

/// Entry point for the Launchy application that wires SwiftUI to the app delegate.
@main
struct LaunchyApp: App {
    /// Keeps the legacy `NSApplicationDelegate` alive so AppKit-specific features work.
    @NSApplicationDelegateAdaptor(LaunchyAppDelegate.self) private var appDelegate

    /// Builds the settings scene that macOS shows from the menu bar.
    var body: some Scene {
        Settings {
            SettingsWindow()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings...") {
                    appDelegate.showSettingsWindow()
                }
                .keyboardShortcut(",", modifiers: [.command])
            }

            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    appDelegate.checkForUpdatesFromMenu()
                }
            }

            CommandGroup(after: .appSettings) {
                Button("Toggle Floaty Panel") {
                    appDelegate.toggleLauncherModeShortcut()
                }
            }
        }
    }
}
