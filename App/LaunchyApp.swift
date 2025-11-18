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

            CommandGroup(after: .appSettings) {
                Button("Toggle Launcher Layout") {
                    appDelegate.toggleLauncherModeShortcut()
                }
                .keyboardShortcut("f", modifiers: [.command, .option])
            }

            CommandMenu("Debug") {
                Button("Reload Apps") {
                    appDelegate.reloadAppsFromDebugMenu()
                }

                Button("Reset Settings") {
                    appDelegate.resetSettingsFromDebugMenu()
                }

                Button("Toggle Test Background Styles") {
                    appDelegate.toggleTestBackgroundStyles()
                }
            }
        }
    }
}
