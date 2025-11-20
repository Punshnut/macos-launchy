import SwiftUI
import AppKit

/// Displays the grid of discovered applications and handles pagination/launch events.
struct LauncherView: View {
    /// Data source backing the grid.
    let appLibrary: [AppItem]
    /// Selected background presentation.
    var backgroundStylePreference: LauncherSettings.PreferredBackgroundStyle = .automatic
    /// Current presentation mode so layout can adapt between floaty and fullscreen.
    var launcherMode: LauncherMode = .floaty

    private let columnsPerPage = 7
    private let rowsPerPage = 5
    private var appsPerPage: Int { columnsPerPage * rowsPerPage }
    private let launcherDismissalAnimationDuration: TimeInterval = 0.25
    private let launcherDismissalSlideOffset: CGFloat = 28

    @State private var currentPageIndex = 0
    @State private var isAnimatingLauncherDismissal = false
    @State private var searchQuery = ""

    /// Builds the full launcher UI including background, grid, and pager controls.
    var body: some View {
        GeometryReader { proxy in
            launcherContent(for: proxy.size)
        }
        .onChange(of: appLibrary) { _ in
            currentPageIndex = 0
        }
        .onChange(of: searchQuery) { _ in
            currentPageIndex = 0
        }
    }

    /// Builds the full-screen filling layers for either floaty or fullscreen modes.
    private func launcherContent(for containerSize: CGSize) -> some View {
        let topInset = topContentInset(for: containerSize.height)
        let layout = LauncherLayoutMetrics(
            containerSize: containerSize,
            launcherMode: launcherMode,
            topInset: topInset,
            columnsPerPage: columnsPerPage,
            rowsPerPage: rowsPerPage
        )

        return ZStack {
            backgroundLayer()
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topContentSpacer(height: topInset)

                VStack(spacing: layout.sectionSpacing) {
                    searchField(layout: layout)

                    ZStack {
                        Group {
                            if filteredApps.isEmpty {
                                emptyStateView()
                                    .frame(maxWidth: .infinity, minHeight: layout.gridHeight)
                            } else {
                                LazyVGrid(
                                    columns: layout.gridColumns,
                                    alignment: .center,
                                    spacing: layout.iconSpacing
                                ) {
                                    ForEach(appsForCurrentPage) { app in
                                        Button {
                                            launchApplication(app)
                                        } label: {
                                            VStack(spacing: 10) {
                                                iconView(for: app)
                                                    .resizable()
                                                    .aspectRatio(contentMode: .fit)
                                                    .frame(
                                                        width: layout.iconDimension,
                                                        height: layout.iconDimension
                                                    )
                                                Text(app.displayName)
                                                    .font(.system(size: 13, weight: .medium))
                                                    .multilineTextAlignment(.center)
                                                    .foregroundColor(.primary)
                                                    .lineLimit(2)
                                                    .frame(maxWidth: .infinity)
                                            }
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 4)
                                        }
                                        .buttonStyle(.plain)
                                        .contentShape(Rectangle())
                                    }
                                }
                                .frame(maxWidth: .infinity, minHeight: layout.gridHeight, alignment: .top)
                            }
                        }
                        .disabled(isAnimatingLauncherDismissal)

                        ScrollWheelPagerOverlay(
                            isEnabled: shouldEnableGesturePaging,
                            onPreviousPage: { goToPreviousPage() },
                            onNextPage: { goToNextPage() }
                        )
                        .frame(maxWidth: .infinity, minHeight: layout.gridHeight)
                        .allowsHitTesting(false)
                    }

                    HStack(spacing: 16) {
                        Button("Previous") {
                            goToPreviousPage()
                        }
                        .disabled(currentPageIndex == 0 || appLibrary.isEmpty)

                        Text(pageIndicatorLabel)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Button("Next") {
                            goToNextPage()
                        }
                        .disabled(appLibrary.isEmpty || currentPageIndex >= totalPageCount - 1)
                    }
                }
                .padding(.horizontal, layout.horizontalPadding)
                .padding(.bottom, layout.bottomPadding)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: containerSize.width, height: containerSize.height)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onEnded { _ in
                    handleBackgroundTap()
                },
            including: .gesture
        )
    }

    /// Calculates how many pages are required to show all apps.
    private var totalPageCount: Int {
        guard filteredApps.isEmpty == false else { return 1 }
        return (filteredApps.count + appsPerPage - 1) / appsPerPage
    }

    /// Determines when gesture-driven paging should be active.
    private var shouldEnableGesturePaging: Bool {
        totalPageCount > 1 && isAnimatingLauncherDismissal == false
    }

    /// Returns the slice of apps that should be visible for the current page index.
    private var appsForCurrentPage: [AppItem] {
        guard filteredApps.isEmpty == false else { return [] }
        let startIndex = currentPageIndex * appsPerPage
        guard startIndex < filteredApps.count else { return [] }
        let endIndex = min(startIndex + appsPerPage, filteredApps.count)
        return Array(filteredApps[startIndex..<endIndex])
    }

    /// Generates the friendly page indicator label.
    private var pageIndicatorLabel: String {
        if filteredApps.isEmpty {
            return appLibrary.isEmpty ? "No apps found" : "No matching apps"
        }
        return "Page \(currentPageIndex + 1) of \(totalPageCount)"
    }

    /// Filters the full list of apps based on the current search query.
    private var filteredApps: [AppItem] {
        let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedQuery.isEmpty == false else { return appLibrary }
        return appLibrary.filter { app in
            app.displayName.localizedCaseInsensitiveContains(trimmedQuery) ||
            app.bundleIdentifier.localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    /// Picks either the discovered icon or the fallback system glyph.
    private func iconView(for app: AppItem) -> Image {
        if let nsImage = app.iconImage {
            return Image(nsImage: nsImage)
        } else {
            return Image(systemName: "app.fill")
        }
    }

    /// Simple empty state shown when the grid has nothing to display.
    private func emptyStateView() -> some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 32, weight: .light))
                .foregroundColor(.secondary)
            Text(appLibrary.isEmpty ? "No apps found" : "No matching apps")
                .font(.title3)
            if appLibrary.isEmpty == false && searchQuery.isEmpty == false {
                Text("Try a different search term.")
                    .foregroundStyle(.secondary)
            } else if appLibrary.isEmpty {
                Text("Launchy has not indexed any applications yet.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Asks `NSWorkspace` to launch the tapped application and queues the close animation.
    private func launchApplication(_ app: AppItem) {
        guard isAnimatingLauncherDismissal == false else { return }
        guard let bundleURL = app.bundleURL else { return }

        isAnimatingLauncherDismissal = true

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration, completionHandler: nil)

        performCloseAnimation()
    }

    /// Fades/slides the launcher window away before hiding it.
    private func performCloseAnimation() {
        guard let window = activeHostingWindow() else {
            isAnimatingLauncherDismissal = false
            return
        }

        let originalFrame = window.frame
        let shouldSlide = window is FloatyLauncherWindow
        let targetFrame = shouldSlide
            ? originalFrame.offsetBy(dx: 0, dy: -launcherDismissalSlideOffset)
            : originalFrame

        NSAnimationContext.runAnimationGroup { context in
            context.duration = launcherDismissalAnimationDuration
            window.animator().alphaValue = 0
            if shouldSlide {
                window.animator().setFrame(targetFrame, display: true)
            }
        } completionHandler: {
            Task { @MainActor in
                window.orderOut(nil)
                window.alphaValue = 1
                if shouldSlide {
                    window.setFrame(originalFrame, display: false)
                }
                isAnimatingLauncherDismissal = false
            }
        }
    }

    /// Returns the NSWindow currently hosting the launcher content, if any.
    private func activeHostingWindow() -> NSWindow? {
        NSApp?.keyWindow ?? NSApp?.mainWindow
    }

    /// Moves to the previous page if possible.
    private func goToPreviousPage() {
        guard totalPageCount > 0 else { return }
        currentPageIndex = max(currentPageIndex - 1, 0)
    }

    /// Moves to the next page if possible.
    private func goToNextPage() {
        guard totalPageCount > 0 else { return }
        currentPageIndex = min(currentPageIndex + 1, totalPageCount - 1)
    }

    /// Hides the fullscreen launcher when the blurred background is clicked.
    private func handleBackgroundTap() {
        guard launcherMode == .fullscreenOldMac else { return }
        guard isAnimatingLauncherDismissal == false else { return }
        guard isInteractiveViewHit() == false else { return }
        isAnimatingLauncherDismissal = true
        performCloseAnimation()
    }

    /// Returns true when the click landed on an interactive SwiftUI-backed control.
    private func isInteractiveViewHit() -> Bool {
        guard let window = activeHostingWindow(),
              let contentView = window.contentView,
              let event = NSApp?.currentEvent else {
            return false
        }

        let locationInWindow = event.locationInWindow
        let locationInContent = contentView.convert(locationInWindow, from: nil)
        guard contentView.bounds.contains(locationInContent) else { return false }
        guard let hitView = contentView.hitTest(locationInContent) else { return false }

        return hitView.isDescended(from: NSButton.self) || hitView.isDescended(from: NSTextField.self)
    }

    /// Chooses the proper background view for the configured style.
    private func backgroundLayer() -> some View {
        switch backgroundStylePreference {
        case .automatic:
            return AnyView(VisualEffectBackground(material: .hudWindow, blendingMode: .behindWindow))
        case .transparent:
            return AnyView(Color.clear)
        case .solid:
            return AnyView(Color(nsColor: .windowBackgroundColor))
        }
    }

    /// Inserts the top spacer only when fullscreen mode is active.
    @ViewBuilder
    private func topContentSpacer(height: CGFloat) -> some View {
        if height > 0 {
            Color.clear
                .frame(height: height)
                .accessibilityHidden(true)
        }
    }

    /// Calculates how far the content should sit from the top edge in fullscreen mode.
    private func topContentInset(for containerHeight: CGFloat) -> CGFloat {
        guard launcherMode == .fullscreenOldMac else { return 0 }
        guard containerHeight.isFinite else { return 0 }
        return max(0, containerHeight / 12)
    }

    /// Custom search field that mirrors the glassy Launchpad design.
    private func searchField(layout: LauncherLayoutMetrics) -> some View {
        TextField("Search apps", text: $searchQuery)
            .textFieldStyle(.plain)
            .font(.system(size: layout.searchFieldFontSize, weight: .medium))
            .foregroundColor(.primary)
            .padding(.horizontal, 18)
            .frame(height: layout.searchFieldHeight)
            .background(
                VisualEffectBackground(material: .menu, blendingMode: .withinWindow)
                    .clipShape(RoundedRectangle(cornerRadius: layout.searchFieldCornerRadius, style: .continuous))
            )
            .overlay(
                RoundedRectangle(cornerRadius: layout.searchFieldCornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.25))
            )
            .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
            .frame(maxWidth: layout.searchFieldWidth)
            .frame(maxWidth: .infinity)
    }
}

