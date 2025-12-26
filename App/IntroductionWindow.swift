import SwiftUI
import AppKit

private struct IntroStep: Identifiable {
    let id: Int
    let title: String
    let subtitle: String
    let iconName: String
    let accent: LinearGradient
    let bullets: [IntroBullet]
}

private struct IntroBullet: Identifiable {
    let id = UUID()
    let iconName: String
    let title: String
    let detail: String
}

/// Four-step introduction that walks through Launchy's core features.
struct IntroductionWindow: View {
    var initialStep: Int = 0
    var onFinish: (() -> Void)?
    var onSkip: (() -> Void)?
    var resetToken: UUID = UUID()

    @State private var currentStep: Int = 0

    private var steps: [IntroStep] {
        [
            IntroStep(
                id: 0,
                title: String(localized: "Floaty or fullscreen"),
                subtitle: String(localized: "Pick the layout that fits the moment. Floaty hovers above your desktop, while fullscreen feels like classic Launchpad."),
                iconName: "rectangle.3.group",
                accent: LinearGradient(
                    colors: [Color.blue.opacity(0.85), Color.purple.opacity(0.75)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                bullets: [
                    IntroBullet(iconName: "sparkles", title: String(localized: "Floaty mode"), detail: String(localized: "A panel that stays light and quick. Hide the Dock icon if you want a minimal feel.")),
                    IntroBullet(iconName: "macwindow.on.rectangle", title: String(localized: "Fullscreen mode"), detail: String(localized: "Fill the screen for a focused, grid-first workflow.")),
                    IntroBullet(iconName: "bolt.fill", title: String(localized: "Flip instantly"), detail: String(localized: "Add a layout toggle shortcut in Settings to jump between modes anytime."))
                ]
            ),
            IntroStep(
                id: 1,
                title: String(localized: "Hotkeys you control"),
                subtitle: String(localized: "Launchy ships with Cmd+Shift+Space, but you can set your own shortcuts in Settings > Keyboard."),
                iconName: "keyboard",
                accent: LinearGradient(
                    colors: [Color.cyan.opacity(0.9), Color.green.opacity(0.8)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                bullets: [
                    IntroBullet(iconName: "command", title: String(localized: "Toggle Launchy anywhere"), detail: String(localized: "Record the shortcut you want to open or hide the launcher.")),
                    IntroBullet(iconName: "arrow.left.arrow.right.circle", title: String(localized: "Layout toggle"), detail: String(localized: "Set an optional hotkey to swap floaty and fullscreen on demand.")),
                    IntroBullet(iconName: "arrow.counterclockwise", title: String(localized: "Reset friendly"), detail: String(localized: "Use Reset in Settings if you ever want the defaults back."))
                ]
            ),
            IntroStep(
                id: 2,
                title: String(localized: "Search & organize"),
                subtitle: String(localized: "Type to filter instantly, drag to reorder, and build folders when you need them."),
                iconName: "magnifyingglass",
                accent: LinearGradient(
                    colors: [Color.orange.opacity(0.9), Color.pink.opacity(0.8)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                bullets: [
                    IntroBullet(iconName: "text.magnifyingglass", title: String(localized: "Instant search"), detail: String(localized: "The search bar narrows results as you type, then Enter launches the first match.")),
                    IntroBullet(iconName: "hand.point.up.left.fill", title: String(localized: "Rearrange easily"), detail: String(localized: "Drag icons to reorder pages. Hold Option or Shift while dragging to create folders.")),
                    IntroBullet(iconName: "folder.fill.badge.plus", title: String(localized: "Name folders fast"), detail: String(localized: "Drop onto another app to make a folder, then rename it inline."))
                ]
            ),
            IntroStep(
                id: 3,
                title: String(localized: "Right-click for power"),
                subtitle: String(localized: "Context menus unlock more control wherever you click."),
                iconName: "cursorarrow.click",
                accent: LinearGradient(
                    colors: [Color.indigo.opacity(0.85), Color.blue.opacity(0.8)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                bullets: [
                    IntroBullet(iconName: "ellipsis.circle", title: String(localized: "App actions"), detail: String(localized: "Right-click any app to rename it, move pages, hide it, or jump into folders.")),
                    IntroBullet(iconName: "folder.fill", title: String(localized: "Folder tools"), detail: String(localized: "Rename, reorder, and move folders between pages with the same menu.")),
                    IntroBullet(iconName: "plus.rectangle.on.rectangle", title: String(localized: "Blank canvas"), detail: String(localized: "Right-click the background to drop in a new folder whenever you need one."))
                ]
            )
        ]
    }

    private var currentIntroStep: IntroStep {
        let bounded = min(max(currentStep, 0), steps.count - 1)
        return steps[bounded]
    }

    var body: some View {
        ZStack {
            outerBackground
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                Divider()
                    .opacity(0.1)
                    .overlay(Color.white.opacity(0.05))
                content
                footer
            }
            .frame(minWidth: 720, minHeight: 540)
            .background(
                FrostedBackgroundView(material: .hudWindow)
                    .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
            .overlay(
                HostingWindowFinder { window in
                    updateWindowChrome(for: window)
                }
                .allowsHitTesting(false)
            )
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
        }
        .onAppear {
            currentStep = max(0, min(initialStep, steps.count - 1))
        }
        .onChange(of: resetToken) { _ in
            currentStep = max(0, min(initialStep, steps.count - 1))
        }
    }

    private var outerBackground: some View {
        let gradient = LinearGradient(
            colors: [
                Color.black.opacity(0.4),
                Color.black.opacity(0.25),
                Color.black.opacity(0.4)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        return gradient
            .overlay(Color.white.opacity(0.02))
            .background(Color.clear)
            .blur(radius: 0.4)
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "Meet Launchy"))
                        .font(.system(size: 16, weight: .heavy, design: .rounded))
                    Text(String(localized: "A quick tour of the essentials"))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            progressDots
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    private var progressDots: some View {
        HStack(spacing: 10) {
            ForEach(steps.indices, id: \.self) { index in
                let isActive = index == currentStep
                Capsule()
                    .fill(isActive ? Color.accentColor.opacity(0.9) : Color.white.opacity(0.25))
                    .frame(width: isActive ? 34 : 14, height: 10)
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(isActive ? 0.35 : 0.15), lineWidth: 0.8)
                    )
                    .shadow(color: isActive ? Color.accentColor.opacity(0.35) : .clear, radius: 6, y: 3)
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 18) {
            heroCard(for: currentIntroStep)
            bulletList(for: currentIntroStep)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 24)
    }

    private func heroCard(for step: IntroStep) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(step.accent)
                .overlay(
                    AngularGradient(
                        gradient: Gradient(colors: [
                            Color.white.opacity(0.25),
                            Color.clear,
                            Color.white.opacity(0.25)
                        ]),
                        center: .center
                    )
                    .opacity(0.35)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.25), radius: 18, y: 10)

            VStack(alignment: .leading, spacing: 12) {
                Label {
                    Text(step.title)
                        .font(.system(size: 22, weight: .black, design: .rounded))
                } icon: {
                    Image(systemName: step.iconName)
                        .font(.system(size: 18, weight: .semibold))
                        .padding(10)
                        .background(Color.white.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .foregroundStyle(Color.white)

                Text(step.subtitle)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundColor(Color.white.opacity(0.92))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 560, alignment: .leading)
            }
            .padding(22)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 156)
    }

    private func bulletList(for step: IntroStep) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(step.bullets) { bullet in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: bullet.iconName)
                        .font(.system(size: 16, weight: .bold))
                        .frame(width: 32, height: 32)
                        .foregroundColor(.accentColor)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.accentColor.opacity(0.14))
                        )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(bullet.title)
                            .font(.system(size: 15, weight: .semibold))
                        Text(bullet.detail)
                            .font(.system(size: 13, weight: .regular))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.white.opacity(0.03))
                )
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                finishEarly()
            } label: {
                Label(String(localized: "Skip intro"), systemImage: "forward.end")
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)

            Spacer()

            if currentStep > 0 {
                Button(String(localized: "Back")) {
                    currentStep = max(currentStep - 1, 0)
                }
                .buttonStyle(.bordered)
            }

            Button(action: advance) {
                Label(nextButtonTitle, systemImage: currentStep == steps.count - 1 ? "checkmark.circle" : "arrow.right.circle.fill")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .background(
            Color.white.opacity(0.02)
                .clipShape(RoundedRectangle(cornerRadius: 0, style: .continuous))
        )
    }

    private var nextButtonTitle: String {
        currentStep == steps.count - 1
        ? String(localized: "Start using Launchy")
        : String(localized: "Next")
    }

    /// Advances the intro carousel or finishes when on the last step.
    private func advance() {
        if currentStep >= steps.count - 1 {
            finish()
        } else {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                currentStep += 1
            }
        }
    }

