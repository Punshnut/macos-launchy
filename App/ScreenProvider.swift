import AppKit

/// Utility for picking the screen that is currently hosting the user's cursor.
enum ScreenProvider {
    private static var mouseLocation: NSPoint {
        NSEvent.mouseLocation
    }

    /// Returns the screen under the current cursor or falls back to the main display.
    static func screenUnderMouseOrMain() -> NSScreen? {
        if let cursorScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) {
            return cursorScreen
        }
        return NSScreen.main
    }
}
