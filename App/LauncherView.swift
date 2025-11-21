import SwiftUI
import AppKit

/// Displays the grid of discovered applications and handles pagination/launch events.
struct LauncherView: View {
    /// Data source backing the grid.
    let appCatalog: [AppItem]
    /// Selected background presentation.
    var backgroundStylePreference: LauncherSettings.PreferredBackgroundStyle = .automatic
    /// Current presentation mode so layout can adapt between floaty and fullscreen.
    var launcherMode: LauncherMode = .floaty
    /// Callback fired whenever the user changes the arrangement.
    var onAppOrderChange: (([AppItem]) -> Void)?

    private var pageCapacity: Int { LauncherGridConfiguration.pageCapacity }
    private let closeAnimationDuration: TimeInterval = 0.25
    private let closeAnimationSlideOffset: CGFloat = 28

    @State private var orderedApps: [AppItem]
    @State private var draggedApp: AppItem?
    @State private var currentPage: Int = 0
    @State private var isClosingLauncher = false
    @State private var searchText = ""

    init(
        appCatalog: [AppItem],
        backgroundStylePreference: LauncherSettings.PreferredBackgroundStyle = .automatic,
        launcherMode: LauncherMode = .floaty,
        onAppOrderChange: (([AppItem]) -> Void)? = nil
    ) {
        self.appCatalog = appCatalog
        self.backgroundStylePreference = backgroundStylePreference
        self.launcherMode = launcherMode
        self.onAppOrderChange = onAppOrderChange
        _orderedApps = State(initialValue: appCatalog)
    }

    /// Builds the full launcher UI including background, grid, and pager controls.
    var body: some View {
        GeometryReader { proxy in
            buildLauncherContent(for: proxy.size)
        }
        .onChange(of: appCatalog) { newValue in
            orderedApps = newValue
            currentPage = 0
        }
        .onChange(of: searchText) { _ in
            currentPage = 0
        }
        .onChange(of: orderedApps) { _ in
            let maxPage = max(pageCount - 1, 0)
            currentPage = min(currentPage, maxPage)
        }
    }