/// Invisible AppKit host view that captures scroll wheel events so users can page with gestures.
private struct ScrollWheelPagerOverlay: NSViewRepresentable {
    var isEnabled: Bool
    var onPreviousPage: () -> Void
    var onNextPage: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPreviousPage: onPreviousPage, onNextPage: onNextPage)
    }

    func makeNSView(context: Context) -> PassthroughView {
        let view = PassthroughView()
        view.coordinator = context.coordinator
        context.coordinator.hostingView = view
        return view
    }

    func updateNSView(_ nsView: PassthroughView, context: Context) {
        context.coordinator.hostingView = nsView
        context.coordinator.isEnabled = isEnabled
    }

    static func dismantleNSView(_ nsView: PassthroughView, coordinator: Coordinator) {
        coordinator.stopMonitoring()
    }

    /// Keeps track of the AppKit event monitor and translates deltas into paging requests.
    @MainActor
    final class Coordinator {
        var isEnabled: Bool = true {
            didSet {
                if isEnabled == false {
                    resetAccumulators()
                }
            }
        }

        weak var hostingView: NSView?

        private let onPreviousPage: () -> Void
        private let onNextPage: () -> Void
        private var scrollMonitor: Any?
        private var horizontalAccumulator: CGFloat = 0
        private let preciseThreshold: CGFloat = 20

        init(onPreviousPage: @escaping () -> Void, onNextPage: @escaping () -> Void) {
            self.onPreviousPage = onPreviousPage
            self.onNextPage = onNextPage
        }

        func startMonitoringIfNeeded() {
            guard scrollMonitor == nil else { return }
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handleScroll(event)
                return event
            }
        }

        func stopMonitoring() {
            if let scrollMonitor {
                NSEvent.removeMonitor(scrollMonitor)
            }
            scrollMonitor = nil
            resetAccumulators()
        }

        private func handleScroll(_ event: NSEvent) {
            guard isEnabled,
                  let view = hostingView,
                  view.window != nil else {
                return
            }

            let location = event.locationInWindow
            let localPoint = view.convert(location, from: nil)
            guard view.bounds.contains(localPoint) else {
                return
            }

            if event.phase.contains(.began) {
                horizontalAccumulator = 0
            }

            if processHorizontalScroll(delta: event.scrollingDeltaX, isPrecise: event.hasPreciseScrollingDeltas) {
                if event.phase.contains(.ended) || event.momentumPhase.contains(.ended) {
                    horizontalAccumulator = 0
                }
                return
            }

            if event.hasPreciseScrollingDeltas == false {
                processDiscreteVerticalScroll(delta: event.scrollingDeltaY)
            }

            if event.phase.contains(.ended) || event.momentumPhase.contains(.ended) {
                horizontalAccumulator = 0
            }
        }

        @discardableResult
        private func processHorizontalScroll(delta: CGFloat, isPrecise: Bool) -> Bool {
            guard abs(delta) > 0.01 else { return false }

            let threshold = isPrecise ? preciseThreshold : 1
            horizontalAccumulator += delta

            if horizontalAccumulator <= -threshold {
                trigger(.next)
                horizontalAccumulator = 0
                return true
            } else if horizontalAccumulator >= threshold {
                trigger(.previous)
                horizontalAccumulator = 0
                return true
            }

            return false
        }

        private func processDiscreteVerticalScroll(delta: CGFloat) {
            guard abs(delta) >= 1 else { return }
            if delta <= -1 {
                trigger(.next)
            } else if delta >= 1 {
                trigger(.previous)
            }
        }

        private func trigger(_ direction: PageDirection) {
            switch direction {
            case .next:
                onNextPage()
            case .previous:
                onPreviousPage()
            }
        }

        private func resetAccumulators() {
            horizontalAccumulator = 0
        }

        private enum PageDirection {
            case next
            case previous
        }
    }

    /// A transparent NSView that reports window changes to the coordinator.
    final class PassthroughView: NSView {
        weak var coordinator: Coordinator?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            translatesAutoresizingMaskIntoConstraints = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                coordinator?.hostingView = self
                coordinator?.startMonitoringIfNeeded()
            } else {
                coordinator?.hostingView = nil
                coordinator?.stopMonitoring()
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }
    }
}

