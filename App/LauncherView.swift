import SwiftUI
import AppKit

private struct FolderDragContext {
    let folderID: UUID
    let app: AppItem
}

private enum AppLocation {
    case root(index: Int)
    case folder(folderIndex: Int, appIndex: Int)
}

private enum PageShiftDirection {
    case forward
    case backward
}

private struct RemovedAppContext {
    var items: [LauncherItem]
    var app: AppItem
    var suggestedIndex: Int
}

private struct FolderOverlayLayout {
    let cardWidth: CGFloat
    let cardHeight: CGFloat
    let columns: Int
    let maxRows: Int
    let spacing: CGFloat
    let gridContentHeight: CGFloat
    let contentInsets: EdgeInsets
    let gridInsets: EdgeInsets
    let titleToGridSpacing: CGFloat

    var gridHeight: CGFloat { gridContentHeight + gridInsets.top + gridInsets.bottom }
    var pageCapacity: Int { max(columns, 1) * max(maxRows, 1) }
}

/// Displays the grid of discovered items (apps and folders) and handles pagination/launch events.
struct LauncherView: View {
    /// Data source backing the grid.
    let itemCatalog: [LauncherItem]
    /// Persisted pagination layout coming from storage.
    let initialPageSizes: [Int]
    /// Selected background presentation.
    var backgroundStylePreference: LauncherSettings.PreferredBackgroundStyle = .standard
    /// Selected solid color when the solid background is active.
    var solidBackgroundColor: LauncherSettings.SolidBackgroundColor = .system
    /// Current presentation mode so layout can adapt between floaty and fullscreen.
    var launcherMode: LauncherMode = .floaty
    /// Whether items should collapse upward to fill earlier gaps.
    var fillsGapsAutomatically: Bool = true
    /// Callback fired when the user requests to open settings from a context menu.
    var onSettingsRequested: (() -> Void)?
    /// Callback fired whenever the user changes the arrangement.
    var onItemOrderChange: (([LauncherItem], [Int]) -> Void)?

    private var pageCapacity: Int { LauncherGridConfiguration.pageCapacity }
    private let closeAnimationDuration: TimeInterval = 0.25
    private let gridSpringAnimation = Animation.spring(response: 0.42, dampingFraction: 0.86, blendDuration: 0.12)
    private let pageSwitchAnimation = Animation.interactiveSpring(response: 0.2, dampingFraction: 0.9, blendDuration: 0.06)
    private let gestureSettleAnimation = Animation.interactiveSpring(response: 0.22, dampingFraction: 0.88, blendDuration: 0.06)
    private let folderOpenAnimation = Animation.spring(response: 0.36, dampingFraction: 0.82, blendDuration: 0.08)
    private let pagerButtonHitPadding: CGFloat = 12
    private let pagerButtonHitSize: CGFloat = 44
    private let pagerButtonHitExpansion: CGFloat = 12

    @State private var orderedItems: [LauncherItem]
    @State private var draggedItem: LauncherItem?
    @State private var currentPage: Int = 0
    @State private var isClosingLauncher = false
    @State private var searchText = ""
    @State private var activeFolder: FolderItem?
    @State private var folderDragContext: FolderDragContext?
    @State private var draggedFolderApp: AppItem?
    @State private var activeFolderFrame: CGRect = .zero
    @State private var folderHoverWorkItem: DispatchWorkItem?
    @State private var folderHoverTargetID: UUID?
    @State private var folderHoverWithSuppressedReorder = false
    @State private var isEditingFolderName = false
    @State private var renamingAppID: UUID?
    @State private var appNameDraft = ""
    @State private var folderNameDraft = ""
    @State private var activeFolderPage = 0
    @State private var pageSizes: [Int]
    @State private var launchingItemID: UUID?
    @State private var pageDirection: PageShiftDirection = .forward
    @State private var folderIconWaveToggle = false
    @State private var pagerDragOffset: CGFloat = 0
    @State private var pagerViewportWidth: CGFloat = 1
    @State private var lastPagerDragDate: Date?
    @FocusState private var isFolderNameFieldFocused: Bool
    @FocusState private var isAppNameFieldFocused: Bool
    @FocusState private var isSearchFieldFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    init(
        itemCatalog: [LauncherItem],
        initialPageSizes: [Int] = [],
        backgroundStylePreference: LauncherSettings.PreferredBackgroundStyle = .standard,
        solidBackgroundColor: LauncherSettings.SolidBackgroundColor = .system,
        launcherMode: LauncherMode = .floaty,
        fillsGapsAutomatically: Bool = true,
        onSettingsRequested: (() -> Void)? = nil,
        onItemOrderChange: (([LauncherItem], [Int]) -> Void)? = nil
    ) {
        self.itemCatalog = itemCatalog
        self.initialPageSizes = initialPageSizes
        self.backgroundStylePreference = backgroundStylePreference
        self.solidBackgroundColor = solidBackgroundColor
        self.launcherMode = launcherMode
        self.fillsGapsAutomatically = fillsGapsAutomatically
        self.onSettingsRequested = onSettingsRequested
        self.onItemOrderChange = onItemOrderChange
        _orderedItems = State(initialValue: itemCatalog)
        _pageSizes = State(initialValue: initialPageSizes)
    }

