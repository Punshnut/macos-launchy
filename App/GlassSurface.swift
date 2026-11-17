import SwiftUI
import AppKit

/// Visual weight for a glass surface. `.prominent` tints with a softened (reduced-opacity) accent color on macOS 26+.
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
                    ? .regular.tint(Color.accentColor.opacity(0.55)).interactive(interactive)
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
/// Below macOS 26 this is a transparent passthrough, no extra cost is added on older systems.
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

// MARK: - Settings window glass layer

/// Reads the system-wide knobs that influence how glass should be drawn.
/// Blur/liquidity themselves are applied by the system inside `.glassEffect` and the glass button styles.
enum LaunchyGlassSystem {
    /// Global "Liquid Glass" tint amount (0...1), written by System Settings > Appearance.
    static var tintAmount: Double {
        let value = UserDefaults.standard.double(forKey: "NSGlassTintAmount")
        return min(max(value, 0), 1)
    }
}

/// Card surface used by the settings window. macOS 26+: Liquid Glass (system tint amount honored),
/// Reduce Transparency: opaque, below macOS 26: the previous frosted look with a hairline.
private struct SettingsCardSurface: ViewModifier {
    let cornerRadius: CGFloat
    let legacyStrokeOpacity: Double
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if reduceTransparency {
            content
                .background(shape.fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(shape.stroke(Color.primary.opacity(0.2), lineWidth: 0.75))
        } else if #available(macOS 26, *) {
            let tint = LaunchyGlassSystem.tintAmount
            content
                .glassEffect(
                    tint > 0 ? .regular.tint(Color.accentColor.opacity(0.18 * tint)) : .regular,
                    in: shape
                )
                .overlay {
                    if contrast == .increased {
                        shape.stroke(Color.primary.opacity(0.45), lineWidth: 1)
                    }
                }
        } else {
            content
                .glassSurface(cornerRadius: cornerRadius)
                .overlay(shape.stroke(Color.white.opacity(legacyStrokeOpacity), lineWidth: 1))
        }
    }
}

/// Capsule glass plate for badges and small chips.
private struct SettingsCapsulePlate: ViewModifier {
    let tint: Color?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
        } else if #available(macOS 26, *) {
            content.glassEffect(tint.map { .regular.tint($0) } ?? .regular, in: Capsule())
        } else {
            content.background(Capsule().fill((tint ?? Color.primary).opacity(0.15)))
        }
    }
}

/// Hairline divider: system divider on macOS 26+, the previous white-tinted one below.
private struct SettingsDivider: View {
    var body: some View {
        if #available(macOS 26, *) {
            Divider()
        } else {
            Divider().overlay(Color.white.opacity(0.08))
        }
    }
}

extension View {
    /// Settings card: Liquid Glass on 26+, opaque with Reduce Transparency, legacy frosted below.
    func settingsCardSurface(cornerRadius: CGFloat, legacyStrokeOpacity: Double = 0.08) -> some View {
        modifier(SettingsCardSurface(cornerRadius: cornerRadius, legacyStrokeOpacity: legacyStrokeOpacity))
    }

    /// Capsule glass plate for badges and chips.
    func settingsCapsulePlate(tint: Color? = nil) -> some View {
        modifier(SettingsCapsulePlate(tint: tint))
    }

    /// Settings button style: `.glass` / `.glassProminent` capsule buttons on macOS 26+,
    /// `.bordered` / `.borderedProminent` below.
    @ViewBuilder
    func settingsButtonStyle(prominent: Bool = false) -> some View {
        if #available(macOS 26, *) {
            if prominent {
                self.buttonStyle(.glassProminent)
            } else {
                self.buttonStyle(.glass)
            }
        } else {
            if prominent {
                self.buttonStyle(.borderedProminent)
            } else {
                self.buttonStyle(.bordered)
            }
        }
    }
}

/// Divider used between settings rows.
struct SettingsRowDivider: View {
    var body: some View { SettingsDivider() }
}