private extension NSView {
    /// Walks superviews to determine whether the hierarchy includes the target type.
    func isDescended(from type: NSView.Type) -> Bool {
        var current: NSView? = self
        while let view = current {
            if view.isKind(of: type) {
                return true
            }
            current = view.superview
        }
        return false
    }
}

/// Describes layout constants for the launcher grid based on the current mode + size.
private struct LauncherLayoutMetrics {
    let containerSize: CGSize
    let launcherMode: LauncherMode
    let topInset: CGFloat
    let columnsPerPage: Int
    let rowsPerPage: Int

    var sectionSpacing: CGFloat {
        switch launcherMode {
        case .floaty:
            return 20
        case .fullscreenOldMac:
            return 28
        }
    }

    var horizontalPadding: CGFloat {
        switch launcherMode {
        case .floaty:
            return 32
        case .fullscreenOldMac:
            return max(60, containerSize.width * 0.08)
        }
    }

    var bottomPadding: CGFloat {
        switch launcherMode {
        case .floaty:
            return 28
        case .fullscreenOldMac:
            return 56
        }
    }

    var iconSpacing: CGFloat {
        switch launcherMode {
        case .floaty:
            return 14
        case .fullscreenOldMac:
            let base = min(containerSize.width, containerSize.height) / 40
            return max(20, min(base, 60))
        }
    }

