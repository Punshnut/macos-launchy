import SwiftUI
import AppKit

// Liquid Glass renditions of the settings controls (macOS 26+).
// Below macOS 26 every control falls back to the stock SwiftUI control used before.
// Glass is applied to small label-free shapes only (thumbs, knobs, tracks) and never over text,
// so labels stay crisp.

// MARK: - Selection pill

/// Soft glass-looking selection pill drawn without a glass effect, so the label above it never blurs.
struct GlassSelectionPill: View {
    var tint: Color = .accentColor

    var body: some View {
        Capsule()
            .fill(tint.opacity(0.30))
            .overlay(Capsule().fill(Color.white.opacity(0.10)))
            .overlay(
                Capsule().strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.55), Color.white.opacity(0.08)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.8
                )
            )
            .shadow(color: Color.black.opacity(0.14), radius: 3, y: 1)
    }
}

// MARK: - Toggle

/// Liquid Glass switch: tinted capsule track with a glass thumb.
@available(macOS 26, *)
struct GlassSwitchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer(minLength: 12)
            GlassSwitch(isOn: configuration.isOn) {
                configuration.isOn.toggle()
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { configuration.isOn.toggle() }
    }
}

private struct GlassSwitch: View {
    let isOn: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? Color.accentColor : Color.primary.opacity(0.18))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
            thumb.padding(2)
        }
        .frame(width: 50, height: 28)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isOn)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isOn ? Text("1") : Text("0"))
        .accessibilityAction(.default, action)
    }

    @ViewBuilder
    private var thumb: some View {
        if #available(macOS 26, *) {
            Capsule()
                .fill(Color.white.opacity(0.01))
                .frame(width: 34, height: 24)
                .glassEffect(.regular.interactive(), in: Capsule())
        } else {
            Capsule().fill(Color.white).frame(width: 34, height: 24)
        }
    }
}

/// Liquid Glass checkbox.
@available(macOS 26, *)
struct GlassCheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 8) {
                box(isOn: configuration.isOn)
                configuration.label
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func box(isOn: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        ZStack {
            if isOn { shape.fill(Color.accentColor) }
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(.white)
                .opacity(isOn ? 1 : 0)
        }
        .frame(width: 18, height: 18)
        .glassEffect(.regular.interactive(), in: shape)
    }
}

extension View {
    /// Liquid Glass switch on macOS 26+, stock switch below.
    @ViewBuilder
    func settingsSwitchStyle() -> some View {
        if #available(macOS 26, *) {
            self.toggleStyle(GlassSwitchToggleStyle())
        } else {
            self.toggleStyle(.switch)
        }
    }

    /// Liquid Glass checkbox on macOS 26+, stock checkbox below.
    @ViewBuilder
    func settingsCheckboxStyle() -> some View {
        if #available(macOS 26, *) {
            self.toggleStyle(GlassCheckboxToggleStyle())
        } else {
            self.toggleStyle(.checkbox)
        }
    }
}

// MARK: - Segmented control

/// Segmented picker: glass track with a sliding selection pill on macOS 26+, native segmented picker below.
struct SettingsSegmentedPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [Value]
    let title: (Value) -> String
    @Namespace private var namespace

    var body: some View {
        if #available(macOS 26, *) {
            HStack(spacing: 2) {
                ForEach(options, id: \.self) { option in
                    let isSelected = option == selection
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                            selection = option
                        }
                    } label: {
                        Text(title(option))
                            .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                            .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.7))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .padding(.horizontal, 10)
                            .background {
                                if isSelected {
                                    GlassSelectionPill()
                                        .matchedGeometryEffect(id: "segment", in: namespace)
                                }
                            }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(3)
            .background { Capsule().glassEffect(.regular, in: Capsule()) }
        } else {
            Picker("", selection: $selection) {
                ForEach(options, id: \.self) { Text(title($0)).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
    }
}

// MARK: - Slider

/// Slider with a glass knob on macOS 26+, native slider below.
struct SettingsSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double

    var body: some View {
        if #available(macOS 26, *) {
            GlassSlider(value: $value, range: range, step: step)
        } else {
            Slider(value: $value, in: range, step: step)
        }
    }
}