    /// Builds the full-screen filling layers for either floaty or fullscreen modes.
    private func buildLauncherContent(for containerSize: CGSize) -> some View {
        let topInset = fullscreenTopInset(for: containerSize.height)
        let layout = LauncherLayoutMetrics(
            containerSize: containerSize,
            launcherMode: launcherMode,
            topInset: topInset,
            columnsPerPage: LauncherGridConfiguration.columnsPerPage,
            rowsPerPage: LauncherGridConfiguration.rowsPerPage
        )
        let canReorder = searchText.isEmpty

        return ZStack {
            backgroundView()
                .ignoresSafeArea()

            VStack(spacing: 0) {
                fullscreenSpacer(height: topInset)

                VStack(spacing: 0) {
                    searchBar(layout: layout)
                        .padding(.bottom, layout.searchToGridSpacing)

                    ZStack {
                        Group {
                            if filteredAppList.isEmpty {
                                emptyState()
                                    .frame(maxWidth: .infinity, minHeight: layout.gridHeight)
                            } else {
                                GeometryReader { gridProxy in
                                    LazyVGrid(
                                        columns: layout.gridColumns,
                                        alignment: .center,
                                        spacing: layout.iconSpacing
                                    ) {
                                        ForEach(Array(appsForVisiblePage.enumerated()), id: \.element.id) { _, app in
                                            let cell = Button {
                                                openApplication(app)
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

                                            if canReorder {
                                                cell
                                                    .onDrag {
                                                        draggedApp = app
                                                        return NSItemProvider(object: NSString(string: app.bundleIdentifier))
                                                    }
                                            } else {
                                                cell
                                            }
                                        }
                                    }
                                    .frame(maxWidth: .infinity, minHeight: layout.gridHeight, alignment: .top)
                                    .contentShape(Rectangle())
                                    .onDrop(
                                        of: [.text],
                                        delegate: GridReorderDropDelegate(
                                            layout: layout,
                                            gridSize: gridProxy.size,
                                            currentPage: currentPage,
                                            pageCapacity: pageCapacity,
                                            apps: $orderedApps,
                                            draggedApp: $draggedApp,
                                            performReorder: reorderApp(_:to:),
                                            afterReorder: updatePageAfterDrop(at:)
                                        )
                                    )
                                }
                                .frame(height: layout.gridHeight)
                            }
                        }
                        .disabled(isClosingLauncher)

                        ScrollWheelPagerOverlay(
                            isEnabled: isGesturePagingEnabled,
                            onPreviousPage: { pageBackward() },
                            onNextPage: { pageForward() }
                        )
                        .frame(maxWidth: .infinity, minHeight: layout.gridHeight)
                        .allowsHitTesting(false)

                        KeyPressPagerOverlay(
                            isEnabled: isGesturePagingEnabled,
                            onPreviousPage: { pageBackward() },
                            onNextPage: { pageForward() }
                        )
                        .frame(maxWidth: .infinity, minHeight: layout.gridHeight)
                        .allowsHitTesting(false)
                    }
                    .padding(.top, layout.gridVerticalOffset)

                    HStack(spacing: 16) {
                        let previousButton = Button("<") {
                            pageBackward()
                        }
                        .disabled(currentPage == 0 || orderedApps.isEmpty)

                        if canReorder {
                            previousButton.onDrop(
                                of: [.text],
                                delegate: PageReorderDropDelegate(
                                    targetPage: currentPage - 1,
                                    pageCapacity: pageCapacity,
                                    apps: $orderedApps,
                                    draggedApp: $draggedApp,
                                    performReorder: reorderApp(_:to:),
                                    afterReorder: updatePageAfterDrop(at:)
                                )
                            )
                        } else {
                            previousButton
                        }

                        Text(pageIndicatorTitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        let nextButton = Button(">") {
                            pageForward()
                        }
                        .disabled(orderedApps.isEmpty || currentPage >= pageCount - 1)

                        if canReorder {
                            nextButton.onDrop(
                                of: [.text],
                                delegate: PageReorderDropDelegate(
                                    targetPage: currentPage + 1,
                                    pageCapacity: pageCapacity,
                                    apps: $orderedApps,
                                    draggedApp: $draggedApp,
                                    performReorder: reorderApp(_:to:),
                                    afterReorder: updatePageAfterDrop(at:)
                                )
                            )
                        } else {
                            nextButton
                        }
                    }
                    .padding(.top, layout.gridToPagerSpacing)
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
                    dismissFullscreenViaBackgroundTap()
                },
            including: .gesture
        )
    }

    /// Calculates how many pages are required to show all apps.
    private var pageCount: Int {
        guard filteredAppList.isEmpty == false else { return 1 }
        return (filteredAppList.count + pageCapacity - 1) / pageCapacity
    }

    /// Determines when gesture-driven paging should be active.
    private var isGesturePagingEnabled: Bool {
        pageCount > 1 && isClosingLauncher == false
    }

    /// Returns the slice of apps that should be visible for the current page index.
    private var appsForVisiblePage: [AppItem] {
        guard filteredAppList.isEmpty == false else { return [] }
        let startIndex = currentPage * pageCapacity
        guard startIndex < filteredAppList.count else { return [] }
        let endIndex = min(startIndex + pageCapacity, filteredAppList.count)
        return Array(filteredAppList[startIndex..<endIndex])
    }

    /// Moves the dragged app to a new linear position and persists the arrangement.
    @discardableResult
    private func reorderApp(_ app: AppItem, to targetIndex: Int) -> Int? {
        guard let originalIndex = orderedApps.firstIndex(of: app) else { return nil }
        var updated = orderedApps
        updated.remove(at: originalIndex)

        let boundedIndex = max(0, min(targetIndex, updated.count))
        if originalIndex == boundedIndex {
            return nil
        }

        updated.insert(app, at: boundedIndex)
        orderedApps = updated
        onAppOrderChange?(updated)
        return boundedIndex
    }

    /// Keeps the visible page pinned to where the moved app now lives.
    private func updatePageAfterDrop(at index: Int?) {
        guard let index, pageCapacity > 0 else { return }
        let targetPage = index / pageCapacity
        let maxPage = max(pageCount - 1, 0)
        currentPage = min(max(targetPage, 0), maxPage)
    }

    /// Generates the friendly page indicator label.
    private var pageIndicatorTitle: String {
        if filteredAppList.isEmpty {
            return orderedApps.isEmpty ? "No apps found" : "No matching apps"
        }
        return "Page \(currentPage + 1) of \(pageCount)"
    }

    /// Filters the full list of apps based on the current search query.
    private var filteredAppList: [AppItem] {
        let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedQuery.isEmpty == false else { return orderedApps }
        return orderedApps.filter { app in
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
    private func emptyState() -> some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 32, weight: .light))
                .foregroundColor(.secondary)
            Text(orderedApps.isEmpty ? "No apps found" : "No matching apps")
                .font(.title3)
            if orderedApps.isEmpty == false && searchText.isEmpty == false {
                Text("Try a different search term.")
                    .foregroundStyle(.secondary)
            } else if orderedApps.isEmpty {
                Text("Launchy has not indexed any applications yet.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Asks `NSWorkspace` to launch the tapped application and queues the close animation.
    private func openApplication(_ app: AppItem) {
        guard isClosingLauncher == false else { return }
        guard let bundleURL = app.bundleURL else { return }

        isClosingLauncher = true

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration, completionHandler: nil)

        animateAndDismissLauncher()
    }

    /// Fades/slides the launcher window away before hiding it.
    private func animateAndDismissLauncher() {
        guard let window = hostingWindow() else {
            isClosingLauncher = false
            return
        }

        let originalFrame = window.frame
        let shouldSlide = window is FloatyLauncherWindow
        let targetFrame = shouldSlide
            ? originalFrame.offsetBy(dx: 0, dy: -closeAnimationSlideOffset)
            : originalFrame

        NSAnimationContext.runAnimationGroup { context in
            context.duration = closeAnimationDuration
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
                isClosingLauncher = false
            }
        }
    }

    /// Returns the NSWindow currently hosting the launcher content, if any.
    private func hostingWindow() -> NSWindow? {
        NSApp?.keyWindow ?? NSApp?.mainWindow
    }

    /// Moves to the previous page if possible.
    private func pageBackward() {
        guard pageCount > 0 else { return }
        currentPage = max(currentPage - 1, 0)
    }

    /// Moves to the next page if possible.
    private func pageForward() {
        guard pageCount > 0 else { return }
        currentPage = min(currentPage + 1, pageCount - 1)
    }

    /// Hides the fullscreen launcher when the blurred background is clicked.
    private func dismissFullscreenViaBackgroundTap() {
        guard launcherMode == .fullscreenOldMac else { return }
        guard isClosingLauncher == false else { return }
        guard didTapInteractiveView() == false else { return }
        isClosingLauncher = true
        animateAndDismissLauncher()
    }

    /// Returns true when the click landed on an interactive SwiftUI-backed control.
    private func didTapInteractiveView() -> Bool {
        guard let window = hostingWindow(),
              let contentView = window.contentView,
              let event = NSApp?.currentEvent else {
            return false
        }

        let locationInWindow = event.locationInWindow
        let locationInContent = contentView.convert(locationInWindow, from: nil)
        guard contentView.bounds.contains(locationInContent) else { return false }
        guard let hitView = contentView.hitTest(locationInContent) else { return false }

        return hitView.hasAncestor(ofType: NSButton.self) || hitView.hasAncestor(ofType: NSTextField.self)
    }

    /// Chooses the proper background view for the configured style.
    private func backgroundView() -> some View {
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
    private func fullscreenSpacer(height: CGFloat) -> some View {
        if height > 0 {
            Color.clear
                .frame(height: height)
                .accessibilityHidden(true)
        }
    }

    /// Calculates how far the content should sit from the top edge in fullscreen mode.
    private func fullscreenTopInset(for containerHeight: CGFloat) -> CGFloat {
        guard launcherMode == .fullscreenOldMac else { return 0 }
        guard containerHeight.isFinite else { return 0 }
        return max(0, containerHeight / 12)
    }

    /// Custom search field that mirrors the glassy Launchpad design.
    private func searchBar(layout: LauncherLayoutMetrics) -> some View {
        TextField("Search apps", text: $searchText)
            .textFieldStyle(.plain)
            .font(.system(size: layout.searchBarFontSize, weight: .medium))
            .foregroundColor(.primary)
            .onSubmit {
                launchSearchResultIfPossible()
            }
            .padding(.leading, 18)
            .padding(.trailing, 44)
            .frame(height: layout.searchBarHeight)
            .background(
                VisualEffectBackground(material: .menu, blendingMode: .withinWindow)
                    .clipShape(RoundedRectangle(cornerRadius: layout.searchBarCornerRadius, style: .continuous))
            )
            .overlay(alignment: .trailing) {
                if searchText.isEmpty == false {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.primary.opacity(0.55))
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 14)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: layout.searchBarCornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.25))
            )
            .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
            .frame(maxWidth: layout.searchBarWidth)
            .frame(maxWidth: .infinity)
    }

    /// Launches the first matched app when a user submits the search field.
    private func launchSearchResultIfPossible() {
        let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedQuery.isEmpty == false else { return }
        guard let firstMatch = filteredAppList.first else { return }
        openApplication(firstMatch)
    }
}

#Preview {
    LauncherView(
        appCatalog: [
            AppItem(id: UUID(), displayName: "Safari", bundleIdentifier: "com.apple.Safari", iconImage: NSImage(named: NSImage.networkName), bundleURL: nil),
            AppItem(id: UUID(), displayName: "Xcode", bundleIdentifier: "com.apple.dt.Xcode", iconImage: nil, bundleURL: nil),
            AppItem(id: UUID(), displayName: "Notes", bundleIdentifier: "com.apple.Notes", iconImage: nil, bundleURL: nil)
        ],
        backgroundStylePreference: .automatic
    )
}