    /// Builds the full launcher UI including background, grid, and pager controls.
    var body: some View {
        GeometryReader { proxy in
            buildLauncherContent(for: proxy.size)
        }
        .onChange(of: itemCatalog) { newValue in
            orderedItems = newValue
            if fillsGapsAutomatically {
                pageSizes = densePageSizes(for: newValue.count)
            } else {
                pageSizes = normalizePageSizes(initialPageSizes, itemCount: newValue.count)
            }
            currentPage = 0
            pageDirection = .forward
            pagerDragOffset = 0
        }
        .onChange(of: initialPageSizes) { newValue in
            if fillsGapsAutomatically {
                pageSizes = densePageSizes(for: itemCatalog.count)
            } else {
                pageSizes = normalizePageSizes(newValue, itemCount: itemCatalog.count)
            }
            currentPage = 0
            pageDirection = .forward
            pagerDragOffset = 0
        }
        .onChange(of: activeFolder) { newValue in
            if newValue == nil {
                activeFolderFrame = .zero
                folderDragContext = nil
                draggedFolderApp = nil
                cancelFolderHover()
                isEditingFolderName = false
                folderNameDraft = ""
                isFolderNameFieldFocused = false
                folderIconWaveToggle = false
                launchingItemID = nil
                activeFolderPage = 0
            } else if let folder = newValue {
                folderNameDraft = folder.name
                isEditingFolderName = false
                folderIconWaveToggle = true
                launchingItemID = nil
                activeFolderPage = 0
            }
        }
        .onChange(of: searchText) { _ in
            currentPage = 0
            pageDirection = .forward
            pagerDragOffset = 0
        }
        .onChange(of: orderedItems) { newItems in
            if fillsGapsAutomatically {
                pageSizes = densePageSizes(for: newItems.count)
            } else {
                pageSizes = normalizePageSizes(pageSizes, itemCount: newItems.count)
            }
            let maxPage = max(pageCount - 1, 0)
            currentPage = min(currentPage, maxPage)
            pageDirection = .forward
            pagerDragOffset = 0
            if let activeFolder,
               newItems.contains(where: { item in
                    if case let .folder(folder) = item {
                        return folder.id == activeFolder.id
                    }
                    return false
                }) == false {
                self.activeFolder = nil
            }
        }
        .onChange(of: isEditingFolderName) { isEditing in
            if isEditing == false {
                focusSearchFieldIfAppropriate()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            guard let window = notification.object as? NSWindow,
                  isLauncherHostingWindow(window) else { return }
            focusSearchFieldIfAppropriate()
        }
        .onAppear {
            focusSearchFieldIfAppropriate()
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
                            if filteredItemList.isEmpty {
                                emptyState()
                                    .frame(maxWidth: .infinity, minHeight: layout.gridHeight)
                                    .contextMenu {
                                        backgroundContextMenu()
                                    }
                            } else {
                                GeometryReader { gridProxy in
                                    let pageWidth = max(gridProxy.size.width, 1)
                                    let sizes = displayPageSizes
                                    let totalPages = max(pageCount, 1)
                                    let pageIndices = visiblePageIndices(total: totalPages)

                                    let dragGesture = DragGesture(minimumDistance: 2)
                                        .onChanged { value in
                                            guard isGesturePagingEnabled else { return }
                                            beginPagerInteraction(pageWidth: pageWidth)
                                            lastPagerDragDate = Date()
                                            pagerDragOffset = clampPagerOffset(
                                                value.translation.width,
                                                pageWidth: pageWidth
                                            )
                                        }
                                        .onEnded { value in
                                            guard isGesturePagingEnabled else { return }
                                            finishPagerInteraction(
                                                translation: value.translation.width,
                                                predictedEndTranslation: value.predictedEndTranslation.width,
                                                pageWidth: pageWidth
                                            )
                                        }

                                    ZStack(alignment: .leading) {
                                        ForEach(pageIndices, id: \.self) { pageIndex in
                                            let pageItems = itemsForPage(pageIndex, sizes: sizes)
                                            let pageStart = pageStartIndex(for: pageIndex, sizes: sizes)
                                            let itemCountOnPage = sizes.indices.contains(pageIndex) ? sizes[pageIndex] : 0

                                            LazyVGrid(
                                                columns: layout.gridColumns,
                                                alignment: .center,
                                                spacing: layout.iconSpacing
                                            ) {
                                                ForEach(Array(pageItems.enumerated()), id: \.element.id) { _, item in
                                                    let isLaunching = launchingItemID == item.id
                                                    let isFolderBeingOpened = activeFolder?.id == item.id
                                                    let isRenamingApp = renamingAppID == item.id

                                                    let cell: AnyView = {
                                                        if isRenamingApp, case let .app(app) = item {
                                                            return AnyView(
                                                                editableAppCell(app: app, layout: layout)
                                                            )
                                                        }

                                                        return AnyView(
                                                            Button {
                                                                openItem(item)
                                                            } label: {
                                                                VStack(spacing: 10) {
                                                                    iconView(for: item, layout: layout)
                                                                        .frame(
                                                                            width: layout.iconDimension,
                                                                            height: layout.iconDimension
                                                                        )
                                                                        .scaleEffect(isLaunching ? 1.08 : 1.0)
                                                                        .opacity(isLaunching ? 0.4 : 1.0)
                                                                        .animation(.easeInOut(duration: 0.18), value: launchingItemID)
                                                                    appOrFolderTitleView(for: item)
                                                                        .font(.system(size: 13, weight: .medium))
                                                                        .multilineTextAlignment(.center)
                                                                        .foregroundColor(iconLabelColor())
                                                                        .lineLimit(2)
                                                                        .frame(maxWidth: .infinity)
                                                                }
                                                                .frame(maxWidth: .infinity)
                                                                .padding(.vertical, 4)
                                                                .scaleEffect(isFolderBeingOpened ? 1.03 : 1.0)
                                                                .animation(
                                                                    .spring(response: 0.35, dampingFraction: 0.82, blendDuration: 0.06),
                                                                    value: activeFolder?.id
                                                                )
                                                            }
                                                            .buttonStyle(.plain)
                                                        )
                                                    }()

                                                    let decoratedCell = cell
                                                        .contentShape(Rectangle())
                                                        .contextMenu {
                                                            itemContextMenu(for: item)
                                                        }

                                                    if canReorder && isRenamingApp == false {
                                                        decoratedCell
                                                            .onDrag {
                                                                draggedItem = item
                                                                return NSItemProvider(object: NSString(string: item.id.uuidString))
                                                            } preview: {
                                                                dragPreview(for: item, layout: layout)
                                                            }
                                                    } else {
                                                        decoratedCell
                                                    }
                                                }
                                            }
                                            .frame(width: pageWidth, height: layout.gridHeight, alignment: .top)
                                            .contentShape(Rectangle())
                                            .contextMenu {
                                                backgroundContextMenu()
                                            }
                                            .onDrop(
                                                of: [.text],
                                                    delegate: GridReorderDropDelegate(
                                                        layout: layout,
                                                        gridSize: gridProxy.size,
                                                        pageStartIndex: pageStart,
                                                        pageItemCount: itemCountOnPage,
                                                        items: $orderedItems,
                                                        draggedItem: $draggedItem,
                                                        shouldSuppressReorder: { isDragReorderSuppressed() },
                                                        performReorder: { item, targetIndex, preferSwap in
                                                            reorderItem(
                                                                item,
                                                                to: targetIndex,
                                                                preferSwap: preferSwap,
                                                                targetPageHint: pageIndex
                                                            )
                                                        },
                                                        afterReorder: updatePageAfterDrop(at:),
                                                        performFolderDrop: { dragged, target in
                                                            mergeItemsIfNeeded(dragged: dragged, onto: target)
                                                        },
                                                        onFolderHoverExit: cancelFolderHover
                                                    )
                                            )
                                            .opacity(pageOpacity(for: pageIndex, pageWidth: pageWidth))
                                            .offset(x: pageOffset(for: pageIndex, pageWidth: pageWidth))
                                        }
                                    }
                                    .frame(width: pageWidth, height: layout.gridHeight, alignment: .leading)
                                    .gesture(dragGesture)
                                    .animation(gridSpringAnimation, value: orderedItems)
                                    .onAppear {
                                        pagerViewportWidth = pageWidth
                                    }
                                    .onChange(of: gridProxy.size.width) { newWidth in
                                        pagerViewportWidth = max(newWidth, 1)
                                    }
                                }
                                .frame(height: layout.gridHeight)
                            }
                        }
                        .disabled(isClosingLauncher)

                        ScrollWheelPagerOverlay(
                            isEnabled: isGesturePagingEnabled,
                            onScrollProgress: { event in
                                handleScrollProgress(
                                    deltaX: event.deltaX,
                                    phase: event.phase,
                                    momentumPhase: event.momentumPhase,
                                    isPrecise: event.isPrecise
                                )
                            },
                            onScrollEnd: {
                                settlePagerOffset(pageWidth: pagerViewportWidth)
                            },
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

                    gridPager(canReorder: canReorder, layout: layout)
                }
                .padding(.horizontal, layout.horizontalPadding)
                .padding(.bottom, layout.bottomPadding)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            if let folder = activeFolder {
                folderOverlay(for: folder, layout: layout)
            }
        }
        .frame(width: containerSize.width, height: containerSize.height)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onEnded { _ in
                    dismissLauncherViaBackgroundTap()
                },
            including: .gesture
        )
    }

    private var usesGappedLayout: Bool {
        fillsGapsAutomatically == false && searchText.isEmpty
    }

    private var displayPageSizes: [Int] {
        guard filteredItemList.isEmpty == false else { return [] }
        if searchText.isEmpty == false {
            return densePageSizes(for: filteredItemList.count)
        }
        return activePageSizes(for: orderedItems.count)
    }

    /// Calculates how many pages are required to show all apps.
    private var pageCount: Int {
        guard filteredItemList.isEmpty == false else { return 1 }
        return max(displayPageSizes.count, 1)
    }

    /// Page count ignoring active search filters, used by context menus.
    private var fullPageCount: Int {
        guard orderedItems.isEmpty == false else { return 1 }
        return max(activePageSizes(for: orderedItems.count).count, 1)
    }

    /// Determines when gesture-driven paging should be active.
    private var isGesturePagingEnabled: Bool {
        pageCount > 1 && isClosingLauncher == false
    }

    /// Returns the slice of apps that should be visible for a specific page index.
    private func itemsForPage(_ page: Int, sizes: [Int]) -> [LauncherItem] {
        guard filteredItemList.isEmpty == false else { return [] }
        guard sizes.indices.contains(page) else { return [] }
        let startIndex = pageStartIndex(for: page, sizes: sizes)
        let endIndex = min(startIndex + sizes[page], filteredItemList.count)
        guard endIndex > startIndex else { return [] }
        return Array(filteredItemList[startIndex..<endIndex])
    }

    /// Calculates the current horizontal offset for the paged grid stack.
    private func pageOffset(for page: Int, pageWidth: CGFloat) -> CGFloat {
        let current = clampPageIndex(currentPage)
        return CGFloat(page - current) * pageWidth + pagerDragOffset
    }

    /// Records the active viewport width so scroll-based gestures map 1:1 with page width.
    private func beginPagerInteraction(pageWidth: CGFloat) {
        pagerViewportWidth = max(pageWidth, 1)
    }

    /// Finalizes a drag-based page interaction using the predicted end state to capture velocity.
    private func finishPagerInteraction(translation: CGFloat, predictedEndTranslation: CGFloat, pageWidth: CGFloat) {
        let projection = predictedEndTranslation - translation
        settlePagerOffset(pageWidth: pageWidth, projectedDelta: projection)
    }

    /// Applies live scroll deltas from the trackpad so paging feels directly connected to the gesture.
    private func handleScrollProgress(deltaX: CGFloat, phase: NSEvent.Phase, momentumPhase: NSEvent.Phase, isPrecise: Bool) {
        guard isGesturePagingEnabled else { return }
        let width = pagerViewportWidth
        guard width > 0 else { return }
        beginPagerInteraction(pageWidth: width)

        let scale: CGFloat = isPrecise ? 1.0 : 12.0
        pagerDragOffset = clampPagerOffset(pagerDragOffset + deltaX * scale, pageWidth: width)
        lastPagerDragDate = Date()
        if phase.isEmpty && momentumPhase.isEmpty && isPrecise == false {
            settlePagerOffset(pageWidth: width)
            return
        }

        if phase.contains(.ended) || momentumPhase.contains(.ended) {
            settlePagerOffset(pageWidth: width)
        }
    }

    /// Settles the pager to the nearest target page and animates the slide.
    private func settlePagerOffset(pageWidth: CGFloat, projectedDelta: CGFloat = 0) {
        guard pageCount > 0 else {
            pagerDragOffset = 0
            return
        }

        let normalizedWidth = max(pageWidth, 1)
        let totalOffset = pagerDragOffset + projectedDelta
        let progress = totalOffset / normalizedWidth
        let snapThreshold: CGFloat = 0.09
        let fastThreshold: CGFloat = 0.26
        let doubleProgressThreshold: CGFloat = 1.45
        let highVelocityThreshold: CGFloat = 0.95
        let velocity = projectedDelta / normalizedWidth
        let absVelocity = abs(velocity)
        let absProgress = abs(progress)
        let recentDrag = (lastPagerDragDate.map { Date().timeIntervalSince($0) < 0.12 }) ?? false
        let directionSign: Int = {
            if absVelocity > 0.15 {
                return velocity > 0 ? 1 : -1
            }
            return progress > 0 ? 1 : -1
        }()

        var delta = 0
        let allowDouble = (absVelocity > highVelocityThreshold && absProgress > 0.6) || absProgress > doubleProgressThreshold

        if allowDouble {
            delta = 2 * directionSign
        } else if absProgress > fastThreshold {
            delta = 1 * directionSign
        } else if absProgress > snapThreshold || (recentDrag && absProgress > 0.06) {
            delta = 1 * directionSign
        }

        let targetPage = clampPageIndex(currentPage - delta)
        withAnimation(gestureSettleAnimation) {
            pageDirection = targetPage >= currentPage ? .forward : .backward
            currentPage = targetPage
            pagerDragOffset = 0
        }
        lastPagerDragDate = nil
    }

    /// Constrains live offsets so we keep neighbors in memory but avoid excessive empty space.
    private func clampPagerOffset(_ offset: CGFloat, pageWidth: CGFloat) -> CGFloat {
        let limit = pageWidth * 1.1
        let bounded = max(min(offset, limit), -limit)

        if currentPage == 0 && bounded > 0 {
            return min(bounded, pageWidth * 0.35)
        }
        if currentPage >= pageCount - 1 && bounded < 0 {
            return max(bounded, -pageWidth * 0.35)
        }

        return bounded
    }

    /// Safely clamps a page index into the available range.
    private func clampPageIndex(_ index: Int) -> Int {
        guard pageCount > 0 else { return 0 }
        return min(max(index, 0), pageCount - 1)
    }

    /// Computes how visible a page should be based on its proximity to the active page and drag offset.
    private func pageOpacity(for page: Int, pageWidth: CGFloat) -> Double {
        if page == currentPage {
            return 1
        }
        let width = max(pageWidth, 1)
        let dragProgress = pagerDragOffset / width
        let distance = abs(CGFloat(page - currentPage) + dragProgress)
        let visibility = max(0, 1 - distance)
        return Double(min(1, visibility))
    }

    /// Returns only the currently focused page and its immediate neighbors to keep gesture FPS high.
    private func visiblePageIndices(total: Int) -> [Int] {
        guard total > 0 else { return [] }
        let current = clampPageIndex(currentPage)
        return [current - 1, current, current + 1].filter { $0 >= 0 && $0 < total }
    }

    /// Detects modifier keys that disable live reordering during a drag.
    private func isDragReorderSuppressed() -> Bool {
        let flags = NSApp?.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
        return flags.contains(.shift) || flags.contains(.option)
    }

    /// Convenience accessor for the currently dragged app, if any.
    private func currentDraggedApp() -> AppItem? {
        guard case let .app(app) = draggedItem else { return nil }
        return app
    }

    /// Moves the dragged app to a new linear position and persists the arrangement.
    @discardableResult
    private func reorderItem(
        _ item: LauncherItem,
        to targetIndex: Int,
        preferSwap: Bool = false,
        targetPageHint: Int? = nil
    ) -> Int? {
        guard let originalIndex = orderedItems.firstIndex(of: item) else { return nil }
        let currentSizes = activePageSizes(for: orderedItems.count)
        var updated = orderedItems
        if preferSwap,
           targetIndex < updated.count,
           targetIndex >= 0,
           targetIndex != originalIndex {
            updated.swapAt(originalIndex, targetIndex)
            withAnimation(gridSpringAnimation) {
                orderedItems = updated
            }
            persistOrderChange(using: fillsGapsAutomatically ? nil : currentSizes)
            return targetIndex
        } else {
            updated.remove(at: originalIndex)

            let boundedIndex = max(0, min(targetIndex, updated.count))
            if originalIndex == boundedIndex {
                return nil
            }

            let afterRemovalSizes = pageSizesAfterRemoval(currentSizes, removingIndex: originalIndex, currentCount: orderedItems.count)
            updated.insert(item, at: boundedIndex)
            let afterInsertSizes = pageSizesAfterInsertion(
                afterRemovalSizes,
                insertingIndex: boundedIndex,
                resultingCount: updated.count,
                targetPageHint: targetPageHint
            )
            withAnimation(gridSpringAnimation) {
                orderedItems = updated
            }
            persistOrderChange(using: afterInsertSizes)
            return boundedIndex
        }
    }

    /// Convenience overload for callers that do not care about swap semantics.
    @discardableResult
    private func reorderItem(_ item: LauncherItem, to targetIndex: Int) -> Int? {
        reorderItem(item, to: targetIndex, preferSwap: false)
    }

    /// Reorders an app within a folder, keeping the active overlay in sync.
    private func reorderApp(_ app: AppItem, inFolderWithID folderID: UUID, to targetIndex: Int) {
        guard let folderIndex = orderedItems.firstIndex(where: { item in
            if case let .folder(folder) = item {
                return folder.id == folderID
            }
            return false
        }) else { return }

        guard case var .folder(folder) = orderedItems[folderIndex] else { return }
        guard let originalIndex = folder.apps.firstIndex(of: app) else { return }

        var apps = folder.apps
        apps.remove(at: originalIndex)

        let boundedIndex = max(0, min(targetIndex, apps.count))
        apps.insert(app, at: boundedIndex)

        folder.apps = apps
        updateFolder(folder, at: folderIndex)
    }

    /// Places an app inside a folder at the desired index, removing it from its previous location first.
    private func insertApp(_ app: AppItem, intoFolderWithID folderID: UUID, at targetIndex: Int) {
        guard isApp(app, inFolderWithID: folderID) == false else {
            reorderApp(app, inFolderWithID: folderID, to: targetIndex)
            return
        }

        guard var removal = removeAppFromHierarchy(app) else { return }
        guard let folderIndex = removal.items.firstIndex(where: { item in
            if case let .folder(folder) = item {
                return folder.id == folderID
            }
            return false
        }) else { return }
        guard case var .folder(folder) = removal.items[folderIndex] else { return }

        let boundedIndex = max(0, min(targetIndex, folder.apps.count))
        folder.apps.insert(removal.app, at: boundedIndex)
        removal.items[folderIndex] = .folder(folder)
        withAnimation(gridSpringAnimation) {
            orderedItems = removal.items
            activeFolder = folder
        }
        currentPage = folderIndex / max(pageCapacity, 1)
        pagerDragOffset = 0
        persistOrderChange()
    }

    /// Updates a folder in the ordered list and propagates the change outward.
    private func updateFolder(_ folder: FolderItem, at index: Int? = nil) {
        guard let idx = index ?? orderedItems.firstIndex(where: { item in
            if case let .folder(existing) = item {
                return existing.id == folder.id
            }
            return false
        }) else { return }

        var updated = orderedItems
        updated[idx] = .folder(folder)
        withAnimation(gridSpringAnimation) {
            orderedItems = updated
            activeFolder = folder
        }
        persistOrderChange()
    }

    /// Removes the dragged app from its folder and inserts it into the root grid to continue dragging.
    @discardableResult
    private func extractAppFromFolderForDrag() -> LauncherItem? {
        guard let context = folderDragContext else { return nil }
        guard let folderIndex = orderedItems.firstIndex(where: { item in
            if case let .folder(folder) = item {
                return folder.id == context.folderID
            }
            return false
        }) else { return nil }
        guard case var .folder(folder) = orderedItems[folderIndex] else { return nil }
        guard let removalIndex = folder.apps.firstIndex(of: context.app) else { return nil }

        let app = folder.apps.remove(at: removalIndex)
        var updated = orderedItems
        updated.remove(at: folderIndex)

        if folder.apps.isEmpty == false {
            updated.insert(.folder(folder), at: folderIndex)
        }

        let insertIndex = folder.apps.isEmpty ? folderIndex : folderIndex + 1
        updated.insert(.app(app), at: insertIndex)

        withAnimation(gridSpringAnimation) {
            orderedItems = updated
            activeFolder = nil
        }
        persistOrderChange()
        folderDragContext = nil
        return .app(app)
    }

    /// Converts an active folder drag into a root-level drag by pulling the app out and closing the overlay.
    private func dragItemOutOfFolderIfNeeded() {
        guard activeFolder != nil else { return }
        if let extracted = extractAppFromFolderForDrag() {
            draggedItem = extracted
            draggedFolderApp = nil
        }
    }

    /// Opens a folder overlay mid-drag so the app can be dropped into a specific position.
    private func openFolderForDrag(_ folder: FolderItem, draggedItem: LauncherItem) {
        guard case .app = draggedItem else { return }
        withAnimation(folderOpenAnimation) {
            activeFolder = folder
        }
    }

    /// Starts a delayed folder merge after hovering over a target item.
    private func handleFolderHover(dragged: LauncherItem, onto target: LauncherItem) {
        guard case .app = dragged else {
            cancelFolderHover()
            return
        }
        guard dragged.id != target.id else { return }

        let suppressReorder = isDragReorderSuppressed()
        if folderHoverTargetID == target.id && folderHoverWithSuppressedReorder == suppressReorder {
            return
        }

        cancelFolderHover()
        folderHoverWithSuppressedReorder = suppressReorder

        let action: () -> Void
        let delay: TimeInterval

        switch target {
        case .app:
            action = { mergeItemsIfNeeded(dragged: dragged, onto: target) }
            delay = suppressReorder ? 1.0 : 0.6
        case .folder(let folder):
            if suppressReorder {
                action = { openFolderForDrag(folder, draggedItem: dragged) }
                delay = 1.0
            } else {
                action = { mergeItemsIfNeeded(dragged: dragged, onto: target) }
                delay = 0.6
            }
        }

        let work = DispatchWorkItem {
            action()
            folderHoverTargetID = nil
        }
        folderHoverWorkItem = work
        folderHoverTargetID = target.id
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Cancels any pending folder merge hover.
    private func cancelFolderHover() {
        folderHoverWorkItem?.cancel()
        folderHoverWorkItem = nil
        folderHoverTargetID = nil
        folderHoverWithSuppressedReorder = false
    }

    /// Combines the dragged item with the target item to form or append to a folder.
    private func mergeItemsIfNeeded(dragged: LauncherItem, onto target: LauncherItem) {
        guard dragged.id != target.id else { return }

        var updated = orderedItems
        guard let draggedIndex = updated.firstIndex(of: dragged) else { return }
        let currentSizes = activePageSizes(for: orderedItems.count)
        updated.remove(at: draggedIndex)
        var workingSizes = pageSizesAfterRemoval(currentSizes, removingIndex: draggedIndex, currentCount: orderedItems.count)
        guard let targetIndex = updated.firstIndex(of: target) else { return }

        let mergedFolder: FolderItem
        switch (dragged, target) {
        case let (.app(appToMove), .app(targetApp)):
            mergedFolder = FolderItem(name: FolderItem.defaultName, apps: [targetApp, appToMove])
        case let (.app(appToMove), .folder(existingFolder)):
            var folder = existingFolder
            folder.apps.append(appToMove)
            mergedFolder = folder
        case let (.folder(droppedFolder), .folder(targetFolder)):
            var folder = targetFolder
            folder.apps.append(contentsOf: droppedFolder.apps)
            mergedFolder = folder
        default:
            return
        }

        updated.remove(at: targetIndex)
        updated.insert(.folder(mergedFolder), at: targetIndex)
        workingSizes = pageSizesAfterRemoval(workingSizes, removingIndex: targetIndex, currentCount: orderedItems.count - 1)
        let finalSizes = pageSizesAfterInsertion(workingSizes, insertingIndex: targetIndex, resultingCount: updated.count)
        withAnimation(gridSpringAnimation) {
            orderedItems = updated
        }

        let targetFolderID: UUID? = {
            if case let .folder(folder) = target {
                return folder.id
            }
            return nil
        }()
        let draggedFolderID: UUID? = {
            if case let .folder(folder) = dragged {
                return folder.id
            }
            return nil
        }()

        if let active = activeFolder {
            if let targetFolderID, active.id == targetFolderID {
                activeFolder = mergedFolder
            } else if let draggedFolderID, active.id == draggedFolderID {
                activeFolder = mergedFolder
            }
        }

        persistOrderChange(using: finalSizes)
        updatePageAfterDrop(at: targetIndex)
    }

    /// Keeps the visible page pinned to where the moved app now lives.
    private func updatePageAfterDrop(at index: Int?) {
        guard let index else { return }
        let sizes = activePageSizes(for: orderedItems.count)
        guard let targetPage = pageIndex(forLinearIndex: index, sizes: sizes) else { return }
        let maxPage = max(pageCount - 1, 0)
        let boundedTarget = min(max(targetPage, 0), maxPage)
        withAnimation(pageSwitchAnimation) {
            pageDirection = boundedTarget >= currentPage ? .forward : .backward
            currentPage = boundedTarget
            pagerDragOffset = 0
        }
    }

    /// Generates the friendly page indicator label.
    private var pageIndicatorTitle: String {
        if filteredItemList.isEmpty {
            return orderedItems.isEmpty
            ? String(localized: "No items found")
            : String(localized: "No matching items")
        }
        return String(localized: "Page \(currentPage + 1) of \(pageCount)")
    }

    private func activePageSizes(for itemCount: Int) -> [Int] {
        guard itemCount > 0 else { return [] }
        if fillsGapsAutomatically {
            return densePageSizes(for: itemCount)
        }
        let normalized = normalizePageSizes(pageSizes, itemCount: itemCount)
        return normalized.isEmpty ? densePageSizes(for: itemCount) : normalized
    }

    private func densePageSizes(for itemCount: Int) -> [Int] {
        guard itemCount > 0, pageCapacity > 0 else { return [] }
        var remaining = itemCount
        var sizes: [Int] = []
        while remaining > 0 {
            let count = min(pageCapacity, remaining)
            sizes.append(count)
            remaining -= count
        }
        return sizes
    }

    private func normalizePageSizes(_ raw: [Int], itemCount: Int) -> [Int] {
        guard itemCount > 0, pageCapacity > 0 else { return [] }

        var remaining = itemCount
        var normalized: [Int] = []
        var overflow = 0

        // Carry overflow forward so existing pages absorb extra items before we add a new page.
        for size in raw where remaining > 0 {
            let desired = size + overflow
            let portion = min(desired, pageCapacity, remaining)
            overflow = max(desired - portion, 0)
            guard portion > 0 else { continue }
            normalized.append(portion)
            remaining -= portion
        }

        while remaining > 0 {
            let portion = min(pageCapacity, remaining)
            normalized.append(portion)
            remaining -= portion
        }

        return normalized
    }

    private func pageStartIndex(for page: Int, sizes: [Int]) -> Int {
        guard page > 0, sizes.isEmpty == false else { return 0 }
        let safePage = min(page, sizes.count)
        return sizes.prefix(safePage).reduce(0, +)
    }

    private func pageIndex(forLinearIndex index: Int, sizes: [Int]) -> Int? {
        var remaining = index
        for (page, size) in sizes.enumerated() {
            guard size > 0 else { continue }
            if remaining < size {
                return page
            }
            remaining -= size
        }
        return sizes.isEmpty ? nil : sizes.count - 1
    }

    private func insertionIndexForPage(_ page: Int, sizes: [Int]) -> Int {
        guard sizes.isEmpty == false else { return 0 }
        let boundedPage = max(page, 0)
        if boundedPage >= sizes.count {
            return sizes.reduce(0, +)
        }
        let start = pageStartIndex(for: boundedPage, sizes: sizes)
        return start + sizes[boundedPage]
    }

    private func pageDropInsertionIndex(for page: Int) -> Int {
        var sizes = activePageSizes(for: orderedItems.count)
        let boundedPage = max(page, 0)
        if boundedPage >= sizes.count {
            sizes.append(contentsOf: Array(repeating: 0, count: boundedPage - sizes.count + 1))
        }
        return insertionIndexForPage(boundedPage, sizes: sizes)
    }

    private func pageSizesAfterRemoval(_ sizes: [Int], removingIndex: Int, currentCount: Int) -> [Int] {
        if fillsGapsAutomatically {
            return densePageSizes(for: max(currentCount - 1, 0))
        }

        guard let page = pageIndex(forLinearIndex: removingIndex, sizes: sizes) else {
            return normalizePageSizes(sizes, itemCount: max(currentCount - 1, 0))
        }
        var updated = sizes
        updated[page] = max(updated[page] - 1, 0)
        updated = trimTrailingEmptyPages(updated)
        return normalizePageSizes(updated, itemCount: max(currentCount - 1, 0))
    }

    private func pageSizesAfterInsertion(
        _ sizes: [Int],
        insertingIndex: Int,
        resultingCount: Int,
        targetPageHint: Int? = nil
    ) -> [Int] {
        if fillsGapsAutomatically {
            return densePageSizes(for: resultingCount)
        }

        var updated = sizes
        let targetPage = max(targetPageHint ?? pageIndex(forLinearIndex: insertingIndex, sizes: updated) ?? updated.count, 0)
        if targetPage >= updated.count {
            updated.append(contentsOf: Array(repeating: 0, count: targetPage - updated.count + 1))
        }
        updated[targetPage] += 1
        return normalizePageSizes(updated, itemCount: resultingCount)
    }

    private func trimTrailingEmptyPages(_ sizes: [Int]) -> [Int] {
        var mutable = sizes
        while let last = mutable.last, last == 0 {
            mutable.removeLast()
        }
        return mutable
    }

    private func persistOrderChange(using updatedSizes: [Int]? = nil) {
        let normalized = updatedSizes
            ?? (fillsGapsAutomatically ? densePageSizes(for: orderedItems.count) : normalizePageSizes(pageSizes, itemCount: orderedItems.count))
        pageSizes = normalized
        onItemOrderChange?(orderedItems, normalized)
    }

    /// Filters the full list of apps based on the current search query.
    private var filteredItemList: [LauncherItem] {
        let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedQuery.isEmpty == false else { return orderedItems }
        return orderedItems.filter { item in
            switch item {
            case .app(let app):
                return app.resolvedDisplayName.localizedCaseInsensitiveContains(trimmedQuery) ||
                app.bundleIdentifier.localizedCaseInsensitiveContains(trimmedQuery)
            case .folder(let folder):
                let nameMatches = folder.name.localizedCaseInsensitiveContains(trimmedQuery)
                let contentsMatch = folder.apps.contains { app in
                    app.resolvedDisplayName.localizedCaseInsensitiveContains(trimmedQuery) ||
                    app.bundleIdentifier.localizedCaseInsensitiveContains(trimmedQuery)
                }
                return nameMatches || contentsMatch
            }
        }
    }

    /// Picks either the discovered icon or the fallback system glyph.
    @ViewBuilder
    private func iconView(for item: LauncherItem, layout: LauncherLayoutMetrics) -> some View {
        switch item {
        case .app(let app):
            if let nsImage = app.iconImage {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "app.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        case .folder(let folder):
            folderIcon(for: folder, layout: layout)
        }
    }

    /// Monochrome drag preview to keep the in-grid placeholder untouched.
    private func dragPreview(for item: LauncherItem, layout: LauncherLayoutMetrics) -> some View {
        iconView(for: item, layout: layout)
            .frame(width: layout.iconDimension, height: layout.iconDimension)
            .grayscale(1.0)
            .saturation(0)
            .opacity(0.72)
            .shadow(color: .black.opacity(0.18), radius: 10, y: 6)
    }

    /// Composes a 3x3 grid of the first nine app icons to mimic the macOS folder style.
    private func folderIcon(for folder: FolderItem, layout: LauncherLayoutMetrics) -> some View {
        let previews = Array(folder.apps.prefix(9))
        let spacing = max(layout.iconDimension * 0.04, 2)
        let padding = spacing
        let columns = Array(repeating: GridItem(.flexible(), spacing: spacing, alignment: .center), count: 3)
        let tileSize = max((layout.iconDimension - padding * 2 - spacing * 2) / 3, 10)

        return ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.35))
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)

            LazyVGrid(columns: columns, alignment: .center, spacing: spacing) {
                ForEach(previews, id: \.id) { app in
                    folderTile(for: app)
                        .frame(width: tileSize, height: tileSize)
                }
                ForEach(0..<max(0, 9 - previews.count), id: \.self) { _ in
                    Color.clear
                        .frame(width: tileSize, height: tileSize)
                }
            }
            .padding(padding)
        }
    }

    /// Shows a single tiny app icon inside the folder preview grid.
    @ViewBuilder
    private func folderTile(for app: AppItem) -> some View {
        if let icon = app.iconImage {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.white.opacity(0.15))
                Image(systemName: "app.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(4)
                    .foregroundColor(.primary.opacity(0.75))
            }
        }
    }

    /// Renders a standard title for either an app or folder.
    @ViewBuilder
    private func appOrFolderTitleView(for item: LauncherItem) -> some View {
        Text(item.displayName)
    }

    /// Inline app renaming field embedded in the grid.
    private func editableAppCell(app: AppItem, layout: LauncherLayoutMetrics, fontSize: CGFloat = 13) -> some View {
        VStack(spacing: 10) {
            iconView(for: .app(app), layout: layout)
                .frame(
                    width: layout.iconDimension,
                    height: layout.iconDimension
                )
            TextField("", text: $appNameDraft)
                .textFieldStyle(.plain)
                .font(.system(size: fontSize, weight: .medium))
                .multilineTextAlignment(.center)
                .focused($isAppNameFieldFocused)
                .onSubmit {
                    commitAppRename(app)
                }
                .onChange(of: isAppNameFieldFocused) { focused in
                    if focused == false && renamingAppID == app.id {
                        commitAppRename(app)
                    }
                }
                .onAppear {
                    if renamingAppID == app.id {
                        DispatchQueue.main.async {
                            isAppNameFieldFocused = true
                        }
                    }
                }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .scaleEffect(renamingAppID == app.id ? 1.0 : 0.98)
    }

    /// Renders the folder title and allows inline editing when tapped.
    @ViewBuilder
    private func folderTitleView(for folder: FolderItem) -> some View {
        if isEditingFolderName {
            TextField("", text: $folderNameDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(iconLabelColor())
                .multilineTextAlignment(.center)
                .focused($isFolderNameFieldFocused)
                .onSubmit {
                    commitFolderNameEdit(for: folder)
                }
                .onChange(of: isFolderNameFieldFocused) { focused in
                    if focused == false && isEditingFolderName {
                        commitFolderNameEdit(for: folder)
                    }
                }
                .padding(.top, 8)
                .frame(maxWidth: .infinity)
        } else {
            Text(folder.name.isEmpty ? FolderItem.defaultName : folder.name)
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(iconLabelColor())
                .padding(.top, 8)
                .onTapGesture {
                    beginFolderNameEdit(for: folder)
                }
        }
    }

    private func folderOverlayLayout(for folder: FolderItem, containerSize: CGSize, layout: LauncherLayoutMetrics) -> FolderOverlayLayout {
        let spacing: CGFloat = launcherMode == .floaty ? 18 : 20
        let titleToGridSpacing: CGFloat = launcherMode == .floaty ? 14 : 16
        let targetAspect: CGFloat = 16.0 / 9.0
        let contentInsets = folderContentInsets()
        let gridInsets = folderGridInsets()
        let maxRows = 4

        let widthCap: CGFloat = launcherMode == .floaty ? 860 : 1120
        let widthFloor: CGFloat = launcherMode == .floaty ? 520 : 720
        let widthFactor: CGFloat = launcherMode == .floaty ? 0.9 : 0.94
        let usableWidth = containerSize.width * widthFactor
        let clampedWidth = min(usableWidth, widthCap)
        let cardWidth = max(clampedWidth, min(widthFloor, usableWidth))

        let aspectHeight = cardWidth / targetAspect
        let maxHeightByMode = containerSize.height * (launcherMode == .floaty ? 0.78 : 0.86)
        let maxCardHeight = min(maxHeightByMode, aspectHeight)
        let titleHeight = folderTitleHeight()
        let chromeHeight = contentInsets.top + contentInsets.bottom + titleHeight + titleToGridSpacing + gridInsets.top + gridInsets.bottom
        let allowedGridHeight = max(maxCardHeight - chromeHeight, 0)

        let availableGridWidth = max(cardWidth - contentInsets.leading - contentInsets.trailing - gridInsets.leading - gridInsets.trailing, 0)
        let minColumnWidth = folderMinCellWidth(for: layout)
        let maxColumnsByWidth = max(3, Int(floor((availableGridWidth + spacing) / (minColumnWidth + spacing))))
        let preferredCap = launcherMode == .fullscreen ? 8 : 6
        let softMaxColumns = max(3, min(maxColumnsByWidth, preferredCap))

        func gridContentHeight(for columns: Int) -> CGFloat {
            let perPageCount = min(folder.apps.count, max(columns, 1) * maxRows)
            return folderGridHeight(for: perPageCount, columns: max(columns, 1), spacing: spacing, layout: layout, maxRows: maxRows)
        }

        var columns = softMaxColumns
        var gridContentHeightValue = gridContentHeight(for: columns)

        if gridContentHeightValue > allowedGridHeight && maxColumnsByWidth > columns {
            for candidate in (columns + 1)...maxColumnsByWidth {
                let candidateHeight = gridContentHeight(for: candidate)
                columns = candidate
                gridContentHeightValue = candidateHeight
                if candidateHeight <= allowedGridHeight {
                    break
                }
            }
        }

        let estimatedCardHeight = gridContentHeightValue + chromeHeight
        let cardHeight = estimatedCardHeight

        return FolderOverlayLayout(
            cardWidth: cardWidth,
            cardHeight: cardHeight,
            columns: columns,
            maxRows: maxRows,
            spacing: spacing,
            gridContentHeight: gridContentHeightValue,
            contentInsets: contentInsets,
            gridInsets: gridInsets,
            titleToGridSpacing: titleToGridSpacing
        )
    }

    private func folderGridHeight(for appCount: Int, columns: Int, spacing: CGFloat, layout: LauncherLayoutMetrics, maxRows: Int) -> CGFloat {
        guard columns > 0 else { return 0 }
        let rowsNeeded = Int(ceil(Double(max(appCount, 1)) / Double(columns)))
        let rows = max(1, min(maxRows, rowsNeeded))
        let cellHeight = layout.iconDimension + folderCellChromeHeight()
        let spacingTotal = spacing * CGFloat(max(rows - 1, 0))
        return CGFloat(rows) * cellHeight + spacingTotal
    }

    private func folderPages(for folder: FolderItem, overlayLayout: FolderOverlayLayout) -> [[AppItem]] {
        let capacity = max(overlayLayout.pageCapacity, 1)
        guard capacity > 0 else { return [folder.apps] }

        var pages: [[AppItem]] = []
        var index = 0
        let apps = folder.apps

        while index < apps.count {
            let end = min(index + capacity, apps.count)
            pages.append(Array(apps[index..<end]))
            index += capacity
        }

        return pages.isEmpty ? [apps] : pages
    }

    private func folderCellChromeHeight() -> CGFloat {
        let labelHeight = folderLabelLineHeight()
        let padding: CGFloat = 12 // .padding(.vertical, 6)
        let spacing: CGFloat = 10 // VStack spacing between icon and label
        return labelHeight * 2 + padding + spacing
    }

    private func folderLabelLineHeight() -> CGFloat {
        let font = NSFont.systemFont(ofSize: 14, weight: .medium)
        return font.ascender - font.descender + font.leading
    }

    private func folderTitleHeight() -> CGFloat {
        let font = NSFont.systemFont(ofSize: 22, weight: .semibold)
        let lineHeight = font.ascender - font.descender + font.leading
        return lineHeight + 10 // accounts for the extra .padding(.top, 8)
    }

    private func folderContentInsets() -> EdgeInsets {
        switch launcherMode {
        case .floaty:
            return EdgeInsets(top: 20, leading: 26, bottom: 20, trailing: 26)
        case .fullscreen:
            return EdgeInsets(top: 26, leading: 32, bottom: 26, trailing: 32)
        }
    }

    private func folderGridInsets() -> EdgeInsets {
        EdgeInsets(top: 6, leading: 10, bottom: 8, trailing: 10)
    }

    private func folderMinCellWidth(for layout: LauncherLayoutMetrics) -> CGFloat {
        max(layout.iconDimension + 28, 110)
    }

    @ViewBuilder
    private func folderPager(currentPage: Int, totalPages: Int) -> some View {
        HStack(spacing: 12) {
            Button {
                withAnimation(folderOpenAnimation) {
                    activeFolderPage = max(currentPage - 1, 0)
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary.opacity(currentPage == 0 ? 0.35 : 0.8))
                    .frame(width: 28, height: 28)
            }
            .padding(.horizontal, pagerButtonHitPadding)
            .padding(.vertical, pagerButtonHitPadding)
            .frame(minWidth: pagerButtonHitSize, minHeight: pagerButtonHitSize)
            .contentShape(Rectangle().inset(by: -pagerButtonHitExpansion))
            .buttonStyle(.plain)
            .disabled(currentPage == 0)

            pagerDots(currentPage: currentPage, totalPages: totalPages) { index in
                guard index < totalPages else { return }
                withAnimation(folderOpenAnimation) {
                    activeFolderPage = index
                }
            }

            Button {
                withAnimation(folderOpenAnimation) {
                    activeFolderPage = min(currentPage + 1, totalPages - 1)
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary.opacity(currentPage >= totalPages - 1 ? 0.35 : 0.8))
                    .frame(width: 28, height: 28)
            }
            .padding(.horizontal, pagerButtonHitPadding)
            .padding(.vertical, pagerButtonHitPadding)
            .frame(minWidth: pagerButtonHitSize, minHeight: pagerButtonHitSize)
            .contentShape(Rectangle().inset(by: -pagerButtonHitExpansion))
            .buttonStyle(.plain)
            .disabled(currentPage >= totalPages - 1)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    @ViewBuilder
    private func pagerDots(currentPage: Int, totalPages: Int, onSelect: ((Int) -> Void)? = nil) -> some View {
        HStack(spacing: 6) {
            let pageCount = max(totalPages, 1)
            ForEach(0..<pageCount, id: \.self) { index in
                let isDisabled = onSelect == nil || index >= totalPages
                Button {
                    onSelect?(index)
                } label: {
                    Circle()
                        .fill(index == currentPage ? Color.primary.opacity(0.9) : Color.primary.opacity(0.35))
                        .frame(width: 8, height: 8)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(isDisabled)
            }
        }
    }

    @ViewBuilder
    private func gridPager(canReorder: Bool, layout: LauncherLayoutMetrics) -> some View {
        let totalPages = pageCount
        let dotsTotal = max(totalPages, 1)
        let previousDisabled = currentPage == 0 || orderedItems.isEmpty
        let nextDisabled = orderedItems.isEmpty || currentPage >= totalPages - 1

        HStack(spacing: 12) {
            pagerChevronButton(
                systemName: "chevron.left",
                disabled: previousDisabled,
                canReorder: canReorder,
                targetPage: currentPage - 1,
                action: pageBackward
            )

            pagerDots(currentPage: min(currentPage, dotsTotal - 1), totalPages: dotsTotal) { index in
                jumpToPage(index)
            }

            pagerChevronButton(
                systemName: "chevron.right",
                disabled: nextDisabled,
                canReorder: canReorder,
                targetPage: currentPage + 1,
                action: pageForward
            )
        }
        .frame(maxWidth: .infinity)
        .padding(.top, layout.gridToPagerSpacing)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(pageIndicatorTitle)
    }

    @ViewBuilder
    private func pagerChevronButton(
        systemName: String,
        disabled: Bool,
        canReorder: Bool,
        targetPage: Int,
        action: @escaping () -> Void
    ) -> some View {
        let button = Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.primary.opacity(disabled ? 0.35 : 0.8))
                .frame(width: 28, height: 28)
        }
        .padding(.horizontal, pagerButtonHitPadding)
        .padding(.vertical, pagerButtonHitPadding)
        .frame(minWidth: pagerButtonHitSize, minHeight: pagerButtonHitSize)
        .contentShape(Rectangle().inset(by: -pagerButtonHitExpansion))
        .buttonStyle(.plain)
        .disabled(disabled)

        if canReorder {
            button.onDrop(
                of: [.text],
                delegate: PageReorderDropDelegate(
                    targetPage: targetPage,
                    pageCapacity: pageCapacity,
                    items: $orderedItems,
                    draggedItem: $draggedItem,
                    performReorder: { item, _ in
                        let index = pageDropInsertionIndex(for: targetPage)
                        return reorderItem(item, to: index, targetPageHint: targetPage)
                    },
                    afterReorder: updatePageAfterDrop(at:)
                )
            )
        } else {
            button
        }
    }

    /// Lays out the folder contents with a Launchpad-inspired grid that supports reordering.
    @ViewBuilder
    private func folderGrid(
        for folder: FolderItem,
        layout: LauncherLayoutMetrics,
        overlayLayout: FolderOverlayLayout,
        pageStartIndex: Int,
        pageApps: [AppItem]
    ) -> some View {
        let columnCount = max(1, overlayLayout.columns)
        let columns = Array(repeating: GridItem(.flexible(), spacing: overlayLayout.spacing, alignment: .center), count: columnCount)
        let tileSize = layout.iconDimension
        let gridInsets = overlayLayout.gridInsets

        GeometryReader { gridProxy in
            LazyVGrid(columns: columns, alignment: .center, spacing: overlayLayout.spacing) {
                ForEach(Array(pageApps.enumerated()), id: \.element.id) { offset, app in
                    let index = pageStartIndex + offset
                    let isLaunching = launchingItemID == app.id
                    let isRenaming = renamingAppID == app.id
                    let cell: AnyView = {
                        if isRenaming {
                            return AnyView(
                                editableAppCell(app: app, layout: layout, fontSize: 14)
                            )
                        }
                        return AnyView(
                            Button {
                                openItem(.app(app))
                            } label: {
                                VStack(spacing: 10) {
                                    iconView(for: .app(app), layout: layout)
                                        .frame(width: tileSize, height: tileSize)
                                        .scaleEffect(isLaunching ? 1.08 : 1.0)
                                        .opacity(isLaunching ? 0.4 : 1.0)
                                        .animation(.easeInOut(duration: 0.18), value: launchingItemID)
                                    Text(app.resolvedDisplayName)
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundColor(iconLabelColor())
                                        .lineLimit(2)
                                        .multilineTextAlignment(.center)
                                }
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity)
                                .scaleEffect(folderIconWaveToggle ? 1 : 0.9)
                                .opacity(folderIconWaveToggle ? 1 : 0.0)
                                .animation(
                                    folderOpenAnimation.delay(Double(index) * 0.025),
                                    value: folderIconWaveToggle
                                )
                            }
                            .buttonStyle(.plain)
                        )
                    }()

                    let decoratedCell = cell
                        .contextMenu {
                            itemContextMenu(for: .app(app))
                        }

                    if isRenaming == false {
                        decoratedCell
                            .onDrag {
                                folderDragContext = FolderDragContext(folderID: folder.id, app: app)
                                draggedFolderApp = app
                                draggedItem = .app(app)
                                return NSItemProvider(object: NSString(string: app.bundleIdentifier))
                            } preview: {
                                dragPreview(for: .app(app), layout: layout)
                            }
                    } else {
                        decoratedCell
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.leading, gridInsets.leading)
            .padding(.trailing, gridInsets.trailing)
            .padding(.top, gridInsets.top)
            .padding(.bottom, gridInsets.bottom)
            .onDrop(
                of: [.text],
                delegate: FolderReorderDropDelegate(
                    columns: columns.count,
                    spacing: overlayLayout.spacing,
                    gridSize: gridProxy.size,
                    pageStartIndex: pageStartIndex,
                    pageItemCount: pageApps.count,
                    draggedApp: $draggedFolderApp,
                    resolveDraggedApp: { currentDraggedApp() },
                    isAppInFolder: { app in
                        folder.apps.contains(app)
                    },
                    performReorder: { app, target in
                        reorderApp(app, inFolderWithID: folder.id, to: target)
                    },
                    insertApp: { app, target in
                        insertApp(app, intoFolderWithID: folder.id, at: target)
                    },
                    onDropEnded: {
                        folderDragContext = nil
                        draggedFolderApp = nil
                        draggedItem = nil
                    }
                )
            )
        }
        .animation(gridSpringAnimation, value: folder.apps)
        .frame(maxWidth: .infinity)
        .frame(height: overlayLayout.gridHeight)
    }

    /// Displays a blurred overlay showing a folder's contents with Launchpad-inspired styling.
    @ViewBuilder
    private func folderOverlay(for folder: FolderItem, layout: LauncherLayoutMetrics) -> some View {
        GeometryReader { proxy in
            let overlayLayout = folderOverlayLayout(for: folder, containerSize: proxy.size, layout: layout)
            ZStack {
                VisualEffectBackground(material: .hudWindow, blendingMode: .behindWindow)
                    .ignoresSafeArea()
                Color.black.opacity(0.35)
                    .ignoresSafeArea()

                let pages = folderPages(for: folder, overlayLayout: overlayLayout)
                let pageCount = max(pages.count, 1)
                let pageCapacity = max(overlayLayout.pageCapacity, 1)
                let currentPage = min(activeFolderPage, max(pageCount - 1, 0))
                let showPager = pageCount > 1

                VStack(spacing: overlayLayout.titleToGridSpacing) {
                    folderTitleView(for: folder)

                    ZStack {
                        if pages.isEmpty {
                            Color.clear.frame(height: overlayLayout.gridHeight)
                        } else {
                            ForEach(Array(pages.enumerated()), id: \.offset) { pageIndex, apps in
                                if pageIndex == currentPage {
                                    folderGrid(
                                        for: folder,
                                        layout: layout,
                                        overlayLayout: overlayLayout,
                                        pageStartIndex: pageIndex * pageCapacity,
                                        pageApps: apps
                                    )
                                    .transition(.opacity)
                                }
                            }
                        }
                    }
                    .frame(height: overlayLayout.gridHeight)

                    if showPager {
                        folderPager(currentPage: currentPage, totalPages: pageCount)
                    }
                }
                .padding(.top, overlayLayout.contentInsets.top)
                .padding(.bottom, overlayLayout.contentInsets.bottom)
                .padding(.leading, overlayLayout.contentInsets.leading)
                .padding(.trailing, overlayLayout.contentInsets.trailing)
                .frame(maxWidth: overlayLayout.cardWidth)
                .background(
                    VisualEffectBackground(material: .menu, blendingMode: .withinWindow)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.25))
                )
                .shadow(color: .black.opacity(0.3), radius: 24, y: 14)
                .anchorPreference(key: FolderFramePreference.self, value: .bounds) { anchor in
                    proxy[anchor]
                }
            }
            .onPreferenceChange(FolderFramePreference.self) { frame in
                activeFolderFrame = frame
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(folderOpenAnimation) {
                    activeFolder = nil
                }
            }
            .onDrop(
                of: [.text],
                delegate: FolderExitDropDelegate(
                    activeFrame: $activeFolderFrame,
                    onExitDrag: {
                        withAnimation(.easeInOut(duration: 0.12)) {
                            dragItemOutOfFolderIfNeeded()
                        }
                    }
                )
            )
            .transition(
                .asymmetric(
                    insertion: .scale(scale: 0.92).combined(with: .opacity),
                    removal: .scale(scale: 0.9).combined(with: .opacity)
                )
            )
            .animation(folderOpenAnimation, value: activeFolder?.id)
        }
    }

    /// Simple empty state shown when the grid has nothing to display.
    private func emptyState() -> some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 32, weight: .light))
                .foregroundColor(.secondary)
            Text(orderedItems.isEmpty ? String(localized: "No items found") : String(localized: "No matching items"))
                .font(.title3)
            if orderedItems.isEmpty == false && searchText.isEmpty == false {
                Text(String(localized: "Try a different search term."))
                    .foregroundStyle(.secondary)
            } else if orderedItems.isEmpty {
                Text(String(localized: "Launchy has not indexed any applications yet."))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Asks `NSWorkspace` to launch the tapped application and queues the close animation.
    private func openItem(_ item: LauncherItem) {
        guard isClosingLauncher == false else { return }

        switch item {
        case .folder(let folder):
            withAnimation(folderOpenAnimation) {
                activeFolder = folder
                folderIconWaveToggle = true
            }
            return
        case .app(let app):
            activeFolder = nil
            guard let bundleURL = app.bundleURL else { return }
            withAnimation(.easeInOut(duration: 0.18)) {
                launchingItemID = app.id
            }
            isClosingLauncher = true

            recordLaunchedApplication(app, runningApplication: nil)

            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { runningApp, _ in
                Task { @MainActor in
                    recordLaunchedApplication(app, runningApplication: runningApp)
                }
            }

            animateAndDismissLauncher()
        }
    }

    /// Fades the launcher window away before hiding it.
    private func animateAndDismissLauncher() {
        guard let window = hostingWindow() else {
            isClosingLauncher = false
            focusAfterLauncherDismisses()
            return
        }

        let contentView = window.contentView

        NSAnimationContext.runAnimationGroup { context in
            context.duration = closeAnimationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            window.animator().alphaValue = 0
            contentView?.animator().alphaValue = 0
        } completionHandler: {
            Task { @MainActor in
                window.orderOut(nil)
                window.alphaValue = 1
                contentView?.alphaValue = 1
                isClosingLauncher = false
                launchingItemID = nil
                focusAfterLauncherDismisses()
            }
        }
    }

    /// Informs the app delegate about the chosen launch target so it can restore focus appropriately.
    private func recordLaunchedApplication(_ app: AppItem, runningApplication: NSRunningApplication?) {
        guard let delegate = NSApp?.delegate as? LaunchyAppDelegate else { return }
        delegate.recordLaunchedApplication(bundleIdentifier: app.bundleIdentifier, application: runningApplication)
    }

    /// Asks the app delegate to foreground the right window after the launcher hides.
    private func focusAfterLauncherDismisses() {
        guard let delegate = NSApp?.delegate as? LaunchyAppDelegate else { return }
        delegate.focusPreferredApplicationAfterLauncherHides()
    }

    /// Returns the NSWindow currently hosting the launcher content, if any.
    private func hostingWindow() -> NSWindow? {
        if let primary = NSApp?.keyWindow ?? NSApp?.mainWindow,
           isLauncherHostingWindow(primary) {
            return primary
        }

        // Fall back to any window currently hosting this SwiftUI view when the panel is non-activating.
        if let hosting = NSApp?.windows.first(where: isLauncherHostingWindow) {
            return hosting
        }

        return nil
    }

    /// Identifies windows that are rendering the launcher content.
    private func isLauncherHostingWindow(_ window: NSWindow) -> Bool {
        if window.contentViewController is NSHostingController<LauncherView> {
            return true
        }

        return window.contentView is NSHostingView<LauncherView>
    }

    /// Moves to the previous page if possible.
    private func pageBackward() {
        guard pageCount > 0 else { return }
        withAnimation(pageSwitchAnimation) {
            pageDirection = .backward
            currentPage = max(currentPage - 1, 0)
            pagerDragOffset = 0
        }
    }

    /// Jumps directly to a target page and animates directionally.
    private func jumpToPage(_ targetPage: Int) {
        guard pageCount > 0 else { return }
        let bounded = min(max(targetPage, 0), pageCount - 1)
        guard bounded != currentPage else { return }
        withAnimation(pageSwitchAnimation) {
            pageDirection = bounded >= currentPage ? .forward : .backward
            currentPage = bounded
            pagerDragOffset = 0
        }
    }

    /// Moves to the next page if possible.
    private func pageForward() {
        guard pageCount > 0 else { return }
        withAnimation(pageSwitchAnimation) {
            pageDirection = .forward
            currentPage = min(currentPage + 1, pageCount - 1)
            pagerDragOffset = 0
        }
    }

    /// Hides the launcher when the blurred background is clicked.
    private func dismissLauncherViaBackgroundTap() {
        guard launcherMode == .fullscreen || launcherMode == .floaty else { return }
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
        case .standard:
            if launcherMode == .floaty {
                if colorScheme == .dark {
                    return AnyView(floatyStandardBlurBackground())
                } else {
                    return AnyView(lightBlurBackground())
                }
            } else {
                return AnyView(darkBlurBackground())
            }
        case .light:
            return AnyView(
                lightBlurBackground()
            )
        case .solid:
            return AnyView(Color(nsColor: solidBackgroundColor.nsColor))
        case .transparent:
            return AnyView(Color.clear)
        }
    }

    /// Darkens the floaty background with the same in-window HUD tint as the search bar.
    private func floatyStandardBlurBackground() -> VisualEffectBackground {
        blurBackground(
            material: .hudWindow,
            blendingMode: .withinWindow,
            preferredAppearance: .vibrantDark
        )
    }

    private func darkBlurBackground() -> VisualEffectBackground {
        blurBackground(material: .hudWindow, preferredAppearance: .vibrantDark)
    }

    private func lightBlurBackground() -> VisualEffectBackground {
        blurBackground(
            material: .menu,
            blendingMode: .withinWindow,
            preferredAppearance: .vibrantLight
        )
    }

    /// Helper for building a blurred background with optional appearance.
    private func blurBackground(
        material: NSVisualEffectView.Material,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow,
        preferredAppearance: NSAppearance.Name? = nil
    ) -> VisualEffectBackground {
        let appearance = preferredAppearance.flatMap { NSAppearance(named: $0) }
        return VisualEffectBackground(
            material: material,
            blendingMode: blendingMode,
            appearance: appearance
        )
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
        guard launcherMode == .fullscreen else { return 0 }
        guard containerHeight.isFinite else { return 0 }
        return max(0, containerHeight / 12)
    }

    /// Ensures the search field regains focus when the launcher window is foregrounded.
    private func focusSearchFieldIfAppropriate() {
        guard isEditingFolderName == false else { return }
        isSearchFieldFocused = true
    }

    /// Custom search field that mirrors the glassy Launchpad design.
    private func searchBar(layout: LauncherLayoutMetrics) -> some View {
        TextField("Search items", text: $searchText)
            .textFieldStyle(.plain)
            .font(.system(size: layout.searchBarFontSize, weight: .medium))
            .foregroundColor(searchBarForegroundColor())
            .focused($isSearchFieldFocused)
            .onSubmit {
                launchSearchResultIfPossible()
            }
            .padding(.leading, 18)
            .padding(.trailing, 44)
            .frame(height: layout.searchBarHeight)
            .background(
                searchBarBackgroundMaterial()
                    .clipShape(RoundedRectangle(cornerRadius: layout.searchBarCornerRadius, style: .continuous))
            )
            .overlay(alignment: .trailing) {
                if searchText.isEmpty == false {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(searchBarForegroundColor().opacity(0.55))
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
            .environment(\.colorScheme, searchBarColorSchemeOverride())
    }

    /// Chooses the right blur material for the search bar based on the selected background style.
    private func searchBarBackgroundMaterial() -> VisualEffectBackground {
        if usesDarkSearchBarAppearance {
            return VisualEffectBackground(
                material: .hudWindow,
                blendingMode: .withinWindow,
                appearance: NSAppearance(named: .vibrantDark)
            )
        } else {
            return VisualEffectBackground(material: .menu, blendingMode: .withinWindow)
        }
    }

    /// Adjusts the search bar text/icon color to remain legible on tinted backgrounds.
    private func searchBarForegroundColor() -> Color {
        usesDarkSearchBarAppearance ? .white : .primary
    }

    /// Overrides the color scheme locally so placeholder and accent colors match the background.
    private func searchBarColorSchemeOverride() -> ColorScheme {
        usesDarkSearchBarAppearance ? .dark : colorScheme
    }

    /// Whether the search bar should use the darker tinted style.
    private var usesDarkSearchBarAppearance: Bool {
        backgroundStylePreference == .standard || backgroundStylePreference == .transparent
    }

    /// Picks an icon label color that keeps adequate contrast against the selected background.
    private func iconLabelColor() -> Color {
        shouldUseLightIconText() ? Color.white : Color.black.opacity(0.9)
    }

    /// Heuristic to detect when light text will contrast better with the backdrop.
    private func shouldUseLightIconText() -> Bool {
        if activeFolder != nil {
            return true
        }

        switch backgroundStylePreference {
        case .standard:
            if launcherMode == .fullscreen {
                return true
            }
            return colorScheme == .dark
        case .light:
            return false
        case .solid:
            return solidBackgroundColor.nsColor.launchy_perceivedBrightness < 0.6
        case .transparent:
            return colorScheme == .dark
        }
    }

    /// Launches the first matched app when a user submits the search field.
    private func launchSearchResultIfPossible() {
        let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedQuery.isEmpty == false else { return }
        guard let firstMatch = filteredItemList.first(where: { item in
            if case .app = item { return true }
            return false
        }) else { return }
        openItem(firstMatch)
    }

    /// Context menu shown for each grid item.
    @ViewBuilder
    private func itemContextMenu(for item: LauncherItem) -> some View {
        Button("Open") {
            openItem(item)
        }

        switch item {
        case .app(let app):
            Button("App Details") {
                showItemDetails(item)
            }

            Button("Rename App") {
                beginAppRename(app)
            }

            Button("Show in Finder") {
                showInFinder(app)
            }
            .disabled(app.bundleURL == nil)

            Menu("Move to Folder") {
                folderMoveMenu(for: app)
            }

            Menu("Move to Page") {
                pageMoveMenu(for: .app(app))
            }

            Button("Hide App") {
                hideApp(app)
            }

            Button("Create Folder with App") {
                createFolder(from: app, promptForName: true)
            }
        case .folder(let folder):
            Button("Folder Details") {
                showItemDetails(item)
            }

            Button("Rename Folder") {
                beginFolderRename(folder)
            }

            Menu("Move to Page") {
                pageMoveMenu(for: .folder(folder))
            }
        }
    }

    /// Nested menu showing available folders for an app move.
    @ViewBuilder
    private func folderMoveMenu(for app: AppItem) -> some View {
        let folders = orderedItems.compactMap { item -> FolderItem? in
            if case let .folder(folder) = item { return folder }
            return nil
        }

        if folders.isEmpty {
            Button("No folders available") { }
                .disabled(true)
        } else {
            ForEach(folders, id: \.id) { folder in
                let folderTitle = folder.name.isEmpty ? FolderItem.defaultName : folder.name
                Button(folderTitle) {
                    moveApp(app, toFolderID: folder.id)
                }
                .disabled(isApp(app, inFolderWithID: folder.id))
            }
        }
    }

    /// Nested menu listing pages for quick jumps.
    @ViewBuilder
    private func pageMoveMenu(for item: LauncherItem) -> some View {
        let totalPages = max(fullPageCount, 1)
        let pageIndices = Array(0..<totalPages)
        ForEach(pageIndices, id: \.self) { pageIndex in
            let currentIndex = self.pageIndex(for: item)
            Button("Page \(pageIndex + 1)") {
                moveItem(item, toPage: pageIndex)
            }
            .disabled(currentIndex == pageIndex)
        }
    }

    /// Context menu for the empty grid background.
    @ViewBuilder
    private func backgroundContextMenu() -> some View {
        Button("Create Folder") {
            createEmptyFolder(onPage: currentPage, promptForName: true)
        }

        Button("Settings...") {
            Task { @MainActor in
                onSettingsRequested?()
            }
        }
    }

    /// Shows an alert with info about the selected item.
    private func showItemDetails(_ item: LauncherItem) {
        switch item {
        case .app(let app):
            showAppDetails(app)
        case .folder(let folder):
            showFolderDetails(folder)
        }
    }

    /// Displays bundle metadata in a quick info sheet.
    private func showAppDetails(_ app: AppItem) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = app.resolvedDisplayName

        var lines: [String] = [
            String(localized: "Bundle ID: \(app.bundleIdentifier)")
        ]
        if let url = app.bundleURL {
            lines.append(String(localized: "Location: \(url.path)"))
        }
        if let custom = sanitizedCustomName(app.customName ?? ""), custom.isEmpty == false {
            lines.append(String(localized: "Custom Name: \(custom)"))
        }

        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: String(localized: "OK"))
        presentModalAlert(alert)
    }

    /// Displays folder information and contained apps.
    private func showFolderDetails(_ folder: FolderItem) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = folder.name.isEmpty ? FolderItem.defaultName : folder.name
        let appList = folder.apps.map { "- \($0.resolvedDisplayName)" }.joined(separator: "\n")
        alert.informativeText = appList.isEmpty ? String(localized: "Folder is empty.") : String(localized: "Apps:\n\(appList)")
        alert.addButton(withTitle: String(localized: "OK"))
        presentModalAlert(alert)
    }

    /// Begins inline app renaming on the targeted item.
    private func beginAppRename(_ app: AppItem) {
        renamingAppID = app.id
        appNameDraft = sanitizedCustomName(app.customName ?? app.displayName) ?? app.displayName
        isEditingFolderName = false
        DispatchQueue.main.async {
            isAppNameFieldFocused = true
        }
    }

    /// Starts inline folder renaming by opening and focusing the overlay title.
    private func beginFolderRename(_ folder: FolderItem) {
        withAnimation(folderOpenAnimation) {
            activeFolder = folder
            folderIconWaveToggle = true
        }
        beginFolderNameEdit(for: folder)
    }

    /// Starts inline editing for the folder title displayed in the overlay.
    private func beginFolderNameEdit(for folder: FolderItem) {
        renamingAppID = nil
        folderNameDraft = folder.name.isEmpty ? FolderItem.defaultName : folder.name
        isEditingFolderName = true
        DispatchQueue.main.async {
            isFolderNameFieldFocused = true
        }
    }

    /// Commits the inline folder name edit and syncs it with the data model.
    private func commitFolderNameEdit(for folder: FolderItem) {
        let resolved = sanitizedFolderName(folderNameDraft)
        isEditingFolderName = false
        isFolderNameFieldFocused = false
        folderNameDraft = resolved
        if resolved != folder.name {
            applyFolderRename(folder, newName: resolved)
        }
    }

    /// Applies the pending app name draft and clears edit state.
    private func commitAppRename(_ app: AppItem) {
        let draft = appNameDraft
        resetAppRenameState()
        applyAppRename(app, newName: draft)
    }

    private func resetAppRenameState() {
        renamingAppID = nil
        isAppNameFieldFocused = false
        appNameDraft = ""
    }

    /// Saves a new custom app name into the arrangement.
    private func applyAppRename(_ app: AppItem, newName: String) {
        guard let location = locateApp(app) else { return }
        let trimmed = sanitizedCustomName(newName)

        var items = orderedItems
        switch location {
        case .root(let index):
            guard case var .app(existing) = items[index] else { return }
            existing.customName = trimmed
            items[index] = .app(existing)
        case .folder(let folderIndex, let appIndex):
            guard case var .folder(folder) = items[folderIndex] else { return }
            guard folder.apps.indices.contains(appIndex) else { return }
            folder.apps[appIndex].customName = trimmed
            items[folderIndex] = .folder(folder)
            if activeFolder?.id == folder.id {
                activeFolder = folder
            }
        }

        orderedItems = items
        persistOrderChange()
    }

    /// Saves an updated folder name.
    private func applyFolderRename(_ folder: FolderItem, newName: String) {
        let resolvedName = sanitizedFolderName(newName)
        guard let index = orderedItems.firstIndex(where: { item in
            if case let .folder(existing) = item {
                return existing.id == folder.id
            }
            return false
        }) else { return }

        guard case var .folder(existing) = orderedItems[index] else { return }
        existing.name = resolvedName

        updateFolder(existing, at: index)
    }

    /// Removes intentionally empty or whitespace-only names.
    private func sanitizedCustomName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Fallback-friendly folder naming helper.
    private func sanitizedFolderName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? FolderItem.defaultName : trimmed
    }

    /// Opens the selected bundle in Finder.
    private func showInFinder(_ app: AppItem) {
        guard let url = app.bundleURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Adds or updates a hidden app entry and removes it from the current grid.
    private func hideApp(_ app: AppItem) {
        var identifiers = Set(LauncherSettingsPersistence.hiddenBundleIdentifiers())
        let inserted = identifiers.insert(app.bundleIdentifier).inserted
        guard inserted else { return }
        LauncherSettingsPersistence.setHiddenBundleIdentifiers(Array(identifiers).sorted())

        if let removal = removeAppFromHierarchy(app) {
            withAnimation(gridSpringAnimation) {
                orderedItems = removal.items
            }
            persistOrderChange()
            currentPage = min(currentPage, fullPageCount - 1)
            pagerDragOffset = 0
        }
    }

    /// Moves an app into an existing folder.
    private func moveApp(_ app: AppItem, toFolderID folderID: UUID) {
        guard let removal = removeAppFromHierarchy(app) else { return }
        guard let folderIndex = removal.items.firstIndex(where: { item in
            if case let .folder(folder) = item {
                return folder.id == folderID
            }
            return false
        }) else { return }

        guard case var .folder(folder) = removal.items[folderIndex] else { return }
        guard folder.apps.contains(where: { $0.id == app.id }) == false else { return }

        var updated = removal.items
        folder.apps.append(removal.app)
        updated[folderIndex] = .folder(folder)
        withAnimation(gridSpringAnimation) {
            orderedItems = updated
        }
        currentPage = folderIndex / pageCapacity
        pagerDragOffset = 0
        if activeFolder?.id == folder.id {
            activeFolder = folder
        }
        persistOrderChange()
    }

    /// Moves an item (or app extracted from a folder) to a target page.
    private func moveItem(_ item: LauncherItem, toPage targetPage: Int) {
        var items = orderedItems
        let currentSizes = activePageSizes(for: items.count)
        let itemToInsert: LauncherItem
        var workingSizes = currentSizes

        switch item {
        case .app(let app):
            guard let removal = removeAppFromHierarchy(app) else { return }
            workingSizes = pageSizesAfterRemoval(currentSizes, removingIndex: removal.suggestedIndex, currentCount: items.count)
            items = removal.items
            itemToInsert = .app(removal.app)
        case .folder(let folder):
            guard let index = items.firstIndex(where: { entry in
                if case let .folder(existing) = entry {
                    return existing.id == folder.id
                }
                return false
            }) else { return }
            workingSizes = pageSizesAfterRemoval(currentSizes, removingIndex: index, currentCount: items.count)
            itemToInsert = items.remove(at: index)
        }

        let boundedPage = max(0, targetPage)
        if boundedPage >= workingSizes.count {
            workingSizes.append(contentsOf: Array(repeating: 0, count: boundedPage - workingSizes.count + 1))
        }
        let insertionIndex = insertionIndexForPage(boundedPage, sizes: workingSizes)
        items.insert(itemToInsert, at: insertionIndex)
        let finalSizes = pageSizesAfterInsertion(
            workingSizes,
            insertingIndex: insertionIndex,
            resultingCount: items.count,
            targetPageHint: boundedPage
        )
        withAnimation(gridSpringAnimation) {
            orderedItems = items
        }
        pageSizes = finalSizes
        let targetPage = min(boundedPage, max(finalSizes.count - 1, 0))
        withAnimation(pageSwitchAnimation) {
            pageDirection = targetPage >= currentPage ? .forward : .backward
            currentPage = targetPage
            pagerDragOffset = 0
        }
        persistOrderChange(using: finalSizes)
    }

    /// Inserts a launcher item at the end of the requested page slice.
    @discardableResult
    private func insert(_ item: LauncherItem, into items: inout [LauncherItem], atPage page: Int) -> [Int] {
        guard pageCapacity > 0 else {
            items.append(item)
            return activePageSizes(for: items.count)
        }

        var baseSizes = activePageSizes(for: items.count)
        if page >= baseSizes.count {
            baseSizes.append(contentsOf: Array(repeating: 0, count: page - baseSizes.count + 1))
        }
        let insertionIndex = insertionIndexForPage(page, sizes: baseSizes)
        items.insert(item, at: insertionIndex)
        return pageSizesAfterInsertion(
            baseSizes,
            insertingIndex: insertionIndex,
            resultingCount: items.count,
            targetPageHint: page
        )
    }

    /// Builds the page index for the selected item irrespective of search filters.
    private func pageIndex(for item: LauncherItem) -> Int? {
        let sizes = activePageSizes(for: orderedItems.count)
        switch item {
        case .app(let app):
            guard let location = locateApp(app) else { return nil }
            switch location {
            case .root(let index):
                return pageIndex(forLinearIndex: index, sizes: sizes)
            case .folder(let folderIndex, _):
                return pageIndex(forLinearIndex: folderIndex, sizes: sizes)
            }
        case .folder(let folder):
            guard let index = orderedItems.firstIndex(where: { entry in
                if case let .folder(existing) = entry {
                    return existing.id == folder.id
                }
                return false
            }) else { return nil }
            return pageIndex(forLinearIndex: index, sizes: sizes)
        }
    }

    /// Returns the location of an app in the overall arrangement.
    private func locateApp(_ app: AppItem) -> AppLocation? {
        for (index, item) in orderedItems.enumerated() {
            switch item {
            case .app(let candidate) where candidate.id == app.id:
                return .root(index: index)
            case .folder(let folder):
                if let appIndex = folder.apps.firstIndex(where: { $0.id == app.id }) {
                    return .folder(folderIndex: index, appIndex: appIndex)
                }
            default:
                continue
            }
        }
        return nil
    }

    /// Removes an app from either the root list or a folder.
    private func removeAppFromHierarchy(_ app: AppItem) -> RemovedAppContext? {
        guard let location = locateApp(app) else { return nil }
        let currentSizes = activePageSizes(for: orderedItems.count)
        var items = orderedItems

        switch location {
        case .root(let index):
            guard case let .app(existing) = items.remove(at: index) else { return nil }
            pageSizes = pageSizesAfterRemoval(currentSizes, removingIndex: index, currentCount: orderedItems.count)
            return RemovedAppContext(items: items, app: existing, suggestedIndex: index)
        case .folder(let folderIndex, let appIndex):
            guard case var .folder(folder) = items[folderIndex] else { return nil }
            guard folder.apps.indices.contains(appIndex) else { return nil }
            let removedApp = folder.apps.remove(at: appIndex)
            items.remove(at: folderIndex)

            var insertionIndex = folderIndex
            if folder.apps.isEmpty == false {
                items.insert(.folder(folder), at: folderIndex)
                insertionIndex = folderIndex + 1
                if activeFolder?.id == folder.id {
                    activeFolder = folder
                }
                return RemovedAppContext(items: items, app: removedApp, suggestedIndex: insertionIndex)
            } else if activeFolder?.id == folder.id {
                activeFolder = nil
            }

            pageSizes = pageSizesAfterRemoval(currentSizes, removingIndex: folderIndex, currentCount: orderedItems.count)
            return RemovedAppContext(items: items, app: removedApp, suggestedIndex: insertionIndex)
        }
    }

    /// Creates a folder with the provided app moved inside it.
    private func createFolder(from app: AppItem, promptForName: Bool) {
        guard let removal = removeAppFromHierarchy(app) else { return }
        var items = removal.items
        let newFolder = FolderItem(apps: [removal.app])
        let insertionIndex = min(removal.suggestedIndex, items.count)
        items.insert(.folder(newFolder), at: insertionIndex)
        orderedItems = items
        activeFolder = newFolder
        let baseSizes = activePageSizes(for: removal.items.count)
        let updatedSizes = pageSizesAfterInsertion(
            baseSizes,
            insertingIndex: insertionIndex,
            resultingCount: items.count
        )
        pageSizes = updatedSizes
        persistOrderChange(using: updatedSizes)

        guard promptForName else { return }
        beginFolderRename(newFolder)
    }

    /// Creates an empty folder at the start of the current page.
    private func createEmptyFolder(onPage pageIndex: Int, promptForName: Bool) {
        var items = orderedItems
        let folder = FolderItem(apps: [])
        let updatedSizes = insert(.folder(folder), into: &items, atPage: pageIndex)
        orderedItems = items
        pageSizes = updatedSizes
        persistOrderChange(using: updatedSizes)

        guard promptForName else { return }
        beginFolderRename(folder)
    }

    /// Returns true when an app already lives inside the specified folder.
    private func isApp(_ app: AppItem, inFolderWithID folderID: UUID) -> Bool {
        guard let location = locateApp(app) else { return false }
        if case .folder(let folderIndex, _) = location,
           case let .folder(folder) = orderedItems[folderIndex] {
            return folder.id == folderID
        }
        return false
    }

    @discardableResult
    private func presentModalAlert(_ alert: NSAlert) -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        let alertWindow = alert.window
        alertWindow.level = .statusBar
        alertWindow.collectionBehavior.insert([.moveToActiveSpace, .fullScreenAuxiliary, .canJoinAllSpaces])
        alertWindow.makeKeyAndOrderFront(nil)
        alertWindow.orderFrontRegardless()

        let response = alert.runModal()

        hostingWindow()?.makeKeyAndOrderFront(nil)

        return response
    }
}

