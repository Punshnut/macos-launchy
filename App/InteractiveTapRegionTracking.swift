import SwiftUI

/// Name of the coordinate space the launcher's root content is tagged with, so interactive
/// controls can report their real on-screen frame regardless of how AppKit backs them.
let launcherRootCoordinateSpaceName = "launcherRootContent"

/// Collects the frames (in `launcherRootCoordinateSpaceName` space) of every view that opts in
/// via `.markInteractiveForDismissDetection()`.
private struct InteractiveTapRegionPreferenceKey: PreferenceKey {
    static var defaultValue: [CGRect] { [] }

    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value.append(contentsOf: nextValue())
    }
}

extension View {
    /// Marks this view's frame as "interactive" for the launcher's click-outside-to-dismiss
    /// logic. AppKit's native `hitTest`/`NSButton`-ancestor check (`didTapInteractiveView()` in
    /// `LaunchyView.swift`) doesn't reliably recognize SwiftUI `.buttonStyle(.plain)` controls on
    /// every macOS version — this reports the control's real frame directly from SwiftUI's own
    /// layout instead, so a click's location can be tested against it without depending on how
    /// AppKit happens to back the control.
    func markInteractiveForDismissDetection() -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: InteractiveTapRegionPreferenceKey.self,
                    value: [proxy.frame(in: .named(launcherRootCoordinateSpaceName))]
                )
            }
        )
    }

    /// Applied once, to the launcher's root content view: collects every descendant's
    /// `markInteractiveForDismissDetection()` frame into `regions`.
    func collectInteractiveTapRegions(into regions: Binding<[CGRect]>) -> some View {
        coordinateSpace(name: launcherRootCoordinateSpaceName)
            .onPreferenceChange(InteractiveTapRegionPreferenceKey.self) { regions.wrappedValue = $0 }
    }
}
