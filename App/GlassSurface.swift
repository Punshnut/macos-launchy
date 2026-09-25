import SwiftUI
import AppKit

/// Visual weight for a glass surface. `.prominent` tints with the accent color on macOS 26+.
enum GlassTint {
    case regular
    case prominent
}

extension View {
    /// Applies a rounded glass surface: real Liquid Glass on macOS 26+, an
    /// `NSVisualEffectView`-backed material fallback below that.
    ///
    /// `interactive` should be true for surfaces that host live controls (e.g. a text field)
    /// so macOS 26+ can react to hover/press with its glass highlight.
    @ViewBuilder
    func glassSurface(
        cornerRadius: CGFloat,
        tint: GlassTint = .regular,
        material: NSVisualEffectView.Material = .hudWindow,
        appearance: NSAppearance? = nil,
        interactive: Bool = false
    ) -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(
                tint == .prominent
                    ? .regular.tint(.accentColor).interactive(interactive)
                    : .regular.interactive(interactive),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        } else {
            self
                .background(VisualEffectBackground(material: material, appearance: appearance))
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}

/// Wraps sibling glass surfaces so macOS 26+ can merge/morph them into one glass group.
/// Below macOS 26 this is a transparent passthrough — no extra cost is added on older systems.
struct AdaptiveGlassContainer<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer {
                content
            }
        } else {
            content
        }
    }
}

extension View {
    /// Prominent action button style: real Liquid Glass on macOS 26+, `.borderedProminent` fallback.
    @ViewBuilder
    func glassProminentButtonStyle() -> some View {
        if #available(macOS 26, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }
}

/// Standard corner radii shared by settings/onboarding glass surfaces.
enum GlassRadii {
    static let card: CGFloat = 16
    static let panel: CGFloat = 20
}
