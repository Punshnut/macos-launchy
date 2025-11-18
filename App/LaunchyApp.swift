import SwiftUI

@main
struct LaunchyApp: App {
    @NSApplicationDelegateAdaptor(LaunchyAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
