import SwiftUI
import AppKit

/// Thin wrapper around `NSVisualEffectView` so SwiftUI layouts can use macOS blur materials.
struct VisualEffectBackground: NSViewRepresentable {
    let visualMaterial: NSVisualEffectView.Material
    let visualBlendingMode: NSVisualEffectView.BlendingMode
    let effectState: NSVisualEffectView.State

    /// Creates a background view with configurable material, blending mode, and state.
    init(
        material: NSVisualEffectView.Material = .hudWindow,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow,
        state: NSVisualEffectView.State = .active
    ) {
        self.visualMaterial = material
        self.visualBlendingMode = blendingMode
        self.effectState = state
    }

    /// Builds the AppKit view instance the first time SwiftUI needs it.
    func makeNSView(context: Context) -> NSVisualEffectView {
        makeView()
    }

    /// Keeps the backing `NSVisualEffectView` synchronized with the SwiftUI state.
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = visualMaterial
        nsView.blendingMode = visualBlendingMode
        nsView.state = effectState
    }

    /// Shared helper that wires up the visual effect view with the chosen options.
    private func makeView() -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = visualMaterial
        view.blendingMode = visualBlendingMode
        view.state = effectState
        view.wantsLayer = true
        return view
    }
}