#Preview {
    LauncherView(
        itemCatalog: [
            .app(AppItem(id: UUID(), displayName: "Safari", bundleIdentifier: "com.apple.Safari", iconImage: NSImage(named: NSImage.networkName), bundleURL: nil)),
            .app(AppItem(id: UUID(), displayName: "Xcode", bundleIdentifier: "com.apple.dt.Xcode", iconImage: nil, bundleURL: nil)),
            .folder(FolderItem(name: FolderItem.defaultName, apps: [
                AppItem(id: UUID(), displayName: "Notes", bundleIdentifier: "com.apple.Notes", iconImage: nil, bundleURL: nil),
                AppItem(id: UUID(), displayName: "Mail", bundleIdentifier: "com.apple.mail", iconImage: nil, bundleURL: nil)
            ]))
        ],
        backgroundStylePreference: .standard
    )
}

private struct FolderFramePreference: PreferenceKey {
    static let defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

private extension NSColor {
    /// Perceived brightness used to decide if a foreground color needs to flip.
    var launchy_perceivedBrightness: CGFloat {
        guard let rgb = usingColorSpace(.extendedSRGB) else {
            return 1.0
        }
        return (0.299 * rgb.redComponent) + (0.587 * rgb.greenComponent) + (0.114 * rgb.blueComponent)
    }
}