    /// Exits the intro early, honoring the skip callback when provided.
    private func finishEarly() {
        if let onSkip {
            onSkip()
        } else {
            finish()
        }
    }

    /// Runs the completion callback to mark onboarding done.
    private func finish() {
        onFinish?()
    }

    private func updateWindowChrome(for window: NSWindow?) {
        guard let window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
        window.applyRoundedCorners(radius: 32)
    }
}

/// Window controller that presents the introduction UI and marks it as completed.
final class IntroductionWindowController: NSWindowController {
    static let shared = IntroductionWindowController()
    private var hostingController: NSHostingController<IntroductionWindow>?

    private let defaultWindowSize = NSSize(width: 760, height: 580)

    /// Builds (or rebuilds) the introduction window and presents it.
    func present(
        startingAt step: Int = 0,
        markCompletionOnFinish: Bool = true
    ) {
        let resetToken = UUID()
        let buildView: () -> IntroductionWindow = { [weak self] in
            IntroductionWindow(initialStep: step, onFinish: { [weak self] in
                if markCompletionOnFinish {
                    LauncherSettingsPersistence.setHasCompletedIntroduction(true)
                }
                self?.close()
            }, onSkip: { [weak self] in
                if markCompletionOnFinish {
                    LauncherSettingsPersistence.setHasCompletedIntroduction(true)
                }
                self?.close()
            }, resetToken: resetToken)
        }

        if let host = hostingController, let window {
            host.rootView = buildView()
            window.applyRoundedCorners(radius: 32)
            center(window: window)
            showWindow(nil)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let host = hostingController ?? NSHostingController(rootView: buildView())
        host.view.wantsLayer = true
        host.view.layer?.backgroundColor = NSColor.clear.cgColor
        let windowFrame = centeredFrame(for: defaultWindowSize)
        let window = NSWindow(
            contentRect: windowFrame,
            styleMask: [
                .titled,
                .fullSizeContentView,
                .closable,
                .resizable
            ],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenAuxiliary)
        window.collectionBehavior.insert(.canJoinAllSpaces)
        window.level = .screenSaver
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.contentViewController = host
        window.applyRoundedCorners(radius: 32)

        hostingController = host
        self.window = window

        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func center(window: NSWindow) {
        let frame = centeredFrame(for: window.frame.size)
        window.setFrame(frame, display: false)
    }

    private func centeredFrame(for size: NSSize) -> NSRect {
        guard let screen = ScreenProvider.screenUnderMouseOrMain() ?? NSScreen.main else {
            return NSRect(origin: .zero, size: size)
        }
        let visibleFrame = screen.visibleFrame
        let x = max(visibleFrame.midX - size.width / 2, visibleFrame.minX)
        let y = max(visibleFrame.midY - size.height / 2, visibleFrame.minY)
        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }
}