    var searchFieldWidth: CGFloat {
        let cap: CGFloat = launcherMode == .floaty ? 520 : 620
        let available = max(containerSize.width - horizontalPadding * 2, 320)
        return min(cap, available)
    }

    var searchFieldHeight: CGFloat {
        launcherMode == .floaty ? 46 : 52
    }

    var searchFieldCornerRadius: CGFloat {
        launcherMode == .floaty ? 18 : 22
    }

    var searchFieldFontSize: CGFloat {
        launcherMode == .floaty ? 17 : 18
    }

    var gridColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: iconSpacing, alignment: .top),
            count: columnsPerPage
        )
    }

    var iconDimension: CGFloat {
        let widthAllowance = (gridContentWidth - horizontalSpacingTotal) / CGFloat(columnsPerPage)
        let heightAllowance = (availableGridHeight - verticalSpacingTotal) / CGFloat(rowsPerPage)
        let base = min(widthAllowance, heightAllowance)
        let desiredMax: CGFloat = launcherMode == .floaty ? 102 : 140
        let desiredMin: CGFloat = launcherMode == .floaty ? 70 : 96

        guard base.isFinite, base > 0 else {
            return desiredMin
        }

        if base < desiredMin {
            return base
        }

        return min(base, desiredMax)
    }

    var gridHeight: CGFloat {
        let height = iconDimension * CGFloat(rowsPerPage) + verticalSpacingTotal
        return max(height, 0)
    }

    private var gridContentWidth: CGFloat {
        max(containerSize.width - horizontalPadding * 2, 0)
    }

    private var availableGridHeight: CGFloat {
        let consumed = topInset + bottomPadding + searchFieldHeight + estimatedPagerHeight + sectionSpacing * 2
        let remaining = containerSize.height - consumed
        return max(remaining, 0)
    }

    private var verticalSpacingTotal: CGFloat {
        iconSpacing * CGFloat(rowsPerPage - 1)
    }

    private var horizontalSpacingTotal: CGFloat {
        iconSpacing * CGFloat(columnsPerPage - 1)
    }

    private var estimatedPagerHeight: CGFloat {
        40
    }
}

#Preview {
    LauncherView(
        appLibrary: [
            AppItem(id: UUID(), displayName: "Safari", bundleIdentifier: "com.apple.Safari", iconImage: NSImage(named: NSImage.networkName), bundleURL: nil),
            AppItem(id: UUID(), displayName: "Xcode", bundleIdentifier: "com.apple.dt.Xcode", iconImage: nil, bundleURL: nil),
            AppItem(id: UUID(), displayName: "Notes", bundleIdentifier: "com.apple.Notes", iconImage: nil, bundleURL: nil)
        ],
        backgroundStylePreference: .automatic
    )
}