@available(macOS 26, *)
private struct GlassSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    @Environment(\.isEnabled) private var isEnabled

    private let knobWidth: CGFloat = 30
    private let knobHeight: CGFloat = 20

    var body: some View {
        GeometryReader { proxy in
            let travel = max(proxy.size.width - knobWidth, 1)
            let span = max(range.upperBound - range.lowerBound, .leastNonzeroMagnitude)
            let fraction = CGFloat((value - range.lowerBound) / span)
            let x = fraction * travel

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.16))
                    .frame(height: 6)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: x + knobWidth / 2, height: 6)
                Capsule()
                    .fill(Color.white.opacity(0.01))
                    .frame(width: knobWidth, height: knobHeight)
                    .glassEffect(.regular.interactive(), in: Capsule())
                    .offset(x: x)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { drag in
                    let ratio = min(max((drag.location.x - knobWidth / 2) / travel, 0), 1)
                    var raw = range.lowerBound + Double(ratio) * span
                    if step > 0 {
                        raw = (raw / step).rounded() * step
                    }
                    let snapped = min(max(raw, range.lowerBound), range.upperBound)
                    if snapped != value { value = snapped }
                }
            )
        }
        .frame(height: 24)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityElement()
        .accessibilityValue(Text(value, format: .number.precision(.fractionLength(0...2))))
        .accessibilityAdjustableAction { direction in
            let delta = step > 0 ? step : (range.upperBound - range.lowerBound) / 20
            switch direction {
            case .increment: value = min(value + delta, range.upperBound)
            case .decrement: value = max(value - delta, range.lowerBound)
            @unknown default: break
            }
        }
    }
}

// MARK: - Stepper

/// Stepper with glass +/- buttons on macOS 26+, native stepper below.
struct SettingsStepper: View {
    init(title: String, value: Binding<Int>, in range: ClosedRange<Int>) {
        self.title = title
        self._value = value
        self.range = range
    }
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        if #available(macOS 26, *) {
            HStack {
                Text(title)
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    Button { value = max(value - 1, range.lowerBound) } label: {
                        Image(systemName: "minus").frame(width: 14, height: 14)
                    }
                    .disabled(value <= range.lowerBound)
                    Button { value = min(value + 1, range.upperBound) } label: {
                        Image(systemName: "plus").frame(width: 14, height: 14)
                    }
                    .disabled(value >= range.upperBound)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.small)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: value = min(value + 1, range.upperBound)
                case .decrement: value = max(value - 1, range.lowerBound)
                @unknown default: break
                }
            }
        } else {
            Stepper(title, value: $value, in: range)
        }
    }
}

// MARK: - Menu picker

/// Pop-up picker rendered as a glass button on macOS 26+, native menu picker below.
struct SettingsMenuPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [Value]
    let title: (Value) -> String

    var body: some View {
        if #available(macOS 26, *) {
            Menu {
                ForEach(options, id: \.self) { option in
                    Button {
                        selection = option
                    } label: {
                        if option == selection {
                            Label(title(option), systemImage: "checkmark")
                        } else {
                            Text(title(option))
                        }
                    }
                }
            } label: {
                Text(title(selection))
            }
            .menuStyle(.button)
            .buttonStyle(.glass)
            .fixedSize()
        } else {
            Picker("", selection: $selection) {
                ForEach(options, id: \.self) { Text(title($0)).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }
}

// MARK: - Fields, rows and backdrop

extension View {
    /// Glass plate for text-field-like surfaces (hotkey recorder) on macOS 26+, the previous tinted plate below.
    @ViewBuilder
    func settingsFieldPlate(cornerRadius: CGFloat = 17) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26, *) {
            self
                .glassEffect(.regular.interactive(), in: shape)
                .overlay(shape.strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1.2))
        } else {
            self
                .background(shape.fill(Color.white.opacity(0.02)))
                .overlay(shape.strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1.6))
                .shadow(color: Color.accentColor.opacity(0.18), radius: 6, y: 1)
        }
    }

    /// Hover highlight for full-width link rows (macOS 26+ only; no effect below).
    func settingsRowHover() -> some View {
        modifier(SettingsRowHover())
    }
}

private struct SettingsRowHover: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(hovering ? 0.09 : 0))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                }
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.15), value: hovering)
        } else {
            content
        }
    }
}

/// Window backdrop: system Liquid Glass (`NSGlassEffectView`) on macOS 26+, frosted material below
/// or when Reduce Transparency is on.
struct SettingsWindowBackdrop: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if #available(macOS 26, *), !reduceTransparency {
            GlassBackdropView(cornerRadius: 32)
        } else {
            FrostedBackgroundView(material: .hudWindow)
        }
    }
}

@available(macOS 26, *)
private struct GlassBackdropView: NSViewRepresentable {
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        view.style = .regular
        view.cornerRadius = cornerRadius
        view.contentView = NSView()
        return view
    }

    func updateNSView(_ nsView: NSGlassEffectView, context: Context) {
        nsView.cornerRadius = cornerRadius
    }
}
