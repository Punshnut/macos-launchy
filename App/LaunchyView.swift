import SwiftUI
import AppKit
import os

extension Notification.Name {
    /// Informs the launcher view that the search bar should regain focus after a mode switch.
    static let launcherShouldRefocusSearch = Notification.Name("launchyLauncherShouldRefocusSearch")
    /// Triggers the fullscreen grid fly-in animation when the launcher appears.
    static let launcherShouldAnimateGridEntrance = Notification.Name("launchyLauncherShouldAnimateGridEntrance")
    /// Carries a printable character typed before the search field was ready to accept input.
    static let launcherTypeAheadInput = Notification.Name("launchyLauncherTypeAheadInput")
    /// Indicates the launcher window became visible.
    static let launcherDidShow = Notification.Name("launchyLauncherDidShow")
    /// Indicates the launcher window was fully hidden.
    static let launcherDidHide = Notification.Name("launchyLauncherDidHide")
    /// Requests a lightweight visual cache purge under memory pressure.
    static let launcherShouldPurgeVisualCaches = Notification.Name("launchyLauncherShouldPurgeVisualCaches")
}

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

private enum PagerInteractionSource {
    case drag
    case scroll
}

private struct PendingPagerAnimationFinalization: Equatable {
    let logicalPage: Int?
    let terminalOffset: CGFloat
}

private struct RemovedAppContext {
    var items: [LauncherItem]
    var app: AppItem
    var suggestedIndex: Int
    var removedRootItem: Bool
    var pageSizesAfterRemoval: [Int]
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

private struct PageInsertionOption: Identifiable {
    let insertionIndex: Int
    let title: String

    var id: Int { insertionIndex }
}

private struct SearchableAppEntry {
    let normalizedNames: [String]
    let tokenizedNames: [[String]]
    let initialisms: [String]
    let normalizedBundleIdentifier: String
}

private struct SearchableFolderEntry {
    let normalizedNames: [String]
}

private struct SearchQueryContext {
    let rawQuery: String
    let trimmedQuery: String
    let normalizedQuery: String
    let queryVariants: [String]
    let tokenVariants: [[String]]

    init(rawQuery: String) {
        self.rawQuery = rawQuery
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        trimmedQuery = trimmed
        if trimmed.isEmpty {
            normalizedQuery = ""
            queryVariants = []
            tokenVariants = []
        } else {
            queryVariants = LauncherView.normalizedSearchVariants(for: trimmed)
            tokenVariants = queryVariants.map { LauncherView.tokenizeSearchValue($0) }
            normalizedQuery = LauncherView.primarySearchCacheKey(for: trimmed)
        }
    }

    var isEmpty: Bool { trimmedQuery.isEmpty }
}

/// Thread-safe cache for rendered folder preview icons so drag animations stay smooth.
private final class FolderPreviewCache: @unchecked Sendable {
    private let cache: NSCache<NSString, NSImage>
    private let lock = NSLock()
    private var warmupTokens: Set<String> = []

    init() {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 120
        cache.totalCostLimit = 18 * 1024 * 1024
        self.cache = cache
    }

    /// Applies cache size constraints derived from runtime performance tuning.
    func applyLimits(countLimit: Int, totalCostLimit: Int) {
        cache.countLimit = countLimit
        cache.totalCostLimit = totalCostLimit
    }

    /// Builds deterministic cache key for app preview icon variant.
    func cacheKey(
        for app: AppItem,
        dimension: CGFloat,
        quality: IconRenderQuality,
        appearanceToken: String
    ) -> String {
        let rounded = Int(dimension.rounded())
        return "\(app.bundleIdentifier)|\(rounded)|\(quality.rawValue)|\(appearanceToken)"
    }

    /// Reads cached preview icon for key if available.
    func cachedIcon(for key: String) -> NSImage? {
        cache.object(forKey: key as NSString)
    }

    /// Stores preview icon with a lightweight pixel-based cost estimate.
    func store(_ icon: NSImage, for key: String) {
        let cost = Int(icon.size.width * icon.size.height) * 4
        cache.setObject(icon, forKey: key as NSString, cost: cost)
    }

    /// Marks a warmup token as in-progress and returns false when already running.
    func beginWarmupIfNeeded(token: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if warmupTokens.contains(token) {
            return false
        }
        warmupTokens.insert(token)
        return true
    }

    /// Clears warmup token once asynchronous prewarm pass finishes.
    func finishWarmup(token: String) {
        lock.lock()
        warmupTokens.remove(token)
        lock.unlock()
    }

    /// Clears all cached preview icons and warmup bookkeeping.
    func purge() {
        cache.removeAllObjects()
        lock.lock()
        warmupTokens.removeAll()
        lock.unlock()
    }
}

private struct WiggleSeed {
    let phase: Double
    let intensity: Double
    let rate: Double
}

private struct WiggleMotion: ViewModifier {
    let seed: WiggleSeed
    let isActive: Bool
    let cycle: TimeInterval
    let rotationDegrees: Double
    let sway: CGFloat
    let bob: CGFloat
    let anchor: UnitPoint

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder
    /// Applies deterministic wiggle transform while active.
    func body(content: Content) -> some View {
        if isActive, reduceMotion == false {
            TimelineView(.periodic(from: .now, by: 1.0 / 60.0)) { context in
                let time = context.date.timeIntervalSinceReferenceDate
                let normalized = time * seed.rate / cycle
                let basePhase = normalized * 2 * .pi + seed.phase
                let rotation = sin(basePhase) * rotationDegrees * seed.intensity
                let horizontal = sin(basePhase + .pi / 5) * Double(sway) * seed.intensity
                let vertical = cos(basePhase * 1.32 + .pi / 4) * Double(bob) * (0.7 + 0.3 * seed.intensity)

                content
                    .rotationEffect(.degrees(rotation), anchor: anchor)
                    .offset(x: CGFloat(horizontal), y: CGFloat(vertical))
            }
        } else {
            content
        }
    }
}

private struct ArrangementEffect: Equatable {
    let scale: CGFloat
    let offset: CGFloat
    let shadowOpacity: Double
    let shadowRadius: CGFloat
    let shadowYOffset: CGFloat
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
    /// Grid sizing for the current launcher mode.
    var gridConfiguration: LauncherGridConfiguration = LauncherGridConfiguration.configuration(for: .small, mode: .floaty)
    /// Orientation used when paging between grids.
    var pagingOrientation: PagingOrientation = .horizontal
    /// Whether items should collapse upward to fill earlier gaps.
    var fillsGapsAutomatically: Bool = true
    /// Callback fired when the user requests to open settings from a context menu.
    var onToggleLauncherModeRequested: (() -> Void)?
    var onSettingsRequested: (() -> Void)?
    /// Callback fired when the user requests app info/about.
    var onAppInfoRequested: (() -> Void)?
    /// Callback fired whenever the user changes the arrangement.
    var onItemOrderChange: (([LauncherItem], [Int]) -> Void)?
    /// Callback fired when the visible pages change so icons can be preheated.
    var onVisiblePagesChanged: (([AppItem]) -> Void)?
    /// Callback fired before a page switch to prewarm likely icon work.
    var onPageSwitchPrewarm: (([AppItem]) -> Void)?
    /// Provides the icon that should be for a specific app.
    var iconProvider: @Sendable (AppItem, CGFloat, IconRenderQuality, CGFloat) -> NSImage? = { app, _, _, _ in app.iconImage }

    private var pageCapacity: Int { gridConfiguration.pageCapacity }
    private let closeAnimationDuration: TimeInterval = 0.25
    private let wiggleCycleDuration: TimeInterval = 0.58
    private let wiggleRotationDegrees: Double = 1.65
    private let wiggleHorizontalSwayFactor: CGFloat = 0.018
    private let wiggleVerticalBobFactor: CGFloat = 0.0085
    private let wiggleAnchor = UnitPoint(x: 0.5, y: 0.2)
    private var fullscreenGridEntranceScale: CGFloat {
        guard launcherMode == .fullscreen else { return 1 }
        return 0.95 + 0.05 * CGFloat(fullscreenGridEntranceProgress)
    }
    private var isVerticalPaging: Bool { pagingOrientation == .vertical }

    /// Calculates the folder overlay's horizontal translation, clamping it within the available pages.
    private func folderGridTranslation(pageWidth: CGFloat, totalPages: Int, basePageOffset: CGFloat) -> CGFloat {
        guard totalPages > 0 else { return basePageOffset }
        let maxScroll = CGFloat(max(totalPages - 1, 0)) * pageWidth
        let minTranslation = min(0, -maxScroll)
        let rawTranslation = basePageOffset + folderPagerDragOffset
        return pixelAlign(min(max(rawTranslation, minTranslation), 0))
    }

    /// Builds the main grid layer with pager overlays and empty-state handling.
    @ViewBuilder
    private func launcherGridLayer(layout: LauncherLayoutMetrics, canReorder: Bool) -> some View {
        ZStack {
            if filteredItemList.isEmpty {
                emptyState()
                    .frame(maxWidth: .infinity, minHeight: layout.gridHeight)
                    .contextMenu {
                        backgroundContextMenu()
                    }
            } else {
                GeometryReader { gridProxy in
                    launcherGridPages(layout: layout, canReorder: canReorder, gridProxy: gridProxy)
                }
            }

            ScrollWheelPagerOverlay(
                isEnabled: isGesturePagingEnabled,
                pagingOrientation: pagingOrientation,
                onScrollProgress: { event in
                    handleScrollProgress(event)
                },
                onScrollEnd: {
                    endScrollGesture(pageSpan: pagerViewportWidth)
                },
                onPreviousPage: { pageBackward() },
                onNextPage: { pageForward() }
            )
            .frame(maxWidth: .infinity, minHeight: layout.gridHeight)
            .allowsHitTesting(false)

            KeyPressPagerOverlay(
                isEnabled: isKeyboardPagingEnabled || isRenamingItem || shouldHandleEscapeKeys,
                shouldCaptureArrowKeys: { shouldCaptureArrowKeys },
                shouldHandleEscape: { shouldHandleEscapeKeys },
                onPreviousPage: { handleKeyboardPager(.backward) },
                onNextPage: { handleKeyboardPager(.forward) },
                onEscape: { handleEscapeKeyPress() },
                onPageShortcut: { handlePageShortcutRequest($0) },
                onVerticalNavigation: { handleVerticalNavigation($0) }
            )
            .frame(maxWidth: .infinity, minHeight: layout.gridHeight)
            .allowsHitTesting(false)
        }
        .scaleEffect(fullscreenGridEntranceScale, anchor: .center)
        .opacity(fullscreenGridEntranceOpacity)
        .saturation(fullscreenGridEntranceSaturation)
        .offset(y: fullscreenGridEntranceOffset)
        .padding(.top, layout.gridVerticalOffset)
    }

    /// Renders paged grid content and wires drag/drop state for each page.
    @ViewBuilder
    private func launcherGridPages(
        layout: LauncherLayoutMetrics,
        canReorder: Bool,
        gridProxy: GeometryProxy
    ) -> some View {
        let pageWidth = max(gridProxy.size.width, 1)
        let pageSpan = isVerticalPaging ? max(gridProxy.size.height, 1) : pageWidth
        let sizes = displayPageSizes
        let totalPages = max(sizes.count, 1)
        let pageIndices = visiblePageIndices(total: totalPages)
        let isTransitioning = isPagerTransitionActive
        let transitionPages = Set(pageIndices)

        let dragGesture = DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard isGesturePagingEnabled else { return }
                beginPagerInteraction(pageSpan: pageSpan)
                lastPagerInteractionSource = .drag
                lastPagerDragDate = Date()
                let translation = isVerticalPaging ? value.translation.height : value.translation.width
                pagerDragOffset = clampPagerOffset(
                    translation,
                    pageSpan: pageSpan
                )
            }
            .onEnded { value in
                guard isGesturePagingEnabled else { return }
                let translation = isVerticalPaging ? value.translation.height : value.translation.width
                let predicted = isVerticalPaging ? value.predictedEndTranslation.height : value.predictedEndTranslation.width
                finishPagerInteraction(
                    translation: translation,
                    predictedEndTranslation: predicted,
                    pageSpan: pageSpan
                )
            }

        ZStack(alignment: .leading) {
            ForEach(pageIndices, id: \.self) { pageIndex in
                let pageItems = itemsForPage(pageIndex, sizes: sizes)
                let pageStart = pageStartIndex(for: pageIndex, sizes: sizes)
                let itemCountOnPage = sizes.indices.contains(pageIndex) ? sizes[pageIndex] : 0
                let allowHeavyWork = isTransitioning ? transitionPages.contains(pageIndex) : true

                launcherGridPage(
                    layout: layout,
                    pageIndex: pageIndex,
                    pageWidth: pageWidth,
                    pageItems: pageItems,
                    pageStart: pageStart,
                    itemCountOnPage: itemCountOnPage,
                    canReorder: canReorder,
                    gridProxy: gridProxy,
                    allowHeavyWork: allowHeavyWork
                )
                .opacity(pageOpacity(for: pageIndex, pageSpan: pageSpan))
                .scaleEffect(pageScale(for: pageIndex, pageSpan: pageSpan))
                .offset(
                    x: isVerticalPaging ? 0 : pageOffset(for: pageIndex, pageSpan: pageSpan),
                    y: isVerticalPaging ? pageOffset(for: pageIndex, pageSpan: pageSpan) : 0
                )
            }
        }
        .frame(width: pageWidth, height: layout.gridHeight, alignment: .leading)
        .gesture(dragGesture)
        .animation(activeGridAnimation, value: orderedItems)
        .onAppear {
            let transaction = Transaction(animation: nil)
            withTransaction(transaction) {
                updatePagerViewport(using: gridProxy.size)
            }
            beginFirstPageRenderIfNeeded()
            lastKnownIconDimension = layout.iconDimension
        }
        .onChange(of: gridProxy.size) { newSize in
            let transaction = Transaction(animation: nil)
            withTransaction(transaction) {
                updatePagerViewport(using: newSize)
            }
        }
        .onChange(of: layout.iconDimension) { lastKnownIconDimension = $0 }
    }

    /// Persists the latest grid size and updates the pager span for the active orientation.
    private func updatePagerViewport(using size: CGSize) {
        lastGridViewportSize = size
        pagerViewportWidth = computedPagerSpan(from: size)
    }

    /// Computes the effective page span for the current paging orientation.
    private func computedPagerSpan(from size: CGSize) -> CGFloat {
        let span = isVerticalPaging ? size.height : size.width
        return max(span, 1)
    }

    private var usesCoherentVerticalPagingRenderer: Bool {
        isVerticalPaging
    }

    @ViewBuilder
    private func pageRenderingWrapper<Content: View>(_ content: Content) -> some View {
        content.compositingGroup()
    }

    @ViewBuilder
    private func dragEdgePagingOverlay(canReorder: Bool) -> some View {
        let isEnabled = canReorder && isDragEdgePagingEnabled

        HStack(spacing: 0) {
            dragEdgePagingZone(pageDelta: -1, isEnabled: isEnabled)
            Spacer(minLength: 0)
            dragEdgePagingZone(pageDelta: 1, isEnabled: isEnabled)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(isEnabled)
    }

    @ViewBuilder
    private func dragEdgePagingZone(pageDelta: Int, isEnabled: Bool) -> some View {
        Color.clear
            .frame(width: dragEdgePagingZoneWidth)
            .contentShape(Rectangle())
            .onDrop(
                of: [.text],
                delegate: EdgePagingDropDelegate(
                    pageDelta: pageDelta,
                    isEnabled: { isEnabled },
                    onHoverChange: updateDragEdgePaging(for:),
                    onPerformDrop: { delta in
                        performDragEdgeDrop(pageDelta: delta)
                    }
                )
            )
    }

    /// Renders one launcher page and configures per-page drop targets.
    @ViewBuilder
    private func launcherGridPage(
        layout: LauncherLayoutMetrics,
        pageIndex: Int,
        pageWidth: CGFloat,
        pageItems: [LauncherItem],
        pageStart: Int,
        itemCountOnPage: Int,
        canReorder: Bool,
        gridProxy: GeometryProxy,
        allowHeavyWork: Bool
    ) -> some View {
        let grid = launcherGridPageContent(
            layout: layout,
            pageWidth: pageWidth,
            pageItems: pageItems,
            pageStart: pageStart,
            canReorder: canReorder,
            allowHeavyWork: allowHeavyWork
        )
        .transaction { transaction in
            if transaction.animation == nil {
                transaction.animation = activeGridAnimation
            }
        }
        .frame(width: pageWidth, height: layout.gridHeight, alignment: .top)
        .contentShape(Rectangle())
        .contextMenu {
            backgroundContextMenu()
        }
        .onAppear {
            recordFirstPageRenderIfNeeded()
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
                dragModifierMode: { currentDragModifierMode() },
                performReorder: { item, targetIndex, preferSwap in
                    pendingDropPage = pageIndex
                    return reorderItem(
                        item,
                        to: targetIndex,
                        preferSwap: preferSwap,
                        targetPageHint: pageIndex
                    )
                },
                afterReorder: updatePageAfterDrop(at:),
                performFolderDrop: { dragged, target in
                    if dragged.count == 1, let single = dragged.first {
                        mergeItemsIfNeeded(dragged: single, onto: target)
                    } else {
                        mergeMultiSelection(into: target)
                    }
                },
                isMultiSelectionDragActive: { isMultiSelectionDragActive },
                multiSelectionItems: { selectedLauncherItems },
                onFolderHoverExit: cancelFolderHover,
                onFolderSnapPreviewChange: { previewID in
                    folderSnapPreviewTargetID = previewID
                },
                lastLiveReorderTargetIndex: $lastLiveReorderTargetIndex,
                dragReferenceItems: { dragOriginItemsSnapshot ?? orderedItems },
                consumePendingModifierPreviewReset: {
                    let shouldConsume = pendingModifierPreviewReset
                    pendingModifierPreviewReset = false
                    return shouldConsume
                },
                restoreDraggedLayoutSnapshot: restoreDraggedLayoutSnapshot,
                performLiveSwapPreview: { item, targetIndex in
                    previewSwapItem(
                        item,
                        to: targetIndex,
                        animation: liveReorderSpringAnimation
                    )
                },
                performLiveReorder: { item, targetIndex, preferSwap in
                    reorderItem(
                        item,
                        to: targetIndex,
                        preferSwap: preferSwap,
                        animated: true,
                        animation: liveReorderSpringAnimation
                    )
                },
                onModifierStateChange: handleDragModifierChange
            )
        )

        pageRenderingWrapper(grid)
    }

    @ViewBuilder
    private func launcherGridPageContent(
        layout: LauncherLayoutMetrics,
        pageWidth: CGFloat,
        pageItems: [LauncherItem],
        pageStart: Int,
        canReorder: Bool,
        allowHeavyWork: Bool
    ) -> some View {
        if usesCoherentVerticalPagingRenderer {
            let columnCount = max(layout.columnsPerPage, 1)
            let rowCount = max(layout.rowsPerPage, 1)
            let horizontalSpacing = layout.iconSpacing
            let verticalSpacing = layout.iconSpacing
            let cellWidth = max(
                (pageWidth - horizontalSpacing * CGFloat(max(columnCount - 1, 0))) / CGFloat(columnCount),
                0
            )
            let cellHeight = max(
                (layout.gridHeight - verticalSpacing * CGFloat(max(rowCount - 1, 0))) / CGFloat(rowCount),
                0
            )

            VStack(alignment: .center, spacing: verticalSpacing) {
                ForEach(0..<rowCount, id: \.self) { rowIndex in
                    HStack(alignment: .top, spacing: horizontalSpacing) {
                        ForEach(0..<columnCount, id: \.self) { columnIndex in
                            let localIndex = rowIndex * columnCount + columnIndex

                            if pageItems.indices.contains(localIndex) {
                                launcherGridPageItem(
                                    pageItems[localIndex],
                                    localIndex: localIndex,
                                    pageStart: pageStart,
                                    layout: layout,
                                    canReorder: canReorder,
                                    allowHeavyWork: allowHeavyWork
                                )
                                .frame(width: cellWidth, height: cellHeight, alignment: .top)
                            } else {
                                Color.clear
                                    .frame(width: cellWidth, height: cellHeight)
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                    .frame(height: cellHeight, alignment: .top)
                }
            }
        } else {
            LazyVGrid(
                columns: layout.gridColumns,
                alignment: .center,
                spacing: layout.iconSpacing
            ) {
                ForEach(Array(pageItems.enumerated()), id: \.element.id) { localIndex, item in
                    launcherGridPageItem(
                        item,
                        localIndex: localIndex,
                        pageStart: pageStart,
                        layout: layout,
                        canReorder: canReorder,
                        allowHeavyWork: allowHeavyWork
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func launcherGridPageItem(
        _ item: LauncherItem,
        localIndex: Int,
        pageStart: Int,
        layout: LauncherLayoutMetrics,
        canReorder: Bool,
        allowHeavyWork: Bool
    ) -> some View {
        let globalIndex = pageStart + localIndex
        let isLaunching = launchingItemID == item.id
        let isFolderBeingOpened = activeFolder?.id == item.id
        let isRenamingApp = renamingAppID == item.id
        let shouldShowSearchSelection = isRenamingApp == false && isSearchResultSelected(item: item, globalIndex: globalIndex)

        let cell = launcherGridCellContent(
            item: item,
            layout: layout,
            isLaunching: isLaunching,
            isFolderBeingOpened: isFolderBeingOpened,
            isRenamingApp: isRenamingApp,
            allowHeavyWork: allowHeavyWork
        )

        let decoratedCell = cell
            .background(alignment: .center) {
                if shouldShowSearchSelection {
                    searchSelectionTile(layout: layout)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .contentShape(Rectangle())
            .contextMenu {
                itemContextMenu(for: item)
            }

        let liftEffect = shouldRasterizeGridPages
            ? ArrangementEffect(scale: 1, offset: 0, shadowOpacity: 0, shadowRadius: 0, shadowYOffset: 0)
            : gridArrangementEffect(for: item)
        let animatedCell = decoratedCell
            .scaleEffect(liftEffect.scale)
            .offset(y: liftEffect.offset)
            .shadow(
                color: Color.black.opacity(liftEffect.shadowOpacity),
                radius: liftEffect.shadowRadius,
                y: liftEffect.shadowYOffset
            )
            .animation(reorderLiftAnimation, value: liftEffect)

        if canReorder && isRenamingApp == false {
            if shouldStartMultiSelectionDrag(for: item) {
                animatedCell
                    .onDrag {
                        enterPerformanceShedding(duration: 0.6)
                        draggedItem = item
                        captureDragOrigin(for: item)
                        isPerformingMultiSelectionDrag = true
                        return NSItemProvider(object: NSString(string: item.id.uuidString))
                    } preview: {
                        multiSelectionDragPreview(layout: layout)
                    }
            } else {
                animatedCell
                    .onDrag {
                        enterPerformanceShedding(duration: 0.6)
                        draggedItem = item
                        captureDragOrigin(for: item)
                        return NSItemProvider(object: NSString(string: item.id.uuidString))
                    } preview: {
                        dragPreview(for: item, layout: layout)
                    }
            }
        } else {
            animatedCell
        }
    }

    @ViewBuilder
    /// Produces visual content for a grid cell (app or folder) including selection/drag affordances.
    private func launcherGridCellContent(
        item: LauncherItem,
        layout: LauncherLayoutMetrics,
        isLaunching: Bool,
        isFolderBeingOpened: Bool,
        isRenamingApp: Bool,
        allowHeavyWork: Bool
    ) -> some View {
        // Performance guardrail: keep this as a concrete view (avoid AnyView) to preserve diffing.
        if isRenamingApp, case let .app(app) = item {
            editableAppCell(app: app, layout: layout)
        } else {
            Button {
                if isMultiSelectModeActive {
                    toggleSelection(for: item)
                } else {
                    openItem(item)
                }
            } label: {
                VStack(spacing: 10) {
                    iconCell(for: item, layout: layout, allowHeavyWork: allowHeavyWork)
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
        }
    }

    private var fullscreenGridEntranceOpacity: Double {
        guard launcherMode == .fullscreen else { return 1 }
        return fullscreenGridEntranceProgress
    }

    private var fullscreenGridEntranceSaturation: Double {
        guard launcherMode == .fullscreen else { return 1 }
        return 0.72 + 0.28 * fullscreenGridEntranceProgress
    }

    private var fullscreenGridEntranceOffset: CGFloat {
        guard launcherMode == .fullscreen else { return 0 }
        return pixelAlign((1 - CGFloat(fullscreenGridEntranceProgress)) * fullscreenGridEntranceTranslation)
    }

    private static let performanceLog = OSLog(
        subsystem: Bundle.main.bundleIdentifier ?? "com.launchy",
        category: "Performance"
    )

    /// Starts a debug-only signpost span and returns its identifier.
    private nonisolated static func beginSignpost(_ name: StaticString) -> OSSignpostID {
        #if DEBUG
        let id = OSSignpostID(log: performanceLog)
        os_signpost(.begin, log: performanceLog, name: name, signpostID: id)
        return id
        #else
        return OSSignpostID.invalid
        #endif
    }

    /// Ends a previously started debug signpost span.
    private nonisolated static func endSignpost(_ name: StaticString, id: OSSignpostID) {
        #if DEBUG
        guard id != .invalid else { return }
        os_signpost(.end, log: performanceLog, name: name, signpostID: id)
        #endif
    }

    private let gridSpringAnimation = Animation.spring(response: 0.42, dampingFraction: 0.86, blendDuration: 0.12)
    private let liveReorderSpringAnimation = Animation.interactiveSpring(response: 0.2, dampingFraction: 0.78, blendDuration: 0.12)
    private let folderReorderAnimation = Animation.interactiveSpring(response: 0.23, dampingFraction: 0.8, blendDuration: 0.12)
    private let reorderLiftAnimation = Animation.spring(response: 0.26, dampingFraction: 0.82, blendDuration: 0.1)
    private let fullscreenGridEntranceAnimation = Animation.spring(response: 0.34, dampingFraction: 0.82, blendDuration: 0.12)
    private let fullscreenGridEntranceTranslation: CGFloat = 50
    private static let pageSwitchDuration: TimeInterval = 0.085
    private static let maxQueuedPageShiftCount = 2
    private static let pageSwitchResponse: Double = 0.22
    private static let pageSwitchDamping: Double = 0.88
    private static let pageSwitchFallbackDuration: TimeInterval = 0.18
    private let pageSwitchAnimation = Animation.interactiveSpring(
        response: Self.pageSwitchResponse,
        dampingFraction: Self.pageSwitchDamping,
        blendDuration: 0.08
    )
    private let gestureSettleAnimation = Animation.interactiveSpring(
        response: Self.pageSwitchResponse + 0.02,
        dampingFraction: Self.pageSwitchDamping + 0.04,
        blendDuration: 0.08
    )
    private static let folderOpenDuration: TimeInterval = 0.25
    private let folderOpenAnimation = Animation.easeInOut(duration: Self.folderOpenDuration)
    private let folderPreviewMatchReleaseDelay: TimeInterval = 0.42
    private let pagerButtonHitPadding: CGFloat = 12
    private let pagerButtonHitSize: CGFloat = 44
    private let pagerButtonHitExpansion: CGFloat = 12
    private let dragEdgePagingInterval: TimeInterval = 1.0
    private let dragEdgePagingZoneWidth: CGFloat = 56
    private var performanceTuning: PerformanceTuning {
        PerformanceCapabilityLayer.shared.tuning(for: hostingWindow()?.screen)
    }
    private var highQualityIconCacheLimit: Int { performanceTuning.highQualityIconCacheLimit }
    private var highQualityRequestDelay: TimeInterval { performanceTuning.highQualityRequestDelay }
    private var searchInputDebounceNanoseconds: UInt64 { performanceTuning.searchInputDebounceNanoseconds }
    private var searchMetadataDebounceNanoseconds: UInt64 { performanceTuning.searchMetadataDebounceNanoseconds }
    private var visiblePagesDebounceNanoseconds: UInt64 { performanceTuning.visiblePagesDebounceNanoseconds }
    private var scrollCoalescingNanoseconds: UInt64 { performanceTuning.scrollCoalescingNanoseconds }
    private var pageRasterizationThreshold: CGFloat { performanceTuning.pageRasterizationThreshold }

    @State private var orderedItems: [LauncherItem]
    @State private var draggedItem: LauncherItem?
    @State private var dragOriginIndex: Int?
    @State private var dragOriginItemsSnapshot: [LauncherItem]?
    @State private var dragOriginPageSizesSnapshot: [Int]?
    @State private var isPerformingMultiSelectionDrag = false
    @State private var isDragModifierSnapActive = false
    @State private var activeDragModifierMode: DragModifierMode = .normal
    @State private var pendingModifierPreviewReset = false
    @State private var forceNoGridAnimationDuringDragReset = false
    @State private var currentPage: Int = 0
    @State private var isClosingLauncher = false
    @State private var searchText = ""
    @State private var cachedFilteredItems: [LauncherItem]
    @State private var searchMetadataByAppID: [UUID: SearchableAppEntry]
    @State private var folderSearchMetadataByID: [UUID: SearchableFolderEntry]
    @State private var searchSelectionIndex: Int?
    @State private var searchTask: Task<Void, Never>?
    @State private var searchRequestID: UInt = 0
    @State private var isSearchLoading = false
    @State private var searchDebounceTask: Task<Void, Never>?
    @State private var searchControlsExpanded = false
    @State private var lastNormalizedSearchQuery = ""
    @State private var pendingSearchPageReset = false
    @State private var searchMetadataTask: Task<Void, Never>?
    @State private var isMultiSelectModeActive = false
    @State private var multiSelectedItemIDs: Set<UUID> = []
    @State private var expansionAutoCollapseTask: Task<Void, Never>?
    @State private var activeFolder: FolderItem?
    @State private var folderDragContext: FolderDragContext?
    @State private var draggedFolderApp: AppItem?
    @State private var activeFolderFrame: CGRect = .zero
    @State private var folderHoverWorkItem: DispatchWorkItem?
    @State private var folderHoverTargetID: UUID?
    @State private var folderHoverInModifierMode = false
    @State private var folderSnapPreviewTargetID: UUID?
    @State private var lastLiveReorderTargetIndex: Int?
    @State private var suppressGridAnimation = false
    @State private var isEditingFolderName = false
    @State private var renamingAppID: UUID?
    @State private var highQualityIconOverrides: [UUID: NSImage] = [:]
    @State private var highQualityIconOrder: [UUID] = []
    @State private var pendingHighQualityIconIDs: Set<UUID> = []
    @State private var delayedHighQualityRequests: Set<UUID> = []
    @State private var highQualityRequestEpoch: Int = 0
    @State private var lastPageChangeDate: Date?
    @State private var isLauncherVisible = true
    @State private var interactionPressureEpoch: Int = 0
    @State private var interactionPressureUntil: Date?
    @State private var appNameDraft = ""
    @State private var folderNameDraft = ""
    @State private var activeFolderPage = 0
    @State private var activeFolderPageCount = 0
    @State private var pageSizes: [Int]
    @State private var fullscreenGridEntranceProgress: Double = 1
    @State private var launchingItemID: UUID?
    @State private var pageDirection: PageShiftDirection = .forward
    @State private var folderIconWaveToggle = false
    @State private var folderPreviewMatchID: UUID?
    @State private var isFolderClosing = false
    @State private var folderCloseWorkItem: DispatchWorkItem?
    @State private var closingFolder: FolderItem?
    @State private var folderPreviewReleaseWorkItem: DispatchWorkItem?
    @State private var folderIconWaveWorkItem: DispatchWorkItem?
    @State private var folderOverlayOpenProgress: Double = 1
    @State private var pendingFolderRenameID: UUID?
    @State private var lastActiveFolderID: UUID?
    @State private var shouldSkipActiveFolderChangeEffects = false
    private let highQualityRenderQueue = DispatchQueue(label: "com.launchy.icon.high", qos: .utility)
    private static let folderPreviewWarmupQueue = DispatchQueue(label: "com.launchy.icon.folder-preview", qos: .utility)
    private static let folderPreviewCache = FolderPreviewCache()
    @State private var pagerDragOffset: CGFloat = 0
    @State private var pagerViewportWidth: CGFloat = 1
    @State private var lastGridViewportSize: CGSize = .zero
    @State private var lastPagerDragDate: Date?
    @State private var folderPagerDragOffset: CGFloat = 0
    @State private var folderPagerViewportWidth: CGFloat = 1
    @State private var folderLastPagerDragDate: Date?
    @State private var pendingDropPage: Int?
    @State private var activeDragEdgePagingDelta: Int?
    @State private var dragEdgePagingToken: UInt = 0
    @State private var folderLiveReorderTargetIndex: Int?
    @State private var folderPreviewMatchingDisabled = false
    @State private var lastPerformanceCapability: PerformanceCapability?
    @State private var isPageSwitchAnimationActive = false
    @State private var pageSwitchAnimationToken: UInt = 0
    @State private var pageSwitchPhase2Token: UInt = 0
    @State private var pageSwitchSignpostID: OSSignpostID = .invalid
    @State private var pendingPagerAnimationFinalization: PendingPagerAnimationFinalization?
    @State private var isScrollGestureActive = false
    @State private var pendingScrollDelta: CGFloat = 0
    @State private var scrollUpdateScheduled = false
    @State private var lastPagerInteractionSource: PagerInteractionSource = .drag
    @State private var queuedPageShifts: [Int] = []
    @State private var visiblePagesTask: Task<Void, Never>?
    @State private var prewarmedPageTokens: Set<Int> = []
    @State private var lastKnownIconDimension: CGFloat = 100
    @State private var hasRecordedFirstPageRender = false
    @State private var firstPageRenderSignpostID: OSSignpostID = .invalid
    @State private var hasRecordedFirstPageSwitchCommit = false
    @FocusState private var isFolderNameFieldFocused: Bool
    @FocusState private var isAppNameFieldFocused: Bool
    @FocusState private var isSearchFieldFocused: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.layoutDirection) private var layoutDirection

    init(
        itemCatalog: [LauncherItem],
        initialPageSizes: [Int] = [],
        backgroundStylePreference: LauncherSettings.PreferredBackgroundStyle = .standard,
        solidBackgroundColor: LauncherSettings.SolidBackgroundColor = .system,
        launcherMode: LauncherMode = .floaty,
        gridConfiguration: LauncherGridConfiguration = LauncherGridConfiguration.configuration(for: .small, mode: .floaty),
        pagingOrientation: PagingOrientation = .horizontal,
        fillsGapsAutomatically: Bool = true,
        onToggleLauncherModeRequested: (() -> Void)? = nil,
        onSettingsRequested: (() -> Void)? = nil,
        onAppInfoRequested: (() -> Void)? = nil,
        onItemOrderChange: (([LauncherItem], [Int]) -> Void)? = nil,
        onVisiblePagesChanged: (([AppItem]) -> Void)? = nil,
        onPageSwitchPrewarm: (([AppItem]) -> Void)? = nil,
        iconProvider: @escaping @Sendable (AppItem, CGFloat, IconRenderQuality, CGFloat) -> NSImage? = { app, _, _, _ in app.iconImage }
    ) {
        self.itemCatalog = itemCatalog
        self.initialPageSizes = initialPageSizes
        self.backgroundStylePreference = backgroundStylePreference
        self.solidBackgroundColor = solidBackgroundColor
        self.launcherMode = launcherMode
        self.gridConfiguration = gridConfiguration
        self.pagingOrientation = pagingOrientation
        self.fillsGapsAutomatically = fillsGapsAutomatically
        self.onToggleLauncherModeRequested = onToggleLauncherModeRequested
        self.onSettingsRequested = onSettingsRequested
        self.onAppInfoRequested = onAppInfoRequested
        self.onItemOrderChange = onItemOrderChange
        self.onVisiblePagesChanged = onVisiblePagesChanged
        self.onPageSwitchPrewarm = onPageSwitchPrewarm
        self.iconProvider = iconProvider
        let metadata = Self.buildSearchMetadata(from: itemCatalog)
        _orderedItems = State(initialValue: itemCatalog)
        _cachedFilteredItems = State(initialValue: itemCatalog)
        _searchMetadataByAppID = State(initialValue: metadata.apps)
        _folderSearchMetadataByID = State(initialValue: metadata.folders)
        _pageSizes = State(initialValue: initialPageSizes)
    }

    /// Builds the full launcher UI including background, grid, and pager controls.
    var body: some View {
        bodyContent
    }

    private var bodyContent: some View {
        GeometryReader { proxy in
            buildLauncherContent(for: proxy.size)
        }
        .onAppear {
            applyPerformanceTuningIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            applyPerformanceTuningIfNeeded()
        }
        .onChange(of: itemCatalog) { newValue in
            orderedItems = newValue
            scheduleSearchMetadataRebuild(for: newValue)
            prewarmedPageTokens.removeAll()
            if fillsGapsAutomatically {
                pageSizes = densePageSizes(for: newValue.count)
            } else {
                pageSizes = normalizePageSizes(initialPageSizes, itemCount: newValue.count)
            }
            currentPage = 0
            pageDirection = .forward
            pagerDragOffset = 0
            updateFilteredItems(using: newValue)
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
            notifyVisiblePagesChanged()
        }
        .onChange(of: gridConfiguration) { _ in
            if fillsGapsAutomatically {
                pageSizes = densePageSizes(for: orderedItems.count)
            } else {
                pageSizes = normalizePageSizes(pageSizes, itemCount: orderedItems.count)
            }
            ensureCurrentPageWithinBounds()
            pagerDragOffset = 0
        }
        .onChange(of: pagingOrientation) { _ in
            pagerDragOffset = 0
            pagerViewportWidth = computedPagerSpan(from: lastGridViewportSize)
        }
        .onReceive(NotificationCenter.default.publisher(for: .launcherDidHide)) { _ in
            isLauncherVisible = false
            purgeHighQualityOverrides()
        }
        .onReceive(NotificationCenter.default.publisher(for: .launcherDidShow)) { _ in
            isLauncherVisible = true
            cancelPendingHighQualityRequests()
        }
        .onReceive(NotificationCenter.default.publisher(for: .launcherShouldPurgeVisualCaches)) { _ in
            purgeHighQualityOverrides()
            cancelPendingHighQualityRequests()
            purgeFolderPreviewCache()
        }
        .onChange(of: colorScheme) { _ in
            resetVisualCachesForAppearanceChange()
        }
        .onChange(of: activeFolder) { newValue in
            if shouldSkipActiveFolderChangeEffects {
                shouldSkipActiveFolderChangeEffects = false
                return
            }
            if newValue == nil {
                stopDragEdgePaging()
                pendingFolderRenameID = nil
                activeFolderFrame = .zero
                folderDragContext = nil
                draggedFolderApp = nil
                cancelFolderHover()
                isEditingFolderName = false
                folderNameDraft = ""
                isFolderNameFieldFocused = false
                if folderPreviewMatchID != nil {
                    scheduleFolderIconWaveToggle(false, delay: Self.folderOpenDuration, animated: false)
                } else {
                    scheduleFolderIconWaveToggle(false, delay: 0, animated: true)
                }
                let closingID = lastActiveFolderID
                if let closingID {
                    folderPreviewMatchID = closingID
                }
                scheduleFolderPreviewMatchRelease(for: closingID)
                folderPreviewMatchingDisabled = false
                launchingItemID = nil
                activeFolderPage = 0
                activeFolderPageCount = 0
                folderLiveReorderTargetIndex = nil
            } else if let folder = newValue {
                stopDragEdgePaging()
                lastActiveFolderID = folder.id
                // folderIconWaveToggle being true means the overlay is already visible —
                // this is a data sync (app moved in/out of folder), not a fresh open.
                // Skip the opening animation resets so the overlay stays visible.
                let isFreshOpen = folderIconWaveToggle == false
                if isFreshOpen {
                    scheduleFolderIconWaveToggle(false, delay: 0, animated: false)
                }
                cancelFolderPreviewMatchRelease()
                folderNameDraft = folder.name
                isEditingFolderName = false
                folderPreviewMatchingDisabled = false
                launchingItemID = nil
                if isFreshOpen {
                    activeFolderPage = 0
                    activeFolderPageCount = 1
                }
                isFolderClosing = false
                folderCloseWorkItem?.cancel()
                folderCloseWorkItem = nil
                closingFolder = nil
            }
        }
        .onChange(of: searchText) { newValue in
            prewarmedPageTokens.removeAll()
            if newValue.isEmpty {
                stopDragEdgePaging()
                currentPage = 0
                pageDirection = .forward
                pagerDragOffset = 0
                pendingSearchPageReset = false
            } else {
                pendingSearchPageReset = currentPage != 0
            }
            searchSelectionIndex = nil
            if newValue.isEmpty == false {
                exitMultiSelectMode()
                updateSearchControlsExpansion(to: false)
                cancelExpansionAutoCollapse()
            }
            scheduleSearchUpdate()
        }
        .onChange(of: draggedItem) { newItem in
            if newItem == nil {
                stopDragEdgePaging()
                folderSnapPreviewTargetID = nil
                dragOriginIndex = nil
                dragOriginItemsSnapshot = nil
                dragOriginPageSizesSnapshot = nil
                isDragModifierSnapActive = false
                pendingModifierPreviewReset = false
                activeDragModifierMode = .normal
                forceNoGridAnimationDuringDragReset = false
                isPerformingMultiSelectionDrag = false
                lastLiveReorderTargetIndex = nil
                folderLiveReorderTargetIndex = nil
            }
            suppressGridAnimation = newItem != nil
            if newItem != nil {
                enterPerformanceShedding(duration: 0.8)
            }
        }
        .onChange(of: orderedItems) { newItems in
            scheduleSearchMetadataRebuild(for: newItems)
            prewarmedPageTokens.removeAll()
            if fillsGapsAutomatically {
                pageSizes = densePageSizes(for: newItems.count)
            } else {
                pageSizes = normalizePageSizes(pageSizes, itemCount: newItems.count)
            }
            updateFilteredItems(using: newItems)
            let maxPage = max(pageCount - 1, 0)
            currentPage = min(currentPage, maxPage)
            pageDirection = .forward
            pagerDragOffset = 0
            if let currentFolder = activeFolder {
                if let updatedFolder = folderItem(withID: currentFolder.id, in: newItems) {
                    if updatedFolder != currentFolder {
                        if isEditingFolderName == false {
                            folderNameDraft = updatedFolder.name
                        }
                        shouldSkipActiveFolderChangeEffects = true
                        activeFolder = updatedFolder
                    }
                } else {
                    closeActiveFolder(animated: false)
                    enterPerformanceShedding(duration: 0.6, cancelHeavyWork: false)
                }
            }
            let validIDs = Set(newItems.map(\.id))
            multiSelectedItemIDs.formIntersection(validIDs)
        }
        .onChange(of: isEditingFolderName) { isEditing in
            if isEditing == false {
                focusSearchFieldIfAppropriate()
            }
        }
        .onChange(of: currentPage) { _ in
            alignSearchSelectionWithCurrentPageIfNeeded()
            notifyVisiblePagesChanged()
        }
        .onChange(of: pagerDragOffset) { _ in
            completePageSwitchIfReady()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            guard let window = notification.object as? NSWindow,
                  isLauncherHostingWindow(window) else { return }
            focusSearchFieldIfAppropriate()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard let window = hostingWindow(), window.isVisible else { return }
            focusSearchFieldIfAppropriate()
        }
        .onAppear {
            focusSearchFieldIfAppropriate()
            notifyVisiblePagesChanged()
        }
    }

    /// Builds container-aware launcher content for the active mode.
    @ViewBuilder
    private func buildLauncherContent(for containerSize: CGSize) -> some View {
        let topInset = fullscreenTopInset(for: containerSize.height)
        let layout = LauncherLayoutMetrics(
            containerSize: containerSize,
            launcherMode: launcherMode,
            topInset: topInset,
            columnsPerPage: gridConfiguration.columnsPerPage,
            rowsPerPage: gridConfiguration.rowsPerPage
        )
        let canReorder = searchText.isEmpty

        let content = launcherContentBody(
            layout: layout,
            topInset: topInset,
            canReorder: canReorder,
            containerSize: containerSize
        )

        if launcherMode == .floaty {
            let floatyShape = RoundedRectangle(cornerRadius: layout.floatyCornerRadius, style: .continuous)
            content
                .background(floatyBackdropHighlight(cornerRadius: layout.floatyCornerRadius))
                .clipShape(floatyShape)
                .overlay(floatyGlassStroke(cornerRadius: layout.floatyCornerRadius))
                .background(
                    floatyShape
                        .fill(Color.clear)
                        .shadow(color: Color.black.opacity(0.32), radius: 26, y: 22)
                        .shadow(color: Color.black.opacity(0.18), radius: 12, y: 6)
                        .shadow(color: Color.white.opacity(colorScheme == .dark ? 0.14 : 0.22), radius: 2.6, y: 1)
                )
        } else {
            content
        }
    }

    /// Shared root content body for both floaty and fullscreen presentations.
    @ViewBuilder
    private func launcherContentBody(
        layout: LauncherLayoutMetrics,
        topInset: CGFloat,
        canReorder: Bool,
        containerSize: CGSize
    ) -> some View {
        ZStack {
            LauncherBackgroundLayer(
                style: backgroundStylePreference,
                solidBackgroundColor: solidBackgroundColor,
                launcherMode: launcherMode,
                colorScheme: colorScheme
            )
            .ignoresSafeArea()

            if launcherMode == .floaty {
                let sheen = Color.white.opacity(colorScheme == .dark ? 0.16 : 0.08)
                let glow = Color(red: 0.64, green: 0.78, blue: 0.98).opacity(colorScheme == .dark ? 0.13 : 0.12)
                let depth = Color(red: 0.33, green: 0.45, blue: 0.74).opacity(colorScheme == .dark ? 0.09 : 0.08)
                LinearGradient(
                    colors: [sheen, glow, depth],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .blendMode(.screen)
                .ignoresSafeArea()

                if colorScheme == .dark {
                    Color.black.opacity(0.10)
                        .ignoresSafeArea()
                }
            }

            VStack(spacing: 0) {
                fullscreenSpacer(height: topInset)

                VStack(spacing: 0) {
                    searchBar(layout: layout)
                    .padding(.top, layout.floatySearchBarTopPadding)
                    .padding(.bottom, layout.searchToGridSpacing)

                    let isFolderOverlayVisible = activeFolder != nil || closingFolder != nil
                    let gridBlendOpacity: Double = isFolderOverlayVisible ? 0.6 : 1
                    let pagerOnLeft = isVerticalPaging && launcherMode == .fullscreen
                    Group {
                        if pagerOnLeft {
                            HStack(alignment: .top, spacing: 14) {
                                gridPager(canReorder: canReorder, layout: layout)
                                launcherGridLayer(layout: layout, canReorder: canReorder)
                            }
                        } else {
                            VStack(spacing: 0) {
                                launcherGridLayer(layout: layout, canReorder: canReorder)
                                gridPager(canReorder: canReorder, layout: layout)
                            }
                        }
                    }
                    .opacity(gridBlendOpacity)
                    .animation(.easeInOut(duration: 0.30), value: isFolderOverlayVisible)
                }
                .animation(nil, value: searchControlsExpanded)
                .padding(.horizontal, layout.horizontalPadding)
                .padding(.bottom, layout.bottomPadding)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            if let folder = activeFolder ?? closingFolder {
                folderOverlay(for: folder, layout: layout)
            }

            dragEdgePagingOverlay(canReorder: canReorder)
        }
        .transaction { transaction in
            if isScrollGestureActive {
                transaction.animation = nil
            }
        }
        .onChange(of: isSearchFieldFocused) { isFocused in
            if isFocused {
                ensureSearchFieldCaretHidden()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSTextView.didBeginEditingNotification)) { _ in
            ensureSearchFieldCaretHidden()
        }
        .onReceive(NotificationCenter.default.publisher(for: .launcherShouldRefocusSearch)) { _ in
            focusSearchFieldIfAppropriate()
        }
        .onReceive(NotificationCenter.default.publisher(for: .launcherTypeAheadInput)) { notification in
            guard let chars = notification.object as? String, !chars.isEmpty else { return }
            searchText += chars
            focusSearchFieldIfAppropriate()
        }
        .onReceive(NotificationCenter.default.publisher(for: .launcherShouldAnimateGridEntrance)) { _ in
            guard launcherMode == .fullscreen else { return }
            withTransaction(Transaction(animation: nil)) {
                fullscreenGridEntranceProgress = 0
            }
            withAnimation(fullscreenGridEntranceAnimation) {
                fullscreenGridEntranceProgress = 1
            }
        }
        .onChange(of: launcherMode) { newMode in
            focusSearchFieldIfAppropriate()
            if newMode != .fullscreen {
                fullscreenGridEntranceProgress = 1
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

    /// Page count ignoring active search filters, for context menus.
    private var fullPageCount: Int {
        guard orderedItems.isEmpty == false else { return 1 }
        return max(activePageSizes(for: orderedItems.count).count, 1)
    }

    /// Determines when gesture-driven paging should be active.
    private var isGesturePagingEnabled: Bool {
        activeFolder == nil && pageCount > 1 && isClosingLauncher == false
    }

    private var isKeyboardPagingEnabled: Bool {
        guard isClosingLauncher == false else { return false }
        if activeFolder != nil {
            return true
        }
        return pageCount > 1
    }

    private var isRenamingItem: Bool {
        isEditingFolderName || renamingAppID != nil
    }

    private var isArrangementEditingActive: Bool {
        isMultiSelectModeActive || draggedItem != nil || draggedFolderApp != nil || isRenamingItem || isEditingFolderName
    }

    private var isReorderDragActive: Bool {
        draggedItem != nil || draggedFolderApp != nil
    }

    private var isDragEdgePagingEnabled: Bool {
        draggedItem != nil
            && activeFolder == nil
            && searchText.isEmpty
            && pageCount > 1
            && isClosingLauncher == false
    }

    private var shouldCaptureArrowKeys: Bool {
        if isRenamingItem {
            return false
        }
        return true
    }

    private var shouldHandleEscapeKeys: Bool {
        guard isClosingLauncher == false else { return false }
        if isRenamingItem {
            return true
        }
        if activeFolder != nil {
            return true
        }
        if hasActiveSearchQuery {
            return true
        }
        return launcherMode == .floaty || launcherMode == .fullscreen
    }

    private var isFolderGesturePagingEnabled: Bool {
        activeFolder != nil && activeFolderPageCount > 1 && isClosingLauncher == false
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

    /// Calculates the current offset for the paged grid stack.
    private func pageOffset(for page: Int, pageSpan: CGFloat) -> CGFloat {
        let current = clampPageIndex(currentPage)
        let alignedSpan = pixelAlignedPageSpan(pageSpan)
        let baseOffset = pixelAlign(pagerDragOffset)
        return baseOffset + CGFloat(page - current) * alignedSpan
    }

    private var isPagerTransitionActive: Bool {
        isPageSwitchAnimationActive || abs(pagerDragOffset) > 0.01 || isScrollGestureActive
    }

    private var activeGridAnimation: Animation? {
        if isPageSwitchAnimationActive {
            return nil
        }
        if forceNoGridAnimationDuringDragReset {
            return nil
        }
        if draggedItem != nil {
            return liveReorderSpringAnimation
        }
        return suppressGridAnimation ? nil : gridSpringAnimation
    }

    private var shouldUseHighQualityIcons: Bool {
        guard isArrangementEditingActive == false else { return false }
        guard suppressGridAnimation == false else { return false }
        guard abs(pagerDragOffset) < 1 else { return false }
        guard isClosingLauncher == false else { return false }
        guard isLauncherVisible else { return false }
        guard isUnderInteractionPressure == false else { return false }
        return isHighQualityCoolingDown == false
    }

    private var isHighQualityCoolingDown: Bool {
        guard let lastPageChangeDate else { return false }
        return Date().timeIntervalSince(lastPageChangeDate) < 0.42
    }

    private var isUnderInteractionPressure: Bool {
        guard let until = interactionPressureUntil else { return false }
        return until.timeIntervalSinceNow > 0
    }

    /// Resolves an icon using layered caches and the external provider callback.
    private func resolvedIcon(for app: AppItem, dimension: CGFloat, quality: IconRenderQuality) -> NSImage? {
        iconProvider(app, dimension, quality, currentBackingScale())
    }

    /// Chooses baseline icon size/quality for grid rendering.
    private func baseIconRequest(for layout: LauncherLayoutMetrics) -> (dimension: CGFloat, quality: IconRenderQuality) {
        // Keep base icon sizing stable to avoid post-animation icon swaps.
        let scale = currentBackingScale()
        let dimension = layout.iconDimension
        let quality: IconRenderQuality = {
            if scale <= 1.2 {
                return .medium
            }
            if launcherMode == .floaty {
                return .balanced
            }
            return .medium
        }()
        return (dimension, quality)
    }

    /// Chooses icon request parameters for compact folder previews.
    private func folderTileIconRequest(for layout: LauncherLayoutMetrics) -> (dimension: CGFloat, quality: IconRenderQuality) {
        // Folder preview icons should not rescale after interactions.
        let scaledDimension = max(layout.iconDimension * 0.6, 34)
        return (scaledDimension, .low)
    }

    /// Retrieves one cached icon used inside folder tile previews.
    private func folderPreviewIcon(for app: AppItem, layout: LauncherLayoutMetrics) -> NSImage? {
        let request = folderTileIconRequest(for: layout)
        let cache = Self.folderPreviewCache
        let appearanceToken = currentAppearanceToken()
        let key = cache.cacheKey(
            for: app,
            dimension: request.dimension,
            quality: request.quality,
            appearanceToken: appearanceToken
        )
        if let cached = cache.cachedIcon(for: key) {
            return cached
        }
        let resolved = resolvedIcon(for: app, dimension: request.dimension, quality: request.quality) ?? app.iconImage
        if let resolved {
            cache.store(resolved, for: key)
        }
        return resolved
    }

    /// Preloads folder preview icons to avoid delayed pop-in when opening folders.
    private func warmFolderPreviewIcons(for folder: FolderItem, layout: LauncherLayoutMetrics) {
        let request = folderTileIconRequest(for: layout)
        let apps = Array(folder.apps.prefix(9))
        guard apps.isEmpty == false else { return }
        let cache = Self.folderPreviewCache
        let appearanceToken = currentAppearanceToken()
        let keys = apps.map {
            cache.cacheKey(
                for: $0,
                dimension: request.dimension,
                quality: request.quality,
                appearanceToken: appearanceToken
            )
        }
        let missing = keys.contains { cache.cachedIcon(for: $0) == nil }
        guard missing else { return }

        let token = "\(folder.id.uuidString)|\(appearanceToken)|\(Int(request.dimension.rounded()))|\(apps.map(\.id).hashValue)"
        guard cache.beginWarmupIfNeeded(token: token) else { return }

        let provider: @Sendable (AppItem, CGFloat, IconRenderQuality, CGFloat) -> NSImage? = iconProvider
        let dimension = request.dimension
        let quality = request.quality
        let scale = currentBackingScale()
        let queue = Self.folderPreviewWarmupQueue
        queue.async {
            for (app, key) in zip(apps, keys) {
                if cache.cachedIcon(for: key) != nil {
                    continue
                }
                let resolved = provider(app, dimension, quality, scale) ?? app.iconImage
                if let resolved {
                    cache.store(resolved, for: key)
                }
            }
            cache.finishWarmup(token: token)
        }
    }

    /// Preloads folder preview icons using an explicit icon dimension (for use before layout is available).
    private func warmFolderPreviewIcons(for folder: FolderItem, iconDimension: CGFloat) {
        let dimension = max(iconDimension * 0.6, 34)
        let quality: IconRenderQuality = .low
        let apps = Array(folder.apps.prefix(9))
        guard apps.isEmpty == false else { return }
        let cache = Self.folderPreviewCache
        let appearanceToken = currentAppearanceToken()
        let keys = apps.map {
            cache.cacheKey(for: $0, dimension: dimension, quality: quality, appearanceToken: appearanceToken)
        }
        let missing = keys.contains { cache.cachedIcon(for: $0) == nil }
        guard missing else { return }
        let token = "\(folder.id.uuidString)|\(appearanceToken)|\(Int(dimension.rounded()))|\(apps.map(\.id).hashValue)"
        guard cache.beginWarmupIfNeeded(token: token) else { return }
        let provider: @Sendable (AppItem, CGFloat, IconRenderQuality, CGFloat) -> NSImage? = iconProvider
        let scale = currentBackingScale()
        let queue = Self.folderPreviewWarmupQueue
        queue.async {
            for (app, key) in zip(apps, keys) {
                if cache.cachedIcon(for: key) != nil { continue }
                let resolved = provider(app, dimension, quality, scale) ?? app.iconImage
                if let resolved { cache.store(resolved, for: key) }
            }
            cache.finishWarmup(token: token)
        }
    }

    /// Clears transient folder preview cache when inputs/limits change.
    private func purgeFolderPreviewCache() {
        Self.folderPreviewCache.purge()
    }

    /// Derives a stable token for theme-sensitive view caches.
    private func currentAppearanceToken() -> String {
        colorScheme == .dark ? "dark" : "light"
    }

    /// Clears icon caches that can retain stale light/dark variants across appearance changes.
    private func resetVisualCachesForAppearanceChange() {
        purgeHighQualityOverrides()
        purgeFolderPreviewCache()
    }

    /// Computes icon dimension for deferred high-quality replacement requests.
    private func highQualityRequestDimension(for layout: LauncherLayoutMetrics) -> CGFloat {
        let boosted = max(layout.iconDimension * 1.2, layout.iconDimension)
        return min(boosted, 200)
    }

    /// Starts phase one of page switching (immediate state updates before deferred settle).
    private func beginPageSwitchPhase1() {
        lastPageChangeDate = Date()
        suppressGridAnimation = true
    }

    /// Completes deferred page-switch state after transition delay.
    private func performPageSwitchPhase2() {
        let signpostID = Self.beginSignpost("PageSwitchPhase2")
        bumpHighQualityRequestEpoch(resetPending: true)
        enterPerformanceShedding()
        Self.endSignpost("PageSwitchPhase2", id: signpostID)
    }

    /// Schedules phase-two page-switch work and coalesces rapid triggers.
    private func schedulePageSwitchPhase2() {
        pageSwitchPhase2Token &+= 1
        let phase2Token = pageSwitchPhase2Token
        DispatchQueue.main.async { [self] in
            guard phase2Token == pageSwitchPhase2Token else { return }
            performPageSwitchPhase2()
        }
    }

    /// Applies a directional page change using a staged offset so both pages move coherently.
    private func performAnimatedPageSwitch(
        to targetPage: Int,
        direction: PageShiftDirection,
        spanOverride: CGFloat? = nil,
        handoffOffset: CGFloat? = nil
    ) {
        guard pageCount > 0 else { return }
        guard targetPage != currentPage else { return }
        assert(Thread.isMainThread, "Page switches must run on the main thread to avoid extra view invalidations.")
        // Performance guardrail: keep page switch animations centralized here to avoid nested transactions.

        let span = max(spanOverride ?? pagerViewportWidth, 1)
        let startingPage = currentPage
        let initialOffset = handoffOffset ?? (direction == .forward ? span : -span)

        if handoffOffset == nil, abs(targetPage - startingPage) == 1 {
            performGestureDrivenPageSwitch(
                to: targetPage,
                direction: direction,
                pageSpan: span
            )
            return
        }

        if startingPage != targetPage {
            let step = targetPage > startingPage ? 1 : -1
            for page in stride(from: startingPage + step, through: targetPage, by: step) {
                prewarmPageIfNeeded(page)
            }
        }

        let completionSignpostID = Self.beginSignpost("PageSwitchTrigger")
        pageSwitchSignpostID = Self.beginSignpost("PageSwitch")

        pageDirection = direction
        suppressGridAnimation = true

        // Move to the target page immediately, start it offset offscreen, then slide it in.
        currentPage = targetPage
        pagerDragOffset = pixelAlign(initialOffset)
        beginPageSwitchPhase1()
        schedulePageSwitchPhase2()
        beginPageSwitchAnimation(
            finalization: PendingPagerAnimationFinalization(
                logicalPage: nil,
                terminalOffset: 0
            )
        )

        withAnimation(pageSwitchAnimation) {
            pagerDragOffset = 0
        }

        DispatchQueue.main.async {
            let commitID = Self.beginSignpost("PageSwitchCommit")
            Self.endSignpost("PageSwitchCommit", id: commitID)
            if hasRecordedFirstPageSwitchCommit == false {
                let firstCommitID = Self.beginSignpost("FirstPageSwitchCommit")
                Self.endSignpost("FirstPageSwitchCommit", id: firstCommitID)
                hasRecordedFirstPageSwitchCommit = true
            }
        }

        Self.endSignpost("PageSwitchTrigger", id: completionSignpostID)
    }

    /// Completes a gesture-driven page switch without remapping pages until the slide fully settles.
    private func performGestureDrivenPageSwitch(
        to targetPage: Int,
        direction: PageShiftDirection,
        pageSpan: CGFloat
    ) {
        guard pageCount > 0 else { return }
        guard targetPage != currentPage else { return }
        assert(Thread.isMainThread, "Page switches must run on the main thread to avoid extra view invalidations.")

        let startingPage = currentPage
        let span = max(pageSpan, 1)
        let finalOffset = pixelAlign(CGFloat(startingPage - targetPage) * span)

        if startingPage != targetPage {
            let step = targetPage > startingPage ? 1 : -1
            for page in stride(from: startingPage + step, through: targetPage, by: step) {
                prewarmPageIfNeeded(page)
            }
        }

        let completionSignpostID = Self.beginSignpost("PageSwitchTrigger")
        pageSwitchSignpostID = Self.beginSignpost("PageSwitch")

        let transaction = Transaction(animation: nil)
        withTransaction(transaction) {
            pageDirection = direction
            pagerDragOffset = pixelAlign(pagerDragOffset)
        }

        beginPageSwitchPhase1()
        schedulePageSwitchPhase2()
        beginPageSwitchAnimation(
            finalization: PendingPagerAnimationFinalization(
                logicalPage: targetPage,
                terminalOffset: finalOffset
            )
        )

        withAnimation(pageSwitchAnimation) {
            pagerDragOffset = finalOffset
        }

        DispatchQueue.main.async {
            let commitID = Self.beginSignpost("PageSwitchCommit")
            Self.endSignpost("PageSwitchCommit", id: commitID)
            if hasRecordedFirstPageSwitchCommit == false {
                let firstCommitID = Self.beginSignpost("FirstPageSwitchCommit")
                Self.endSignpost("FirstPageSwitchCommit", id: firstCommitID)
                hasRecordedFirstPageSwitchCommit = true
            }
        }

        Self.endSignpost("PageSwitchTrigger", id: completionSignpostID)
    }

    /// Invalidates stale high-quality icon requests by bumping epoch generation.
    private func bumpHighQualityRequestEpoch(resetPending: Bool = false) {
        highQualityRequestEpoch &+= 1
        if resetPending {
            pendingHighQualityIconIDs.removeAll()
            delayedHighQualityRequests.removeAll()
        }
    }

    /// Drops high-quality icon override cache.
    private func purgeHighQualityOverrides() {
        highQualityIconOverrides.removeAll()
        highQualityIconOrder.removeAll()
        pendingHighQualityIconIDs.removeAll()
        delayedHighQualityRequests.removeAll()
        bumpHighQualityRequestEpoch(resetPending: true)
    }

    /// Cancels any in-flight deferred high-quality icon fetch work.
    private func cancelPendingHighQualityRequests() {
        pendingHighQualityIconIDs.removeAll()
        delayedHighQualityRequests.removeAll()
        bumpHighQualityRequestEpoch(resetPending: true)
    }

    /// Kicks off page transition animation bookkeeping.
    private func beginPageSwitchAnimation(finalization: PendingPagerAnimationFinalization) {
        pageSwitchAnimationToken &+= 1
        let token = pageSwitchAnimationToken
        isPageSwitchAnimationActive = true
        pendingPagerAnimationFinalization = finalization
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pageSwitchFallbackDuration) { [self] in
            guard token == pageSwitchAnimationToken else { return }
            completePageSwitchIfReady(force: true)
        }
    }

    /// Finishes page-switch state once the animated offset is close to its terminal value.
    private func completePageSwitchIfReady(force: Bool = false) {
        guard isPageSwitchAnimationActive else { return }
        guard let finalization = pendingPagerAnimationFinalization else { return }

        let tolerance = max(1.5, pixelAlignedPageSpan(pagerViewportWidth) * 0.015)
        guard force || abs(pagerDragOffset - finalization.terminalOffset) <= tolerance else { return }

        pendingPagerAnimationFinalization = nil
        let transaction = Transaction(animation: nil)
        withTransaction(transaction) {
            if let logicalPage = finalization.logicalPage {
                currentPage = logicalPage
            }
            pagerDragOffset = 0
            isPageSwitchAnimationActive = false
            if draggedItem == nil {
                suppressGridAnimation = false
            }
        }
        Self.endSignpost("PageSwitch", id: pageSwitchSignpostID)
        pageSwitchSignpostID = .invalid
        drainQueuedPageShiftIfNeeded()
    }

    /// Temporarily backs off heavy work (like hi-res icon loads) while the user is interacting.
    private func enterPerformanceShedding(duration: TimeInterval = 0.9, cancelHeavyWork: Bool = true) {
        interactionPressureEpoch &+= 1
        interactionPressureUntil = Date().addingTimeInterval(duration)
        if cancelHeavyWork {
            cancelPendingHighQualityRequests()
        }

        let epoch = interactionPressureEpoch
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [self] in
            guard epoch == interactionPressureEpoch else { return }
            interactionPressureUntil = nil
        }
    }

    /// Records the active viewport span so scroll-based gestures map 1:1 with page distance.
    private func beginPagerInteraction(pageSpan: CGFloat) {
        pagerViewportWidth = max(pageSpan, 1)
    }

    /// Finalizes a drag-based page interaction using the predicted end state to capture velocity.
    private func finishPagerInteraction(translation: CGFloat, predictedEndTranslation: CGFloat, pageSpan: CGFloat) {
        let signpostID = Self.beginSignpost("PagerInputEnd")
        let projection = predictedEndTranslation - translation
        settlePagerOffset(pageSpan: pageSpan, projectedDelta: projection)
        Self.endSignpost("PagerInputEnd", id: signpostID)
    }

    /// Applies live scroll deltas from the trackpad so paging feels directly connected to the gesture.
    private func handleScrollProgress(_ event: ScrollWheelPagerOverlay.ScrollEvent) {
        guard isGesturePagingEnabled else { return }
        let width = pagerViewportWidth
        guard width > 0 else { return }
        beginPagerInteraction(pageSpan: width)
        lastPagerInteractionSource = .scroll

        let isDiscrete = event.isPrecise == false
        let primaryDelta = isVerticalPaging ? -event.deltaY : event.deltaX

        if isDiscrete {
            // Let discrete paging (mouse wheel) trigger jumps without live dragging so animations stay in sync.
            isScrollGestureActive = false
            pagerDragOffset = 0
            lastPagerDragDate = Date()
            if isUnderInteractionPressure == false {
                enterPerformanceShedding(duration: 0.55, cancelHeavyWork: false)
            }
            return
        }

        // Prewarm both neighbors at gesture start so icon loading completes before the companion page
        // enters the view hierarchy, avoiding synchronous main-thread icon rendering on the first frame.
        if isScrollGestureActive == false {
            prewarmPageIfNeeded(currentPage - 1)
            prewarmPageIfNeeded(currentPage + 1)
        }

        if isUnderInteractionPressure == false {
            enterPerformanceShedding(duration: 0.55, cancelHeavyWork: false)
        }

        isScrollGestureActive = true
        let scale: CGFloat = 1.0
        flushPendingScrollDelta(pageSpan: width)
        applyPagerScrollDelta(primaryDelta * scale, pageSpan: width)

    }

    /// Settles the pager to the nearest target page and animates the slide.
    private func settlePagerOffset(pageSpan: CGFloat, projectedDelta: CGFloat = 0) {
        guard pageCount > 0 else {
            pagerDragOffset = 0
            return
        }

        let normalizedWidth = max(pageSpan, 1)
        let liveProgress = pagerDragOffset / normalizedWidth
        let projectedProgress = projectedDelta / normalizedWidth
        let cappedProjectedAssist: CGFloat
        if lastPagerInteractionSource == .drag {
            cappedProjectedAssist = max(min(projectedProgress, 0.12), -0.12)
        } else {
            cappedProjectedAssist = 0
        }
        let completionProgress = liveProgress + cappedProjectedAssist
        let snapThreshold: CGFloat = 0.072
        let recentSnapThreshold: CGFloat = 0.052
        let deliberateLongGestureThreshold: CGFloat = 1.7
        let absLiveProgress = abs(liveProgress)
        let absCompletionProgress = abs(completionProgress)
        let recentDrag = (lastPagerDragDate.map { Date().timeIntervalSince($0) < 0.12 }) ?? false
        let directionSign: Int = {
            if absCompletionProgress > 0.001 {
                return completionProgress > 0 ? 1 : -1
            }
            return liveProgress > 0 ? 1 : -1
        }()

        var deltaMagnitude = 0
        if absLiveProgress >= deliberateLongGestureThreshold {
            deltaMagnitude = min(2, max(1, Int(absLiveProgress.rounded(.down))))
        } else if absCompletionProgress >= snapThreshold || (recentDrag && absLiveProgress >= recentSnapThreshold) {
            deltaMagnitude = 1
        }

        let targetPage = clampPageIndex(currentPage - directionSign * deltaMagnitude)
        let direction: PageShiftDirection = targetPage >= currentPage ? .forward : .backward

        if targetPage == currentPage {
            let signpostID = Self.beginSignpost("PagerCompletionTrigger")
            withAnimation(gestureSettleAnimation) {
                pagerDragOffset = 0
            }
            DispatchQueue.main.async {
                let commitID = Self.beginSignpost("PageSettleCommit")
                Self.endSignpost("PageSettleCommit", id: commitID)
            }
            Self.endSignpost("PagerCompletionTrigger", id: signpostID)
        } else {
            let signpostID = Self.beginSignpost("PagerCompletionTrigger")
            performGestureDrivenPageSwitch(
                to: targetPage,
                direction: direction,
                pageSpan: normalizedWidth
            )
            Self.endSignpost("PagerCompletionTrigger", id: signpostID)
        }
        lastPagerDragDate = nil
    }

    /// Constrains live offsets so we keep neighbors in memory but avoid excessive empty space.
    private func clampPagerOffset(_ offset: CGFloat, pageSpan: CGFloat) -> CGFloat {
        let limit = pageSpan * 2.05
        let bounded = max(min(offset, limit), -limit)

        if currentPage == 0 && bounded > 0 {
            return min(bounded, pageSpan * 0.35)
        }
        if currentPage >= pageCount - 1 && bounded < 0 {
            return max(bounded, -pageSpan * 0.35)
        }

        return bounded
    }

    /// Initializes drag/scroll state for folder-internal pager interaction.
    private func folderBeginPagerInteraction(pageWidth: CGFloat) {
        folderPagerViewportWidth = max(pageWidth, 1)
    }

    /// Applies folder pager offset updates from scroll gesture deltas.
    private func handleFolderScrollProgress(deltaX: CGFloat, phase: NSEvent.Phase, momentumPhase: NSEvent.Phase, isPrecise: Bool) {
        guard isFolderGesturePagingEnabled else { return }
        let width = folderPagerViewportWidth
        guard width > 0 else { return }
        folderBeginPagerInteraction(pageWidth: width)
        if isUnderInteractionPressure == false {
            enterPerformanceShedding(duration: 0.55, cancelHeavyWork: false)
        }

        let scale: CGFloat = isPrecise ? 1.0 : 12.0
        folderPagerDragOffset = folderClampPagerOffset(folderPagerDragOffset + deltaX * scale, pageWidth: width)
        folderLastPagerDragDate = Date()

        if phase.isEmpty && momentumPhase.isEmpty && isPrecise == false {
            folderSettlePagerOffset(pageWidth: width)
            return
        }

        if phase.contains(.ended) || momentumPhase.contains(.ended) {
            folderSettlePagerOffset(pageWidth: width)
        }
    }

    /// Snaps folder pager to nearest page after gesture end/projected momentum.
    private func folderSettlePagerOffset(pageWidth: CGFloat, projectedDelta: CGFloat = 0) {
        guard activeFolder != nil else {
            folderPagerDragOffset = 0
            return
        }

        let normalizedWidth = max(pageWidth, 1)
        let totalPages = max(activeFolderPageCount, 1)
        guard totalPages > 1 else {
            folderPagerDragOffset = 0
            return
        }

        let totalOffset = folderPagerDragOffset + projectedDelta
        let progress = totalOffset / normalizedWidth
        let snapThreshold: CGFloat = 0.08
        let fastThreshold: CGFloat = 0.19
        let doubleProgressThreshold: CGFloat = 1.75
        let highVelocityThreshold: CGFloat = 1.22
        let velocity = projectedDelta / normalizedWidth
        let absVelocity = abs(velocity)
        let absProgress = abs(progress)
        let recentDrag = (folderLastPagerDragDate.map { Date().timeIntervalSince($0) < 0.1 }) ?? false
        let directionSign: Int = {
            if absVelocity > 0.15 {
                return velocity > 0 ? 1 : -1
            }
            return progress > 0 ? 1 : -1
        }()

        var delta = 0
        let allowDouble = (absVelocity > highVelocityThreshold && absProgress > 0.8) || absProgress > doubleProgressThreshold

        if allowDouble {
            delta = 2 * directionSign
        } else if absProgress > fastThreshold {
            delta = 1 * directionSign
        } else if absProgress > snapThreshold || (recentDrag && absProgress > 0.06) {
            delta = 1 * directionSign
        }

        let targetPage = folderClampPageIndex(activeFolderPage - delta)
        let direction: PageShiftDirection = targetPage >= activeFolderPage ? .forward : .backward

        if targetPage == activeFolderPage {
            withAnimation(gestureSettleAnimation) {
                folderPagerDragOffset = 0
            }
        } else {
            performAnimatedFolderSwitch(to: targetPage, direction: direction, pageWidth: pageWidth)
        }
        folderLastPagerDragDate = nil
    }

    /// Ensures folder paging uses the same directional staging as the root pager.
    private func performAnimatedFolderSwitch(to targetPage: Int, direction: PageShiftDirection, pageWidth: CGFloat) {
        guard activeFolder != nil else { return }
        guard targetPage != activeFolderPage else { return }

        let span = max(pageWidth, 1)
        let initialOffset = direction == .forward ? span : -span

        pageDirection = direction
        suppressGridAnimation = true
        activeFolderPage = targetPage
        folderPagerDragOffset = initialOffset
        beginPageSwitchPhase1()
        schedulePageSwitchPhase2()

        withAnimation(pageSwitchAnimation) {
            folderPagerDragOffset = 0
        }
    }

    /// Clamps folder pager offset to valid bounds for current page count.
    private func folderClampPagerOffset(_ offset: CGFloat, pageWidth: CGFloat) -> CGFloat {
        let limit = pageWidth * 0.35
        let bounded = max(min(offset, limit), -limit)

        if activeFolderPage == 0 && bounded > 0 {
            return 0
        }
        if activeFolderPage >= activeFolderPageCount - 1 && bounded < 0 {
            return 0
        }

        return bounded
    }

    /// Computes per-page opacity based on pager offset to soften transitions.
    private func folderPageOpacity(for page: Int, pageWidth: CGFloat) -> Double {
        if page == activeFolderPage {
            return 1
        }
        guard pageWidth > 0 else { return page == activeFolderPage ? 1 : 0 }
        let dragProgress = folderPagerDragOffset / pageWidth
        let distance = abs(CGFloat(page - activeFolderPage) + dragProgress)
        let visibility = max(0, 1 - distance)
        return Double(min(1, visibility))
    }

    /// Clamps folder page index to valid range.
    private func folderClampPageIndex(_ index: Int) -> Int {
        guard activeFolderPageCount > 0 else { return 0 }
        return min(max(index, 0), activeFolderPageCount - 1)
    }

    /// Safely clamps a page index into the available range.
    private func clampPageIndex(_ index: Int) -> Int {
        guard pageCount > 0 else { return 0 }
        return min(max(index, 0), pageCount - 1)
    }

    /// Aligns page widths to device pixels so adjacent pages keep a stable seam.
    private func pixelAlignedPageSpan(_ span: CGFloat) -> CGFloat {
        pixelAlign(max(span, 1))
    }

    /// Resolves the signed direction of the active pager motion.
    private func pagerMotionDirectionSign() -> Int {
        if pagerDragOffset > 0.01 {
            return -1
        }
        if pagerDragOffset < -0.01 {
            return 1
        }

        switch pageDirection {
        case .forward:
            return -1
        case .backward:
            return 1
        }
    }

    /// Resolves the page that should stay attached to the current page during a transition.
    private func pagingCompanionPage(current: Int, total: Int, dragOffset: CGFloat, isPaging: Bool) -> Int? {
        guard total > 1 else { return nil }
        guard isPaging else { return nil }

        let candidate: Int? = {
            if dragOffset > 0.01 {
                return current - 1
            }
            if dragOffset < -0.01 {
                return current + 1
            }

            switch pageDirection {
            case .forward:
                return current - 1
            case .backward:
                return current + 1
            }
        }()

        guard let candidate, candidate >= 0, candidate < total else { return nil }
        return candidate
    }

    /// Keeps pages fully opaque while they remain on-screen so outgoing/incoming grids read as one slide.
    private func pageOpacity(for page: Int, pageSpan: CGFloat) -> Double {
        let current = clampPageIndex(currentPage)
        guard isPagerTransitionActive else {
            return page == current ? 1 : 0
        }

        let span = max(pageSpan, 1)
        let dragProgress = pagerDragOffset / span
        let translatedDistance = abs(CGFloat(page - current) + dragProgress)
        if translatedDistance <= 1 {
            let visibility = max(0, 1 - translatedDistance)
            let minimumVisibleOpacity: CGFloat = 0
            return Double(minimumVisibleOpacity + (1 - minimumVisibleOpacity) * visibility)
        }
        let fadeRange: CGFloat = 0.12
        let visibility = max(0, 1 - ((translatedDistance - 1) / fadeRange))
        return Double(min(1, visibility))
    }

    /// Computes subtle scale transform for adjacent pages during scrolling.
    private func pageScale(for page: Int, pageSpan: CGFloat) -> CGFloat {
        // Keep pages at full scale during paging to avoid unintended zoom/stacking effects.
        return 1
    }

    private var shouldRasterizeGridPages: Bool {
        abs(pagerDragOffset) > pageRasterizationThreshold || isPageSwitchAnimationActive
    }

    /// Returns only the currently focused page and its immediate neighbors to keep gesture FPS high.
    private func visiblePageIndices(total: Int) -> [Int] {
        guard total > 0 else { return [] }
        let current = clampPageIndex(currentPage)
        guard isPagerTransitionActive else {
            return [current - 1, current, current + 1].filter { $0 >= 0 && $0 < total }
        }

        let pageSpan = max(pagerViewportWidth, 1)
        let direction = pagerMotionDirectionSign()
        let progress = abs(pagerDragOffset) / pageSpan
        let extraReach = progress >= 1.02 ? min(2, Int(progress.rounded(.down))) : 0
        var pages = [current]
        if let companion = pagingCompanionPage(
            current: current,
            total: total,
            dragOffset: pagerDragOffset,
            isPaging: true
        ) {
            pages.append(companion)
        }
        if extraReach > 0 {
            for step in 2...(extraReach + 1) {
                pages.append(current + direction * step)
            }
        }

        return Array(Set(pages))
            .filter { $0 >= 0 && $0 < total }
            .sorted()
    }

    /// Extracts folder items from a mixed item list.
    private nonisolated static func collectFolders(from items: [LauncherItem]) -> [FolderItem] {
        items.compactMap {
            if case .folder(let f) = $0 { return f } else { return nil }
        }
    }

    /// Flattens mixed launcher items into a simple app list.
    private nonisolated static func collectApps(from items: [LauncherItem]) -> [AppItem] {
        var seen = Set<UUID>()
        var apps: [AppItem] = []
        for item in items {
            switch item {
            case .app(let app):
                if seen.insert(app.id).inserted {
                    apps.append(app)
                }
            case .folder(let folder):
                for app in folder.apps where seen.insert(app.id).inserted {
                    apps.append(app)
                }
            }
        }
        return apps
    }

    /// Triggers icon prewarming for a specific page when eligible.
    private func prewarmPageIfNeeded(_ pageIndex: Int) {
        guard let onPageSwitchPrewarm else { return }
        guard pageCount > 0 else { return }
        guard pageIndex != currentPage else { return }
        guard pageIndex >= 0 && pageIndex < pageCount else { return }
        guard isClosingLauncher == false else { return }
        guard prewarmedPageTokens.insert(pageIndex).inserted else { return }
        let sizes = displayPageSizes
        let items = itemsForPage(pageIndex, sizes: sizes)
        let apps = Self.collectApps(from: items)
        guard apps.isEmpty == false else { return }
        onPageSwitchPrewarm(apps)

        // Also warm FolderPreviewCache for any folders on this page so folder tile icons
        // are cache-hot before the page slides in, preventing main-thread resize stalls.
        let folders = Self.collectFolders(from: items)
        if folders.isEmpty == false {
            let dim = lastKnownIconDimension
            for folder in folders {
                warmFolderPreviewIcons(for: folder, iconDimension: dim)
            }
        }
    }

    /// Starts first-page render timing instrumentation once.
    private func beginFirstPageRenderIfNeeded() {
        guard hasRecordedFirstPageRender == false else { return }
        guard firstPageRenderSignpostID == .invalid else { return }
        firstPageRenderSignpostID = Self.beginSignpost("FirstPageRender")
    }

    /// Records first-page render completion marker once content is drawn.
    private func recordFirstPageRenderIfNeeded() {
        guard hasRecordedFirstPageRender == false else { return }
        guard firstPageRenderSignpostID != .invalid else { return }
        Self.endSignpost("FirstPageRender", id: firstPageRenderSignpostID)
        firstPageRenderSignpostID = .invalid
        hasRecordedFirstPageRender = true
    }

    /// Publishes apps visible on active/adjacent pages to external warmup callbacks.
    private func notifyVisiblePagesChanged() {
        guard let onVisiblePagesChanged else { return }
        visiblePagesTask?.cancel()
        let sizes = displayPageSizes
        let pages = visiblePageIndices(total: pageCount)
        let pageItems = pages.map { itemsForPage($0, sizes: sizes) }
        let delay: UInt64 = isPageSwitchAnimationActive
            ? UInt64((Self.pageSwitchDuration + 0.06) * 1_000_000_000)
            : visiblePagesDebounceNanoseconds
        visiblePagesTask = Task(priority: .utility) {
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            guard Task.isCancelled == false else { return }
            let apps = await Task.detached(priority: .utility) {
                var flattened: [AppItem] = []
                for items in pageItems {
                    flattened.append(contentsOf: Self.collectApps(from: items))
                }
                var seen = Set<UUID>()
                return flattened.filter { seen.insert($0.id).inserted }
            }.value
            await MainActor.run {
                guard Task.isCancelled == false else { return }
                onVisiblePagesChanged(apps)
            }
        }
    }

    /// Resolves the active drag modifier behavior for root-grid drags.
    private func currentDragModifierMode() -> DragModifierMode {
        if isMultiSelectionDragActive {
            return .folderMerge
        }

        let flags = NSApp?.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
        if flags.contains(.option) {
            return .folderMerge
        }
        if flags.contains(.shift) {
            return .swap
        }
        return .normal
    }

    /// Reacts to modifier changes that switch between reorder, swap, and folder-merge drag behavior.
    private func handleDragModifierChange(_ mode: DragModifierMode) {
        guard draggedItem != nil else {
            isDragModifierSnapActive = false
            pendingModifierPreviewReset = false
            activeDragModifierMode = .normal
            return
        }
        guard isMultiSelectionDragActive == false else {
            return
        }

        guard mode != activeDragModifierMode else { return }
        activeDragModifierMode = mode

        if mode.suppressesLiveReorder {
            isDragModifierSnapActive = true
            lastLiveReorderTargetIndex = nil
            pendingModifierPreviewReset = mode == .swap
            restoreDraggedLayoutSnapshot()
        } else {
            isDragModifierSnapActive = false
            pendingModifierPreviewReset = false
        }
    }

    /// Restores the captured layout snapshot for the current drag so modifier modes start from a stable grid.
    private func restoreDraggedLayoutSnapshot() {
        guard let snapshot = dragOriginItemsSnapshot else {
            snapDraggedItemToOrigin()
            return
        }

        forceNoGridAnimationDuringDragReset = true
        let transaction = Transaction(animation: nil)
        withTransaction(transaction) {
            orderedItems = snapshot
            if let sizes = dragOriginPageSizesSnapshot {
                pageSizes = sizes
            }
        }
        DispatchQueue.main.async {
            forceNoGridAnimationDuringDragReset = false
        }
    }

    /// Builds an animated two-tile preview swap from the original drag snapshot.
    @discardableResult
    private func previewSwapItem(
        _ item: LauncherItem,
        to targetIndex: Int,
        animation: Animation? = nil
    ) -> Int? {
        guard let snapshot = dragOriginItemsSnapshot else {
            return reorderItem(
                item,
                to: targetIndex,
                preferSwap: true,
                animated: true,
                animation: animation
            )
        }
        guard let originalIndex = snapshot.firstIndex(of: item) else { return nil }
        guard snapshot.indices.contains(targetIndex), targetIndex != originalIndex else { return nil }

        var updated = snapshot
        updated.swapAt(originalIndex, targetIndex)

        withAnimation(animation ?? liveReorderSpringAnimation) {
            orderedItems = updated
            if let sizes = dragOriginPageSizesSnapshot {
                pageSizes = sizes
            }
        }
        return targetIndex
    }

    /// Snaps currently dragged item back to captured origin slot.
    private func snapDraggedItemToOrigin() {
        guard
            let draggedItem,
            let originIndex = dragOriginIndex,
            let currentIndex = orderedItems.firstIndex(of: draggedItem),
            currentIndex != originIndex
        else {
            return
        }

        _ = reorderItem(draggedItem, to: originIndex, animated: false)
    }

    /// Captures initial drag index for modifier-triggered snapback.
    private func captureDragOrigin(for item: LauncherItem) {
        dragOriginIndex = orderedItems.firstIndex(of: item)
        dragOriginItemsSnapshot = orderedItems
        dragOriginPageSizesSnapshot = activePageSizes(for: orderedItems.count)
        isDragModifierSnapActive = false
        activeDragModifierMode = .normal
        pendingModifierPreviewReset = false
        lastLiveReorderTargetIndex = nil
    }

    /// Convenience accessor for the currently dragged app, if any.
    private func currentDraggedApp() -> AppItem? {
        guard case let .app(app) = draggedItem else { return nil }
        return app
    }

    /// Reorders an item with optional animation and page-size updates.
    @discardableResult
    private func reorderItem(
        _ item: LauncherItem,
        to targetIndex: Int,
        preferSwap: Bool = false,
        animated: Bool = true,
        targetPageHint: Int? = nil,
        animation: Animation? = nil
    ) -> Int? {
        guard let originalIndex = orderedItems.firstIndex(of: item) else { return nil }
        enterPerformanceShedding(duration: 0.6, cancelHeavyWork: false)
        let currentSizes = activePageSizes(for: orderedItems.count)
        var updated = orderedItems
        if preferSwap,
           targetIndex < updated.count,
           targetIndex >= 0,
           targetIndex != originalIndex {
            updated.swapAt(originalIndex, targetIndex)
            if animated {
                withAnimation(animation ?? gridSpringAnimation) {
                    orderedItems = updated
                }
            } else {
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
            if animated {
                withAnimation(animation ?? gridSpringAnimation) {
                    orderedItems = updated
                }
            } else {
                orderedItems = updated
            }
            persistOrderChange(using: afterInsertSizes)
            return boundedIndex
        }
    }

    /// Convenience reorder entrypoint using default animation behavior.
    @discardableResult
    private func reorderItem(_ item: LauncherItem, to targetIndex: Int) -> Int? {
        reorderItem(item, to: targetIndex, preferSwap: false)
    }

    /// Reorders an app within a folder, keeping the active overlay in sync.
    private func reorderApp(
        _ app: AppItem,
        inFolderWithID folderID: UUID,
        to targetIndex: Int,
        animated: Bool = true,
        animation: Animation? = nil
    ) {
        guard let folderIndex = orderedItems.firstIndex(where: { item in
            if case let .folder(folder) = item {
                return folder.id == folderID
            }
            return false
        }) else { return }

        guard case var .folder(folder) = orderedItems[folderIndex] else { return }
        guard let originalIndex = folder.apps.firstIndex(of: app) else { return }
        guard targetIndex != originalIndex else { return }
        enterPerformanceShedding(duration: 0.6, cancelHeavyWork: false)

        var apps = folder.apps
        apps.remove(at: originalIndex)

        let boundedIndex = max(0, min(targetIndex, apps.count))
        apps.insert(app, at: boundedIndex)

        folder.apps = apps
        updateFolder(folder, at: folderIndex, animated: animated, animation: animation)
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
            if activeFolder?.id == folder.id {
                shouldSkipActiveFolderChangeEffects = true
            }
            activeFolder = folder
        }
        currentPage = folderIndex / max(pageCapacity, 1)
        pagerDragOffset = 0
        persistOrderChange(using: pageSizes)
    }

    /// Updates a folder in the ordered list and propagates the change outward.
    private func updateFolder(
        _ folder: FolderItem,
        at index: Int? = nil,
        animated: Bool = true,
        animation: Animation? = nil
    ) {
        guard let idx = index ?? orderedItems.firstIndex(where: { item in
            if case let .folder(existing) = item {
                return existing.id == folder.id
            }
            return false
        }) else { return }

        var updated = orderedItems
        updated[idx] = .folder(folder)
        if animated {
            withAnimation(animation ?? gridSpringAnimation) {
                orderedItems = updated
                if activeFolder?.id == folder.id {
                    shouldSkipActiveFolderChangeEffects = true
                }
                activeFolder = folder
            }
        } else {
            orderedItems = updated
            if activeFolder?.id == folder.id {
                shouldSkipActiveFolderChangeEffects = true
            }
            activeFolder = folder
        }
        persistOrderChange()
    }

    /// Lifts an app out of an open folder so it can participate in root-grid drag flow.
    @discardableResult
    private func extractAppFromFolderForDrag() -> LauncherItem? {
        guard let context = folderDragContext else { return nil }
        guard let removal = removeAppFromHierarchy(
            context.app,
            updatePageSizes: false,
            normalizePageSizes: false
        ) else { return nil }
        var updated = removal.items
        let insertionIndex = min(removal.suggestedIndex, updated.count)
        let extractedApp = removal.app
        updated.insert(.app(extractedApp), at: insertionIndex)

        withAnimation(gridSpringAnimation) {
            orderedItems = updated
            activeFolder = nil
        }

        let targetPageHint = pageIndex(forLinearIndex: insertionIndex, sizes: removal.pageSizesAfterRemoval)
            ?? removal.pageSizesAfterRemoval.count
        let finalSizes = pageSizesAfterInsertion(
            removal.pageSizesAfterRemoval,
            insertingIndex: insertionIndex,
            resultingCount: updated.count,
            targetPageHint: targetPageHint
        )
        pageSizes = finalSizes
        persistOrderChange(using: finalSizes)
        folderDragContext = nil
        return .app(extractedApp)
    }

    /// Converts an active folder drag into a root-level drag by pulling the app out and closing the overlay.
    private func dragItemOutOfFolderIfNeeded() {
        guard activeFolder != nil else { return }
        if let extracted = extractAppFromFolderForDrag() {
            draggedItem = extracted
            captureDragOrigin(for: extracted)
            draggedFolderApp = nil
        }
    }

    /// Opens a folder overlay mid-drag so the app can be dropped into a specific position.
    private func openFolderForDrag(_ folder: FolderItem, draggedItem: LauncherItem) {
        guard case .app = draggedItem else { return }
        primeFolderOverlayOpenAnimation()
        folderPreviewMatchID = nil
        folderIconWaveToggle = false
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

        let isModifierMode = currentDragModifierMode() == .folderMerge
        if folderHoverTargetID == target.id && folderHoverInModifierMode == isModifierMode {
            return
        }

        cancelFolderHover()
        folderHoverInModifierMode = isModifierMode

        let action: () -> Void
        let delay: TimeInterval

        switch target {
        case .app:
            action = { mergeItemsIfNeeded(dragged: dragged, onto: target) }
            delay = isModifierMode ? 1.0 : 0.6
        case .folder(let folder):
            if isModifierMode {
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
        folderHoverInModifierMode = false
    }

    /// Combines the dragged item with the target item to form or append to a folder.
    private func mergeItemsIfNeeded(dragged: LauncherItem, onto target: LauncherItem) {
        guard dragged.id != target.id else { return }

        enterPerformanceShedding(duration: 0.9, cancelHeavyWork: true)
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

    /// Merges the current multi-selection items into the provided folder target.
    private func mergeMultiSelection(into target: LauncherItem) {
        guard case let .folder(folderTarget) = target else { return }
        let selectionEntries = orderedItems.enumerated().compactMap { index, item -> (index: Int, item: LauncherItem)? in
            guard multiSelectedItemIDs.contains(item.id) else { return nil }
            guard item.id != folderTarget.id else { return nil }
            return (index: index, item: item)
        }
        guard selectionEntries.isEmpty == false else { return }

        var updated = orderedItems
        var workingSizes = activePageSizes(for: orderedItems.count)
        var currentCount = orderedItems.count

        let removalIndices = selectionEntries.map(\.index).sorted(by: >)
        for removalIndex in removalIndices {
            updated.remove(at: removalIndex)
            workingSizes = pageSizesAfterRemoval(workingSizes, removingIndex: removalIndex, currentCount: currentCount)
            currentCount -= 1
        }

        guard let targetIndex = updated.firstIndex(where: { item in
            if case let .folder(existing) = item {
                return existing.id == folderTarget.id
            }
            return false
        }) else {
            return
        }

        guard case var .folder(updatedFolder) = updated[targetIndex] else { return }
        for entry in selectionEntries {
            switch entry.item {
            case .app(let app):
                updatedFolder.apps.append(app)
            case .folder(let otherFolder):
                updatedFolder.apps.append(contentsOf: otherFolder.apps)
            }
        }
        updated[targetIndex] = .folder(updatedFolder)

        withAnimation(gridSpringAnimation) {
            orderedItems = updated
        }
        persistOrderChange(using: workingSizes)
        updatePageAfterDrop(at: targetIndex)

        if let active = activeFolder {
            if active.id == updatedFolder.id {
                activeFolder = updatedFolder
            } else if selectionEntries.contains(where: { $0.item.id == active.id }) {
                closeActiveFolder()
            }
        }

        finalizeBulkSelectionAction()
    }

    /// Keeps the visible page pinned to where the moved app now lives.
    private func updatePageAfterDrop(at index: Int?) {
        let sizes = activePageSizes(for: orderedItems.count)
        let hintedPage = pendingDropPage
        pendingDropPage = nil
        let computedPage = index.flatMap { pageIndex(forLinearIndex: $0, sizes: sizes) }
        let targetPage = hintedPage ?? computedPage
        guard let page = targetPage else { return }
        let maxPage = max(pageCount - 1, 0)
        let boundedTarget = min(max(page, 0), maxPage)
        let dir: PageShiftDirection = boundedTarget >= currentPage ? .forward : .backward
        performAnimatedPageSwitch(to: boundedTarget, direction: dir)
    }

    /// Keeps the visible page index inside the bounds of the current arrangement.
    private func ensureCurrentPageWithinBounds() {
        let maxPage = max(fullPageCount - 1, 0)
        let boundedPage = min(currentPage, maxPage)
        if boundedPage != currentPage {
            let dir: PageShiftDirection = boundedPage >= currentPage ? .forward : .backward
            performAnimatedPageSwitch(to: boundedPage, direction: dir)
        } else {
            pagerDragOffset = 0
        }
    }

    /// Generates the friendly page indicator label.
    private var pageIndicatorTitle: String {
        if filteredItemList.isEmpty {
            return orderedItems.isEmpty
            ? String(localized: "GridNoItemsFoundLabel")
            : String(localized: "GridNoMatchingItemsLabel")
        }
        return String.localizedStringWithFormat(String(localized: "GridPageIndicatorFormat"), currentPage + 1, pageCount)
    }

    /// Resolves effective page sizes for current item count and fill-gaps mode.
    private func activePageSizes(for itemCount: Int) -> [Int] {
        guard itemCount > 0 else { return [] }
        if fillsGapsAutomatically {
            return densePageSizes(for: itemCount)
        }
        let normalized = normalizePageSizes(pageSizes, itemCount: itemCount)
        return normalized.isEmpty ? densePageSizes(for: itemCount) : normalized
    }

    /// Produces dense page sizes using current grid capacity.
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

    /// Resolves page target used when inserting/moving items between pages.
    private func resolveTargetPageForInsertion(
        hint: Int?,
        sizes: [Int]
    ) -> Int {
        let normalizedHint = max(hint ?? sizes.count, 0)
        guard pageCapacity > 0 else {
            return normalizedHint
        }
        if normalizedHint < sizes.count {
            return sizes[normalizedHint] < pageCapacity ? normalizedHint : sizes.count
        }
        return sizes.count
    }

    /// Normalizes page-size arrays to match item count and grid capacity.
    private func normalizePageSizes(_ raw: [Int], itemCount: Int) -> [Int] {
        guard itemCount > 0, pageCapacity > 0 else { return [] }

        var normalized = raw.compactMap { value -> Int? in
            let bounded = min(max(value, 0), pageCapacity)
            return bounded > 0 ? bounded : nil
        }
        if normalized.isEmpty {
            normalized.append(min(itemCount, pageCapacity))
        }

        let total = normalized.reduce(0, +)
        if total < itemCount {
            var remaining = itemCount - total
            while remaining > 0 {
                let portion = min(pageCapacity, remaining)
                normalized.append(portion)
                remaining -= portion
            }
        } else if total > itemCount {
            var surplus = total - itemCount
            for index in stride(from: normalized.count - 1, through: 0, by: -1) where surplus > 0 {
                let reduction = min(normalized[index], surplus)
                normalized[index] -= reduction
                surplus -= reduction
            }

            while let last = normalized.last, last == 0 {
                normalized.removeLast()
            }
        }

        return normalized
    }

    /// Computes linear start index for a page within page-size partitions.
    private func pageStartIndex(for page: Int, sizes: [Int]) -> Int {
        guard page > 0, sizes.isEmpty == false else { return 0 }
        let safePage = min(page, sizes.count)
        return sizes.prefix(safePage).reduce(0, +)
    }

    /// Locates which page contains a given linear item index.
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

    /// Returns insertion index at end of requested page.
    private func insertionIndexForPage(_ page: Int, sizes: [Int]) -> Int {
        guard sizes.isEmpty == false else { return 0 }
        let boundedPage = max(page, 0)
        if boundedPage >= sizes.count {
            return sizes.reduce(0, +)
        }
        let start = pageStartIndex(for: boundedPage, sizes: sizes)
        return start + sizes[boundedPage]
    }

    /// Computes insertion index for page-level drop targets.
    private func pageDropInsertionIndex(for page: Int) -> Int {
        LauncherGridConfiguration.insertionIndex(
            for: page,
            itemsCount: orderedItems.count,
            pageCapacity: pageCapacity
        )
    }

    /// Returns updated page sizes after removing one item from a page/index.
    private func pageSizesAfterRemoval(
        _ sizes: [Int],
        removingIndex: Int,
        currentCount: Int,
        normalize: Bool = true
    ) -> [Int] {
        if fillsGapsAutomatically {
            return densePageSizes(for: max(currentCount - 1, 0))
        }

        guard let page = pageIndex(forLinearIndex: removingIndex, sizes: sizes) else {
            let trimmed = trimTrailingEmptyPages(sizes)
            return normalize ? normalizePageSizes(trimmed, itemCount: max(currentCount - 1, 0)) : sizes
        }
        var updated = sizes
        updated[page] = max(updated[page] - 1, 0)
        if normalize {
            updated = trimTrailingEmptyPages(updated)
            return normalizePageSizes(updated, itemCount: max(currentCount - 1, 0))
        }
        return updated
    }

    /// Returns updated page sizes after inserting one item into a target page/index.
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
        let pageHint = max(targetPageHint ?? pageIndex(forLinearIndex: insertingIndex, sizes: updated) ?? updated.count, 0)
        let targetPage = resolveTargetPageForInsertion(hint: pageHint, sizes: updated)
        if targetPage >= updated.count {
            updated.append(contentsOf: Array(repeating: 0, count: targetPage - updated.count + 1))
        }
        updated[targetPage] += 1
        return trimTrailingEmptyPages(updated)
    }

    /// Removes trailing zero-sized pages.
    private func trimTrailingEmptyPages(_ sizes: [Int]) -> [Int] {
        var mutable = sizes
        while let last = mutable.last, last == 0 {
            mutable.removeLast()
        }
        return mutable
    }

    /// Persists current item ordering and optional explicit page sizes.
    private func persistOrderChange(using updatedSizes: [Int]? = nil) {
        let normalized = updatedSizes
            ?? (fillsGapsAutomatically ? densePageSizes(for: orderedItems.count) : normalizePageSizes(pageSizes, itemCount: orderedItems.count))
        pageSizes = normalized
        onItemOrderChange?(orderedItems, normalized)
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasActiveSearchQuery: Bool {
        normalizedSearchText.isEmpty == false
    }

    private var isSearchModeActive: Bool {
        hasActiveSearchQuery && filteredItemList.isEmpty == false
    }

    private var showSearchLoadingIndicator: Bool {
        hasActiveSearchQuery && isSearchLoading
    }

    private var activeSearchSelectionIndex: Int? {
        guard isSearchModeActive else { return nil }
        guard let preferred = searchSelectionIndex else { return nil }
        let bounded = min(max(preferred, 0), filteredItemList.count - 1)
        return bounded
    }

    private var activeSearchSelectionItem: LauncherItem? {
        guard let index = activeSearchSelectionIndex else { return nil }
        guard filteredItemList.indices.contains(index) else { return nil }
        return filteredItemList[index]
    }

    private var filteredItemList: [LauncherItem] {
        cachedFilteredItems
    }

    /// Debounces expensive search metadata rebuild work.
    private func scheduleSearchMetadataRebuild(for items: [LauncherItem]) {
        searchMetadataTask?.cancel()
        let snapshot = items
        searchMetadataTask = Task(priority: .utility) {
            try? await Task.sleep(nanoseconds: searchMetadataDebounceNanoseconds)
            guard Task.isCancelled == false else { return }
            let metadata = await Task.detached(priority: .utility) {
                Self.buildSearchMetadata(from: snapshot)
            }.value
            await MainActor.run {
                guard Task.isCancelled == false else { return }
                searchMetadataByAppID = metadata.apps
                folderSearchMetadataByID = metadata.folders
                if hasActiveSearchQuery {
                    updateFilteredItems(using: snapshot)
                }
            }
        }
    }

    /// Applies asynchronously computed search results on main actor state.
    private func applySearchResults(_ results: [LauncherItem]) {
        cachedFilteredItems = results
        if pendingSearchPageReset {
            currentPage = 0
            pageDirection = .forward
            pagerDragOffset = 0
        }
        pendingSearchPageReset = false
        clampSearchSelectionIfNeeded()
        alignSearchSelectionWithCurrentPageIfNeeded()
        notifyVisiblePagesChanged()
    }

    /// Debounces query-driven filtering updates.
    private func scheduleSearchUpdate() {
        searchDebounceTask?.cancel()
        searchDebounceTask = nil

        guard hasActiveSearchQuery else {
            cancelSearchTasks()
            isSearchLoading = false
            lastNormalizedSearchQuery = ""
            applySearchResults(orderedItems)
            return
        }

        isSearchLoading = true
        searchDebounceTask = Task {
            try? await Task.sleep(nanoseconds: searchInputDebounceNanoseconds)
            guard Task.isCancelled == false else { return }
            await MainActor.run {
                updateFilteredItems()
            }
        }
    }

    /// Recomputes filtered launcher items based on current query/metadata.
    private func updateFilteredItems(using itemsOverride: [LauncherItem]? = nil) {
        searchDebounceTask?.cancel()
        searchDebounceTask = nil
        let items = itemsOverride ?? orderedItems
        let query = normalizedSearchText
        let queryContext = SearchQueryContext(rawQuery: query)
        let normalizedQuery = queryContext.normalizedQuery
        searchTask?.cancel()
        searchTask = nil

        guard hasActiveSearchQuery else {
            isSearchLoading = false
            lastNormalizedSearchQuery = ""
            applySearchResults(items)
            return
        }

        if normalizedQuery == lastNormalizedSearchQuery {
            isSearchLoading = false
            return
        }

        isSearchLoading = true
        searchRequestID &+= 1
        let requestID = searchRequestID
        let appMetadata = searchMetadataByAppID
        let folderMetadata = folderSearchMetadataByID
        let shouldFilterFromCache = itemsOverride == nil
            && lastNormalizedSearchQuery.isEmpty == false
            && normalizedQuery.hasPrefix(lastNormalizedSearchQuery)
            && cachedFilteredItems.isEmpty == false
        let filterBaseItems = shouldFilterFromCache ? cachedFilteredItems : items

        searchTask = Task(priority: .userInitiated) {
            let detachedTask = Task.detached(priority: .userInitiated) {
                Self.filterItems(
                    items: filterBaseItems,
                    queryContext: queryContext,
                    appMetadata: appMetadata,
                    folderMetadata: folderMetadata
                )
            }
            let results = await withTaskCancellationHandler {
                await detachedTask.value
            } onCancel: {
                detachedTask.cancel()
            }

            do {
                try Task.checkCancellation()
            } catch {
                return
            }

            await MainActor.run {
                guard requestID == searchRequestID else { return }
                isSearchLoading = false
                searchTask = nil
                lastNormalizedSearchQuery = normalizedQuery
                applySearchResults(results)
            }
        }
    }

    /// Cancels pending search and metadata tasks.
    private func cancelSearchTasks() {
        searchDebounceTask?.cancel()
        searchDebounceTask = nil
        searchTask?.cancel()
        searchTask = nil
    }

    /// Pure filtering/sorting implementation for background search tasks.
    nonisolated private static func filterItems(
        items: [LauncherItem],
        queryContext: SearchQueryContext,
        appMetadata: [UUID: SearchableAppEntry],
        folderMetadata: [UUID: SearchableFolderEntry]
    ) -> [LauncherItem] {
        let signpostID = Self.beginSignpost("SearchFilter")
        defer { Self.endSignpost("SearchFilter", id: signpostID) }
        guard queryContext.isEmpty == false else { return items }
        guard queryContext.queryVariants.isEmpty == false else { return items }
        var buckets = Array(repeating: [LauncherItem](), count: 6)
        var seenAppIDs = Set<UUID>()
        seenAppIDs.reserveCapacity(items.count)
        let estimatedBucketSize = max(items.count / max(buckets.count, 1), 1)
        for index in buckets.indices {
            buckets[index].reserveCapacity(estimatedBucketSize)
        }

        for item in items {
            if Task.isCancelled {
                break
            }
            switch item {
            case .app(let app):
                if let score = appMatchScore(
                    app,
                    queryContext: queryContext,
                    metadata: appMetadata
                ),
                   seenAppIDs.insert(app.id).inserted,
                   buckets.indices.contains(score) {
                    buckets[score].append(.app(app))
                }
            case .folder(let folder):
                let folderNameMatches = folderMatchesQuery(queryContext, folderID: folder.id, metadata: folderMetadata)
                for app in folder.apps {
                    if Task.isCancelled {
                        break
                    }
                    let appScore = appMatchScore(
                        app,
                        queryContext: queryContext,
                        metadata: appMetadata
                    )
                    let score: Int? = {
                        guard let appScore else { return nil }
                        if folderNameMatches {
                            return min(appScore, 2)
                        }
                        return appScore
                    }()
                    if let score,
                       seenAppIDs.insert(app.id).inserted,
                       buckets.indices.contains(score) {
                        buckets[score].append(.app(app))
                    }
                }
            }
        }

        return buckets.flatMap { $0 }
    }

    /// Scores app matches for ranking (higher is better).
    nonisolated private static func appMatchScore(
        _ app: AppItem,
        queryContext: SearchQueryContext,
        metadata: [UUID: SearchableAppEntry]
    ) -> Int? {
        if let entry = metadata[app.id] {
            return matchScore(
                entry: entry,
                queryVariants: queryContext.queryVariants,
                tokenVariants: queryContext.tokenVariants,
                fallbackQuery: queryContext.normalizedQuery
            )
        }
        return app.matches(query: queryContext.normalizedQuery) ? 4 : nil
    }

    /// Builds reusable normalized search metadata from launcher items.
    nonisolated private static func buildSearchMetadata(from items: [LauncherItem]) -> (
        apps: [UUID: SearchableAppEntry],
        folders: [UUID: SearchableFolderEntry]
    ) {
        var appMetadata: [UUID: SearchableAppEntry] = [:]
        var folderMetadata: [UUID: SearchableFolderEntry] = [:]

        let record: (AppItem) -> Void = { app in
            appMetadata[app.id] = buildSearchEntry(for: app)
        }

        for item in items {
            switch item {
            case .app(let app):
                record(app)
            case .folder(let folder):
                folderMetadata[folder.id] = buildFolderEntry(for: folder)
                for app in folder.apps {
                    record(app)
                }
            }
        }

        return (apps: appMetadata, folders: folderMetadata)
    }

    /// Converts app model into normalized search entry payload.
    nonisolated private static func buildSearchEntry(for app: AppItem) -> SearchableAppEntry {
        let normalizedNames = uniqueSearchValues(from: app.searchableNames.flatMap { normalizedSearchVariants(for: $0) })
            .filter { $0.isEmpty == false }
        let tokenizedNames = normalizedNames
            .map { tokenizeSearchValue($0) }
            .filter { $0.isEmpty == false }
        let initialisms = uniqueSearchValues(from: tokenizedNames.compactMap { tokens in
            let initials = tokens.compactMap { $0.first }
            return initials.isEmpty ? nil : String(initials)
        })
        let normalizedBundle = primarySearchCacheKey(for: app.bundleIdentifier)
        return SearchableAppEntry(
            normalizedNames: normalizedNames,
            tokenizedNames: tokenizedNames,
            initialisms: initialisms,
            normalizedBundleIdentifier: normalizedBundle
        )
    }

    /// Converts folder model into normalized search entry payload.
    nonisolated private static func buildFolderEntry(for folder: FolderItem) -> SearchableFolderEntry {
        let normalizedNames = uniqueSearchValues(from: normalizedSearchVariants(for: folder.name))
            .filter { $0.isEmpty == false }
        return SearchableFolderEntry(normalizedNames: normalizedNames)
    }

    /// Checks whether folder metadata matches the active query tokens.
    nonisolated private static func folderMatchesQuery(
        _ context: SearchQueryContext,
        folderID: UUID,
        metadata: [UUID: SearchableFolderEntry]
    ) -> Bool {
        guard let entry = metadata[folderID] else { return false }
        return context.queryVariants.contains { query in
            entry.normalizedNames.contains { $0.contains(query) }
        }
    }

    /// Computes string/token match score for ranking search hits.
    nonisolated private static func matchScore(
        entry: SearchableAppEntry,
        queryVariants: [String],
        tokenVariants: [[String]],
        fallbackQuery: String
    ) -> Int? {
        var bestScore: Int?
        for (index, query) in queryVariants.enumerated() {
            let tokens = tokenVariants[index]
            if let score = matchScore(entry: entry, query: query, tokens: tokens) {
                if let current = bestScore {
                    bestScore = min(current, score)
                } else {
                    bestScore = score
                }
                if bestScore == 0 {
                    break
                }
            }
        }

        if bestScore == nil, fallbackQuery.isEmpty == false {
            if entry.normalizedNames.contains(where: { $0.contains(fallbackQuery) }) {
                bestScore = 4
            } else if entry.normalizedBundleIdentifier.contains(fallbackQuery) {
                bestScore = 5
            }
        }

        return bestScore
    }

    /// Variant scoring for app entries used during query ranking.
    nonisolated private static func matchScore(
        entry: SearchableAppEntry,
        query: String,
        tokens: [String]
    ) -> Int? {
        guard query.isEmpty == false else { return nil }

        if entry.normalizedNames.contains(where: { $0 == query }) {
            return 0
        }

        if entry.normalizedNames.contains(where: { $0.hasPrefix(query) }) {
            return 1
        }

        if tokens.isEmpty == false {
            for nameTokens in entry.tokenizedNames {
                if tokensMatch(nameTokens: nameTokens, queryTokens: tokens) {
                    return 2
                }
            }
        }

        if entry.initialisms.contains(where: { $0.hasPrefix(query) }) {
            return 3
        }

        if entry.normalizedNames.contains(where: { $0.contains(query) }) {
            return 4
        }

        if entry.normalizedBundleIdentifier.contains(query) {
            return 5
        }

        return nil
    }

    /// Fast token containment check for exact-token search mode.
    nonisolated private static func tokensMatch(nameTokens: [String], queryTokens: [String]) -> Bool {
        guard queryTokens.isEmpty == false else { return false }
        for queryToken in queryTokens {
            let matches = nameTokens.contains { $0.hasPrefix(queryToken) }
            if matches == false {
                return false
            }
        }
        return true
    }

    /// Deduplicates candidate search strings while preserving order.
    nonisolated private static func uniqueSearchValues(from values: [String]) -> [String] {
        var seen = Set<String>()
        var unique: [String] = []
        unique.reserveCapacity(values.count)

        for value in values {
            guard value.isEmpty == false else { continue }
            let normalized = value.folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: .current
            )
            if seen.insert(normalized).inserted {
                unique.append(value)
            }
        }

        return unique
    }

    /// Tokenizes normalized search text into whitespace-separated terms.
    nonisolated fileprivate static func tokenizeSearchValue(_ value: String) -> [String] {
        let parts = value.components(separatedBy: CharacterSet.alphanumerics.inverted)
        return parts.filter { $0.isEmpty == false }
    }

    /// Produces normalized + latinized variants to support multilingual matching.
    nonisolated fileprivate static func normalizedSearchVariants(for value: String) -> [String] {
        let locales = [Locale.current, Locale(identifier: "en_US_POSIX")]
        var variants: [String] = []
        for locale in locales {
            let normalized = normalizeSearchValue(value, locale: locale)
            if normalized.isEmpty == false {
                variants.append(normalized)
            }
            if let latinized = latinizedSearchValue(value, locale: locale) {
                variants.append(latinized)
            }
        }
        return uniqueSearchValues(from: variants)
    }

    /// Applies case/diacritic/width normalization for stable search keys.
    nonisolated private static func normalizeSearchValue(_ value: String, locale: Locale) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: locale)
    }

    /// Attempts latin transliteration fallback for non-latin scripts.
    nonisolated private static func latinizedSearchValue(_ value: String, locale: Locale) -> String? {
        guard let latin = value.applyingTransform(.toLatin, reverse: false) else { return nil }
        let stripped = latin.applyingTransform(.stripCombiningMarks, reverse: false) ?? latin
        let normalized = normalizeSearchValue(stripped, locale: locale)
        return normalized.isEmpty ? nil : normalized
    }

    /// Computes cache key for tokenization/normalization memoization.
    nonisolated fileprivate static func primarySearchCacheKey(for value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return "" }
        return normalizeSearchValue(trimmed, locale: .current)
    }

    /// Keeps selected search result index inside current result bounds.
    private func clampSearchSelectionIfNeeded() {
        guard isSearchModeActive else {
            searchSelectionIndex = nil
            return
        }
        guard let index = activeSearchSelectionIndex else { return }
        selectSearchResult(at: index, animated: false)
    }

    /// Re-aligns search selection when current page changes.
    private func alignSearchSelectionWithCurrentPageIfNeeded() {
        guard isSearchModeActive else { return }
        let sizes = displayPageSizes
        guard sizes.indices.contains(currentPage) else { return }
        let startIndex = pageStartIndex(for: currentPage, sizes: sizes)
        let endIndex = min(startIndex + sizes[currentPage], filteredItemList.count)

        guard let selection = activeSearchSelectionIndex else { return }

        if selection < startIndex || selection >= endIndex {
            searchSelectionIndex = startIndex
        }
    }

    /// Returns whether a page can accept another item.
    private func pageHasSpace(_ page: Int) -> Bool {
        guard pageCapacity > 0 else { return false }
        let sizes = activePageSizes(for: orderedItems.count)
        guard page < sizes.count else { return true }
        return sizes[page] < pageCapacity
    }

    /// Determines whether wiggle animation is permitted for an item ID.
    private func shouldAllowWiggle(id: UUID) -> Bool {
        guard isArrangementEditingActive else { return false }
        guard hasActiveSearchQuery == false else { return false }
        guard isClosingLauncher == false else { return false }
        guard launchingItemID != id else { return false }
        guard draggedItem?.id != id else { return false }
        guard draggedFolderApp?.id != id else { return false }
        guard currentDraggedApp()?.id != id else { return false }
        return true
    }

    /// Determines whether an item should currently wiggle.
    private func shouldWiggle(item: LauncherItem) -> Bool {
        switch item {
        case .app(let app):
            return shouldAllowWiggle(id: app.id)
        case .folder(let folder):
            return shouldAllowWiggle(id: folder.id)
        }
    }

    /// Produces deterministic wiggle phase/amplitude from item identity.
    private func wiggleMotion(for id: UUID, layout: LauncherLayoutMetrics, isActive: Bool) -> WiggleMotion {
        let seed = Self.wiggleSeed(for: id)
        let dragAttenuation: CGFloat = isReorderDragActive ? 0.6 : 1.0
        let sway = max(layout.iconDimension * wiggleHorizontalSwayFactor * dragAttenuation, 0.7 * dragAttenuation)
        let bob = max(layout.iconDimension * wiggleVerticalBobFactor * dragAttenuation, 0.35 * dragAttenuation)
        let rotation = wiggleRotationDegrees * dragAttenuation

        return WiggleMotion(
            seed: seed,
            isActive: isActive,
            cycle: wiggleCycleDuration,
            rotationDegrees: rotation,
            sway: sway,
            bob: bob,
            anchor: wiggleAnchor
        )
    }

    /// Builds pseudo-random wiggle seed values from stable UUID hash.
    nonisolated private static func wiggleSeed(for id: UUID) -> WiggleSeed {
        let hash = wiggleHash(for: id)
        let phase = wiggleComponent(from: hash, lower: 0, upper: 2 * .pi)
        let intensity = wiggleComponent(from: hash >> 16, lower: 0.9, upper: 1.1)
        let rate = wiggleComponent(from: hash >> 32, lower: 0.92, upper: 1.08)
        return WiggleSeed(phase: phase, intensity: intensity, rate: rate)
    }

    /// Maps a hash fragment into a numeric range for wiggle parameters.
    nonisolated private static func wiggleComponent(from value: UInt64, lower: Double, upper: Double) -> Double {
        let normalized = Double(value & 0xFFFF) / Double(UInt16.max)
        return lower + (upper - lower) * normalized
    }

    /// Creates deterministic 64-bit hash for wiggle parameter generation.
    nonisolated private static func wiggleHash(for id: UUID) -> UInt64 {
        withUnsafeBytes(of: id.uuid) { raw -> UInt64 in
            let bytes = raw.bindMemory(to: UInt8.self)
            var hash: UInt64 = 0xcbf29ce484222325
            for byte in bytes {
                hash ^= UInt64(byte)
                hash &*= 0x100000001b3
            }
            return hash
        }
    }

    /// Computes drag-neighbor transform effect for root grid items.
    private func gridArrangementEffect(for item: LauncherItem) -> ArrangementEffect {
        arrangementEffect(
            isDragged: draggedItem?.id == item.id,
            neighborDistance: gridNeighborDistance(for: item.id)
        )
    }

    /// Computes drag-neighbor transform effect for items in open folder grid.
    private func folderArrangementEffect(for app: AppItem, in folder: FolderItem) -> ArrangementEffect {
        arrangementEffect(
            isDragged: draggedFolderApp?.id == app.id || currentDraggedApp()?.id == app.id,
            neighborDistance: folderNeighborDistance(for: app, in: folder)
        )
    }

    /// Converts drag state and neighbor distance into visual transform parameters.
    private func arrangementEffect(isDragged: Bool, neighborDistance: Int?) -> ArrangementEffect {
        if isDragged {
            return ArrangementEffect(
                scale: 1.08,
                offset: -2.0,
                shadowOpacity: 0.22,
                shadowRadius: 12,
                shadowYOffset: 8
            )
        }

        return ArrangementEffect(
            scale: 1.0,
            offset: 0,
            shadowOpacity: 0,
            shadowRadius: 0,
            shadowYOffset: 0
        )
    }

    /// Returns Manhattan-like distance from current grid reorder target.
    private func gridNeighborDistance(for id: UUID) -> Int? {
        neighborDistance(
            for: id,
            in: orderedItems,
            targetIndex: currentGridReorderTargetIndex()
        )
    }

    /// Returns distance from current folder reorder target for an app.
    private func folderNeighborDistance(for app: AppItem, in folder: FolderItem) -> Int? {
        neighborDistance(
            for: app.id,
            in: folder.apps,
            targetIndex: currentFolderReorderTargetIndex(for: folder)
        )
    }

    /// Resolves active root-grid reorder target index.
    private func currentGridReorderTargetIndex() -> Int? {
        if let live = lastLiveReorderTargetIndex {
            return live
        }
        if let dragged = draggedItem, let index = orderedItems.firstIndex(of: dragged) {
            return index
        }
        return dragOriginIndex
    }

    /// Resolves active reorder target index inside the open folder.
    private func currentFolderReorderTargetIndex(for folder: FolderItem) -> Int? {
        if let live = folderLiveReorderTargetIndex {
            return live
        }
        if let dragged = draggedFolderApp ?? currentDraggedApp(),
           folder.apps.contains(dragged),
           let index = folder.apps.firstIndex(of: dragged) {
            return index
        }
        return nil
    }

    private func neighborDistance<T: Identifiable & Equatable>(
        for id: T.ID,
        in items: [T],
        targetIndex: Int?
    ) -> Int? where T.ID: Equatable {
        guard let targetIndex else { return nil }
        guard let currentIndex = items.firstIndex(where: { $0.id == id }) else { return nil }
        return abs(currentIndex - targetIndex)
    }

    /// Wraps icon rendering with per-item effects and fallback handling.
    @ViewBuilder
    private func iconView(
        for item: LauncherItem,
        layout: LauncherLayoutMetrics,
        allowHeavyWork: Bool = true
    ) -> some View {
        switch item {
        case .app(let app):
            iconForApp(app, layout: layout, allowHeavyWork: allowHeavyWork)
        case .folder(let folder):
            folderIcon(for: folder, layout: layout, allowHeavyWork: allowHeavyWork)
        }
    }

    @ViewBuilder
    /// Resolves icon image for app cells with quality escalation.
    private func iconForApp(
        _ app: AppItem,
        layout: LauncherLayoutMetrics,
        allowHeavyWork: Bool
    ) -> some View {
        let request = baseIconRequest(for: layout)
        let baseIcon = resolvedIcon(for: app, dimension: request.dimension, quality: request.quality) ?? app.iconImage
        let highIcon = highQualityIconOverrides[app.id]
        let baseScale: CGFloat = request.quality == .low ? 0.994 : 1

        let baseLayer = Group {
            if let icon = baseIcon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .scaleEffect(baseScale) // Slightly shrinken low-res placeholders to reduce visible size jump
            } else {
                Image(systemName: "app.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .scaleEffect(baseScale)
            }
        }
        .transaction { transaction in
            transaction.animation = nil
        }

        ZStack {
            baseLayer
            if let detailedIcon = highIcon {
                Image(nsImage: detailedIcon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .transition(.opacity)
            }
        }
        .compositingGroup()
        .animation(.easeInOut(duration: 0.12), value: highIcon != nil)
        .onAppear {
            guard allowHeavyWork else { return }
            requestHighQualityIconIfNeeded(for: app, layout: layout)
        }
    }

    /// Builds the complete app/folder cell chrome.
    private func iconCell(
        for item: LauncherItem,
        layout: LauncherLayoutMetrics,
        allowHeavyWork: Bool
    ) -> some View {
        let isSelected = isMultiSelectModeActive && multiSelectedItemIDs.contains(item.id)
        let shouldWiggleIcon = shouldRasterizeGridPages ? false : shouldWiggle(item: item)
        let selectionShadowOpacity = shouldRasterizeGridPages ? 0 : (isSelected ? 0.28 : 0)
        let selectionShadowRadius: CGFloat = shouldRasterizeGridPages ? 0 : (isSelected ? 10 : 0)
        let selectionShadowYOffset: CGFloat = shouldRasterizeGridPages ? 0 : (isSelected ? 2 : 0)
        let selectionBlendMode: BlendMode = isSelected ? .screen : .normal

        return iconView(for: item, layout: layout, allowHeavyWork: allowHeavyWork)
            .frame(width: layout.iconDimension, height: layout.iconDimension)
            .overlay(selectionHighlight(for: item, layout: layout, isSelected: isSelected))
            .modifier(wiggleMotion(for: item.id, layout: layout, isActive: shouldWiggleIcon))
            .shadow(
                color: Color.accentColor.opacity(selectionShadowOpacity),
                radius: selectionShadowRadius,
                y: selectionShadowYOffset
            )
            .blendMode(selectionBlendMode)
            .animation(.easeInOut(duration: 0.18), value: isSelected)
    }

    @ViewBuilder
    /// Draws selection overlay for keyboard/search/multi-select states.
    private func selectionHighlight(for item: LauncherItem, layout: LauncherLayoutMetrics, isSelected: Bool) -> some View {
        let opacity = isSelected ? 0.92 : 0
        let lineWidth = isSelected ? 2.4 : 0
        switch item {
        case .folder:
            RoundedRectangle(cornerRadius: max(layout.iconDimension * 0.18, 12), style: .continuous)
                .strokeBorder(Color.accentColor.opacity(opacity), lineWidth: lineWidth)
        default:
            RoundedRectangle(cornerRadius: max(layout.iconDimension * 0.32, 14), style: .continuous)
                .strokeBorder(Color.accentColor.opacity(opacity), lineWidth: lineWidth)
        }
    }

    /// Renders floating highlight tile for selected search result.
    private func searchSelectionTile(layout: LauncherLayoutMetrics) -> some View {
        let size = searchSelectionTileSize(for: layout)
        let cornerRadius = searchSelectionCornerRadius(for: layout)
        return VisualEffectBackground(
            material: .hudWindow,
            blendingMode: .withinWindow,
            appearance: NSAppearance(named: .vibrantDark)
        )
        .overlay(
            LinearGradient(
                colors: [
                    Color.accentColor.opacity(0.22),
                    Color.black.opacity(0.26)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .frame(width: size.width, height: size.height)
        .shadow(color: Color.black.opacity(0.32), radius: 18, y: 10)
        .animation(.easeInOut(duration: 0.18), value: activeSearchSelectionIndex)
    }

    /// Computes search selection tile size from active layout metrics.
    private func searchSelectionTileSize(for layout: LauncherLayoutMetrics) -> CGSize {
        let widthPadding = max(layout.iconDimension * 0.42, 32)
        let heightPadding = max(layout.iconDimension * 0.62, 48)
        return CGSize(
            width: layout.iconDimension + widthPadding,
            height: layout.iconDimension + heightPadding
        )
    }

    /// Computes corner radius for search selection tile.
    private func searchSelectionCornerRadius(for layout: LauncherLayoutMetrics) -> CGFloat {
        max(layout.iconDimension * 0.34, 18)
    }

    /// Indicates whether item/index pair is the active search selection.
    private func isSearchResultSelected(item: LauncherItem, globalIndex: Int) -> Bool {
        guard isSearchModeActive else { return false }
        guard case .app = item else { return false }
        return activeSearchSelectionIndex == globalIndex
    }

    /// Monochrome drag preview to keep the in-grid placeholder untouched.
    private func dragPreview(for item: LauncherItem, layout: LauncherLayoutMetrics) -> some View {
        iconView(for: item, layout: layout)
            .frame(width: layout.iconDimension, height: layout.iconDimension)
            .modifier(wiggleMotion(for: item.id, layout: layout, isActive: true))
            .grayscale(1.0)
            .saturation(0)
            .opacity(0.72)
            .shadow(color: .black.opacity(0.18), radius: 10, y: 6)
    }

    /// Shows stacked preview when dragging multiple selected items.
    private func multiSelectionDragPreview(layout: LauncherLayoutMetrics) -> some View {
        let stackItems = Array(selectedLauncherItems.prefix(4))
        let offsetStep: CGFloat = layout.iconDimension * 0.06
        let verticalStep: CGFloat = layout.iconDimension * 0.03
        let scaleStep: CGFloat = 0.02
        let seedID = stackItems.first?.id ?? draggedItem?.id ?? UUID()

        return ZStack {
            ForEach(Array(stackItems.enumerated()), id: \.element.id) { index, item in
                iconView(for: item, layout: layout)
                    .frame(width: layout.iconDimension, height: layout.iconDimension)
                    .scaleEffect(1 - CGFloat(index) * scaleStep)
                    .offset(
                        x: CGFloat(index) * offsetStep,
                        y: -CGFloat(index) * verticalStep
                    )
            }
        }
        .frame(width: layout.iconDimension + offsetStep * 3, height: layout.iconDimension + verticalStep * 3)
        .modifier(wiggleMotion(for: seedID, layout: layout, isActive: true))
        .grayscale(1.0)
        .saturation(0)
        .opacity(0.8)
        .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
    }

    /// Composes a 3x3 grid of the first nine app icons to mimic the macOS folder style.
    private func folderIcon(
        for folder: FolderItem,
        layout: LauncherLayoutMetrics,
        allowHeavyWork: Bool
    ) -> some View {
        let previews = Array(folder.apps.prefix(9))
        let spacing = max(layout.iconDimension * 0.035, 2)
        let padding = spacing * 1.05
        let tileSize = max(((layout.iconDimension * 0.9) - padding * 2 - spacing * 2) / 3, 9)
        let folderCornerRadius: CGFloat = min(layout.iconDimension * 0.24, 28)
        let isSnapPreviewTarget = folder.id == folderSnapPreviewTargetID
        let disableAnimations = isPageSwitchAnimationActive || abs(pagerDragOffset) > 0.1
        let folderIconAnimation = disableAnimations ? nil : folderOpenAnimation

        return ZStack {
            RoundedRectangle(cornerRadius: folderCornerRadius, style: .continuous)
                .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.35))
            LinearGradient(
                colors: [Color.white.opacity(0.09), Color.black.opacity(0.04)],
                startPoint: .top,
                endPoint: .bottom
            )
            .clipShape(RoundedRectangle(cornerRadius: folderCornerRadius, style: .continuous))
            .allowsHitTesting(false)
            RoundedRectangle(cornerRadius: folderCornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)

            VStack(alignment: .center, spacing: spacing) {
                ForEach(0..<3, id: \.self) { rowIndex in
                    HStack(alignment: .top, spacing: spacing) {
                        ForEach(0..<3, id: \.self) { columnIndex in
                            let previewIndex = rowIndex * 3 + columnIndex

                            if previews.indices.contains(previewIndex) {
                                folderTile(for: previews[previewIndex], tileSize: tileSize, layout: layout, allowHeavyWork: allowHeavyWork)
                                    .frame(width: tileSize, height: tileSize)
                            } else {
                                Color.clear
                                    .frame(width: tileSize, height: tileSize)
                            }
                        }
                    }
                }
            }
            .padding(padding)
            .animation(folderIconAnimation, value: folderIconWaveToggle)

            if isSnapPreviewTarget {
                RoundedRectangle(cornerRadius: folderCornerRadius, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.85), lineWidth: 2)
                    .shadow(color: Color.accentColor.opacity(0.35), radius: 12, y: 0)
                    .blendMode(.screen)
                    .scaleEffect(1.02)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .frame(width: layout.iconDimension, height: layout.iconDimension)
        .scaleEffect(isSnapPreviewTarget ? 1.01 : 1.0)
        .animation(disableAnimations ? nil : .easeInOut(duration: 0.25), value: isSnapPreviewTarget)
        .animation(folderIconAnimation, value: folderIconWaveToggle)
        .environment(\.colorScheme, colorScheme)
        .animation(nil, value: searchControlsExpanded)
        .animation(nil, value: currentPage)
        .compositingGroup()
        .transaction { transaction in
            if disableAnimations {
                transaction.animation = nil
            }
        }
        .onAppear {
            guard allowHeavyWork else { return }
            warmFolderPreviewIcons(for: folder, layout: layout)
        }
        .onChange(of: folder.apps.map(\.id)) { _ in
            guard allowHeavyWork else { return }
            warmFolderPreviewIcons(for: folder, layout: layout)
        }
    }

    /// Renders folder cell including preview icons and title.
    @ViewBuilder
    private func folderTile(
        for app: AppItem,
        tileSize: CGFloat,
        layout: LauncherLayoutMetrics,
        allowHeavyWork: Bool
    ) -> some View {
        let tileCornerRadius = max(tileSize * 0.22, 2)
        let resolvedIcon = folderPreviewIcon(for: app, layout: layout)
        Group {
            if let icon = resolvedIcon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: tileCornerRadius, style: .continuous))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: tileCornerRadius, style: .continuous)
                        .fill(Color.white.opacity(0.15))
                    Image(systemName: "app.fill")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(4)
                        .foregroundColor(.primary.opacity(0.75))
                }
            }
        }
        .compositingGroup()
        .animation(nil, value: resolvedIcon?.hash ?? 0)
    }

    /// Chooses currently displayable icon for app tile (base or high-quality override).
    private func displayIcon(for app: AppItem, layout: LauncherLayoutMetrics) -> NSImage? {
        // Prefer any cached high-quality icon to avoid visible swaps when entering wiggle/drag.
        if let detailed = highQualityIconOverrides[app.id] {
            return detailed
        }
        let request = baseIconRequest(for: layout)
        return resolvedIcon(for: app, dimension: request.dimension, quality: request.quality) ?? app.iconImage
    }

    /// Schedules deferred high-quality icon request for visible app tiles.
    private func requestHighQualityIconIfNeeded(for app: AppItem, layout: LauncherLayoutMetrics) {
        guard highQualityIconOverrides[app.id] == nil else { return }
        guard delayedHighQualityRequests.contains(app.id) == false else { return }
        guard isLauncherVisible else { return }
        guard isUnderInteractionPressure == false else { return }
        guard isHighQualityCoolingDown == false else { return }

        if shouldUseHighQualityIcons == false {
            delayedHighQualityRequests.insert(app.id)
            DispatchQueue.main.asyncAfter(deadline: .now() + highQualityRequestDelay) { [self] in
                delayedHighQualityRequests.remove(app.id)
                requestHighQualityIconIfNeeded(for: app, layout: layout)
            }
            return
        }

        let targetDimension = highQualityRequestDimension(for: layout)
        let provider: @Sendable (AppItem, CGFloat, IconRenderQuality, CGFloat) -> NSImage? = iconProvider
        let cachedAppIcon = app.iconImage
        if pendingHighQualityIconIDs.insert(app.id).inserted == false {
            return
        }
        let requestEpoch = highQualityRequestEpoch
        let pressureEpoch = interactionPressureEpoch
        let scale = currentBackingScale()
        highQualityRenderQueue.async {
            let detailed = provider(app, targetDimension, .high, scale)
                ?? cachedAppIcon
            guard let detailed else {
                DispatchQueue.main.async {
                    pendingHighQualityIconIDs.remove(app.id)
                }
                return
            }
            DispatchQueue.main.async {
                guard pressureEpoch == interactionPressureEpoch else {
                    pendingHighQualityIconIDs.remove(app.id)
                    return
                }
                guard requestEpoch == highQualityRequestEpoch else {
                    pendingHighQualityIconIDs.remove(app.id)
                    return
                }
                guard isHighQualityCoolingDown == false else {
                    pendingHighQualityIconIDs.remove(app.id)
                    return
                }
                recordHighQualityIcon(detailed, for: app.id)
                pendingHighQualityIconIDs.remove(app.id)
            }
        }
    }

    @MainActor
    /// Stores high-quality icon override and updates recency bookkeeping.
    private func recordHighQualityIcon(_ icon: NSImage, for id: UUID) {
        guard highQualityIconOverrides[id] == nil else { return }
        withAnimation(.easeInOut(duration: 0.16)) {
            highQualityIconOverrides[id] = icon
            highQualityIconOrder.append(id)
            trimHighQualityIconCacheIfNeeded()
        }
    }

    @MainActor
    /// Evicts least-recently-used high-quality overrides when cache exceeds limit.
    private func trimHighQualityIconCacheIfNeeded() {
        let overflow = highQualityIconOverrides.count - highQualityIconCacheLimit
        guard overflow > 0 else { return }
        let removable = highQualityIconOrder.prefix(overflow)
        for id in removable {
            highQualityIconOverrides.removeValue(forKey: id)
        }
        highQualityIconOrder.removeFirst(min(overflow, highQualityIconOrder.count))
    }

    /// Returns title view for either app or folder items.
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

    /// Renders folder title with in-place rename affordances.
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
                    if focused {
                        DispatchQueue.main.async {
                            (NSApp.keyWindow?.firstResponder as? NSText)?.selectAll(nil)
                        }
                        return
                    }

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

    /// Computes folder overlay geometry and paging constraints.
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

        /// Estimates folder grid content height for a candidate column count.
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

    /// Computes content height for folder grid based on rows/spacing and text chrome.
    private func folderGridHeight(for appCount: Int, columns: Int, spacing: CGFloat, layout: LauncherLayoutMetrics, maxRows: Int) -> CGFloat {
        guard columns > 0 else { return 0 }
        let rowsNeeded = Int(ceil(Double(max(appCount, 1)) / Double(columns)))
        let rows = max(1, min(maxRows, rowsNeeded))
        let cellHeight = layout.iconDimension + folderCellChromeHeight()
        let spacingTotal = spacing * CGFloat(max(rows - 1, 0))
        return CGFloat(rows) * cellHeight + spacingTotal
    }

    /// Splits folder apps into per-page chunks for overlay pager.
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

    /// Returns fixed vertical chrome for folder cells (title + spacing).
    private func folderCellChromeHeight() -> CGFloat {
        let labelHeight = folderLabelLineHeight()
        let padding: CGFloat = 12 // .padding(.vertical, 6)
        let spacing: CGFloat = 10 // VStack spacing between icon and label
        return labelHeight * 2 + padding + spacing
    }

    /// Returns line height for folder cell labels.
    private func folderLabelLineHeight() -> CGFloat {
        let font = NSFont.systemFont(ofSize: 14, weight: .medium)
        return font.ascender - font.descender + font.leading
    }

    /// Returns title row height used in folder overlay.
    private func folderTitleHeight() -> CGFloat {
        let font = NSFont.systemFont(ofSize: 22, weight: .semibold)
        let lineHeight = font.ascender - font.descender + font.leading
        return lineHeight + 10 // accounts for the extra .padding(.top, 8)
    }

    /// Insets for folder overlay card content.
    private func folderContentInsets() -> EdgeInsets {
        switch launcherMode {
        case .floaty:
            return EdgeInsets(top: 20, leading: 26, bottom: 20, trailing: 26)
        case .fullscreen:
            return EdgeInsets(top: 26, leading: 32, bottom: 26, trailing: 32)
        }
    }

    /// Insets applied around folder grid pages.
    private func folderGridInsets() -> EdgeInsets {
        EdgeInsets(top: 6, leading: 10, bottom: 8, trailing: 10)
    }

    /// Minimum folder cell width derived from icon size and label allowance.
    private func folderMinCellWidth(for layout: LauncherLayoutMetrics) -> CGFloat {
        max(layout.iconDimension + 28, 110)
    }

    /// Synchronizes active folder page count and clamps selected page if needed.
    private func updateActiveFolderPageCount(_ count: Int) {
        let bounded = max(count, 1)
        if activeFolderPageCount != bounded {
            activeFolderPageCount = bounded
        }
        let clampedPage = min(activeFolderPage, max(bounded - 1, 0))
        if activeFolderPage != clampedPage {
            activeFolderPage = clampedPage
            folderPagerDragOffset = 0
        }
    }

    @ViewBuilder
    /// Renders folder pager controls for multi-page folders.
    private func folderPager(currentPage: Int, totalPages: Int) -> some View {
        HStack(spacing: 12) {
            Button {
                withAnimation(folderOpenAnimation) {
                    activeFolderPage = max(currentPage - 1, 0)
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(pagerControlForegroundColor.opacity(currentPage == 0 ? 0.35 : 0.8))
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
                    .foregroundColor(pagerControlForegroundColor.opacity(currentPage >= totalPages - 1 ? 0.35 : 0.8))
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
    /// Shared dot indicator row for root/folder pagers.
    private func pagerDots(
        currentPage: Int,
        totalPages: Int,
        orientation: PagingOrientation = .horizontal,
        onSelect: ((Int) -> Void)? = nil
    ) -> some View {
        let pageCount = max(totalPages, 1)
        let isFloaty = launcherMode == .floaty
        let stackSpacing: CGFloat = isFloaty ? 8 : 6
        let stack = Group {
            ForEach(0..<pageCount, id: \.self) { index in
                let isDisabled = onSelect == nil || index >= totalPages
                let isActive = index == currentPage
                let capsuleWidth: CGFloat = {
                    if isFloaty {
                        return isActive ? 16 : 8
                    } else {
                        return 8
                    }
                }()
                let capsuleHeight: CGFloat = isFloaty ? 6 : 8
                let fillOpacity: Double = isActive ? 0.9 : (isFloaty ? 0.28 : 0.35)
                let strokeOpacity: Double = isFloaty && isActive ? 0.22 : 0
                let scale: CGFloat = isActive ? 1.08 : 0.95
                Button {
                    onSelect?(index)
                } label: {
                    Capsule(style: .continuous)
                        .fill(pagerControlForegroundColor.opacity(fillOpacity))
                        .frame(width: capsuleWidth, height: capsuleHeight)
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(Color.white.opacity(strokeOpacity), lineWidth: isFloaty ? 0.8 : 0)
                        )
                        .scaleEffect(scale)
                        .animation(.spring(response: 0.34, dampingFraction: 0.82, blendDuration: 0.1), value: currentPage)
                        .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(isDisabled)
            }
        }

        if orientation == .vertical {
            VStack(spacing: stackSpacing) { stack }
                .frame(alignment: .leading)
        } else {
            HStack(spacing: stackSpacing) { stack }
        }
    }

    @ViewBuilder
    /// Renders root-grid pager controls and gesture affordances.
    private func gridPager(canReorder: Bool, layout: LauncherLayoutMetrics) -> some View {
        let totalPages = pageCount
        let dotsTotal = max(totalPages, 1)
        let previousDisabled = currentPage == 0 || orderedItems.isEmpty
        let nextDisabled = orderedItems.isEmpty || currentPage >= totalPages - 1
        let dotOrientation: PagingOrientation = isVerticalPaging && launcherMode == .fullscreen ? .vertical : .horizontal
        let pagerAlignmentLeading = isVerticalPaging && launcherMode == .fullscreen
        let previousSymbol = isVerticalPaging ? "chevron.up" : "chevron.left"
        let nextSymbol = isVerticalPaging ? "chevron.down" : "chevron.right"
        let pagerSpacing: CGFloat = isVerticalPaging ? 10 : 12
        let controlWidth: CGFloat = pagerButtonHitSize

        Group {
            if pagerAlignmentLeading {
                VStack(alignment: .leading, spacing: pagerSpacing) {
                    pagerChevronButton(
                        systemName: previousSymbol,
                        disabled: previousDisabled,
                        canReorder: canReorder,
                        targetPage: currentPage - 1,
                        action: pageBackward
                    )

                    pagerDots(
                        currentPage: min(currentPage, dotsTotal - 1),
                        totalPages: dotsTotal,
                        orientation: dotOrientation
                    ) { index in
                        jumpToPage(index)
                    }
                    .frame(width: controlWidth, alignment: .center)

                    pagerChevronButton(
                        systemName: nextSymbol,
                        disabled: nextDisabled,
                        canReorder: canReorder,
                        targetPage: currentPage + 1,
                        action: pageForward
                    )
                }
                .frame(width: controlWidth, height: layout.gridHeight, alignment: .center)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(pageIndicatorTitle)
            } else {
                let isRTL = layoutDirection == .rightToLeft
                let leftSymbol    = isRTL ? nextSymbol     : previousSymbol
                let rightSymbol   = isRTL ? previousSymbol : nextSymbol
                let leftAction    = isRTL ? pageForward    : pageBackward
                let rightAction   = isRTL ? pageBackward   : pageForward
                let leftDisabled  = isRTL ? nextDisabled   : previousDisabled
                let rightDisabled = isRTL ? previousDisabled : nextDisabled
                let leftTarget    = isRTL ? currentPage + 1 : currentPage - 1
                let rightTarget   = isRTL ? currentPage - 1 : currentPage + 1
                HStack(spacing: pagerSpacing) {
                    pagerChevronButton(
                        systemName: leftSymbol,
                        disabled: leftDisabled,
                        canReorder: canReorder,
                        targetPage: leftTarget,
                        action: leftAction
                    )

                    pagerDots(
                        currentPage: min(currentPage, dotsTotal - 1),
                        totalPages: dotsTotal,
                        orientation: dotOrientation
                    ) { index in
                        jumpToPage(index)
                    }

                    pagerChevronButton(
                        systemName: rightSymbol,
                        disabled: rightDisabled,
                        canReorder: canReorder,
                        targetPage: rightTarget,
                        action: rightAction
                    )
                }
                .frame(maxWidth: .infinity)
                .padding(.top, layout.gridToPagerSpacing)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(pageIndicatorTitle)
            }
        }
    }

    @ViewBuilder
    /// Builds one pager chevron button with repeat-on-hold behavior.
    private func pagerChevronButton(
        systemName: String,
        disabled: Bool,
        canReorder: Bool,
        targetPage: Int,
        action: @escaping () -> Void
    ) -> some View {
        let button = PagerChevronButtonView(
            systemName: systemName,
            disabled: disabled,
            foregroundColor: pagerControlForegroundColor.opacity(disabled ? 0.35 : 0.8),
            hitPadding: pagerButtonHitPadding,
            hitSize: pagerButtonHitSize,
            hitExpansion: pagerButtonHitExpansion,
            isFloaty: launcherMode == .floaty,
            action: action
        )

        if canReorder {
            button.onDrop(
                of: [.text],
                delegate: PageReorderDropDelegate(
                    targetPage: targetPage,
                    pageCapacity: pageCapacity,
                    items: $orderedItems,
                    draggedItem: $draggedItem,
                    performReorder: { item, _ in
                        pendingDropPage = targetPage
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

    /// Pager chevron that fires on press-down to reduce perceived latency.
    private struct PagerChevronButtonView: View {
        let systemName: String
        let disabled: Bool
        let foregroundColor: Color
        let hitPadding: CGFloat
        let hitSize: CGFloat
        let hitExpansion: CGFloat
        let isFloaty: Bool
        let action: () -> Void

        @State private var didTriggerOnPress = false

        var body: some View {
            Button(action: triggerIfNeededFromRelease) {
                Image(systemName: systemName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(foregroundColor)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.white.opacity(isFloaty ? 0.10 : 0))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(Color.white.opacity(isFloaty ? 0.22 : 0), lineWidth: isFloaty ? 0.8 : 0)
                            )
                    )
                    .animation(.spring(response: 0.32, dampingFraction: 0.84, blendDuration: 0.1), value: isFloaty)
            }
            .padding(.horizontal, hitPadding)
            .padding(.vertical, hitPadding)
            .frame(minWidth: hitSize, minHeight: hitSize)
            .contentShape(Rectangle().inset(by: -hitExpansion))
            .buttonStyle(.plain)
            .disabled(disabled)
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0, maximumDistance: 36)
                    .onChanged { _ in
                        guard disabled == false else { return }
                        triggerFromPress()
                    }
                    .onEnded { _ in
                        didTriggerOnPress = false
                    }
            )
        }

        /// Starts hold tracking and triggers first action immediately.
        private func triggerFromPress() {
            guard didTriggerOnPress == false else { return }
            didTriggerOnPress = true
            action()
        }

        /// Finalizes press action on release when hold timer did not already fire.
        private func triggerIfNeededFromRelease() {
            guard disabled == false else { return }
            guard didTriggerOnPress == false else {
                // Press already dispatched the action for this click.
                didTriggerOnPress = false
                return
            }
            action()
        }
    }

    /// Renders current folder page grid with drag/drop support.
    @ViewBuilder
    private func folderGrid(
        for folder: FolderItem,
        layout: LauncherLayoutMetrics,
        overlayLayout: FolderOverlayLayout,
        pageStartIndex: Int,
        pageApps: [AppItem]
    ) -> some View {
        let columnCount = max(1, overlayLayout.columns)
        let columns = Array(repeating: GridItem(.flexible(), spacing: overlayLayout.spacing, alignment: .top), count: columnCount)
        let tileSize = layout.iconDimension
        let gridInsets = overlayLayout.gridInsets

        GeometryReader { gridProxy in
            LazyVGrid(columns: columns, alignment: .center, spacing: overlayLayout.spacing) {
                ForEach(Array(pageApps.enumerated()), id: \.element.id) { _, app in
                    let isLaunching = launchingItemID == app.id
                    let isRenaming = renamingAppID == app.id
                    let cell = folderGridCellContent(
                        app: app,
                        layout: layout,
                        tileSize: tileSize,
                        isLaunching: isLaunching,
                        isRenaming: isRenaming
                    )

                    let decoratedCell = cell
                        .contextMenu {
                            itemContextMenu(for: .app(app))
                        }

                    let liftEffect = folderArrangementEffect(for: app, in: folder)
                    let animatedCell = decoratedCell
                        .scaleEffect(liftEffect.scale)
                        .offset(y: liftEffect.offset)
                        .shadow(
                            color: Color.black.opacity(liftEffect.shadowOpacity),
                            radius: liftEffect.shadowRadius,
                            y: liftEffect.shadowYOffset
                        )
                        .animation(reorderLiftAnimation, value: liftEffect)

                    if isRenaming == false {
                        animatedCell
                            .onDrag {
                                enterPerformanceShedding(duration: 0.6)
                                folderDragContext = FolderDragContext(folderID: folder.id, app: app)
                                draggedFolderApp = app
                                folderPreviewMatchingDisabled = true
                                return NSItemProvider(object: NSString(string: app.bundleIdentifier))
                            } preview: {
                                dragPreview(for: .app(app), layout: layout)
                            }
                    } else {
                        animatedCell
                    }
                }
            }
            .transaction { transaction in
                if transaction.animation == nil {
                    transaction.animation = folderReorderAnimation
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
                    maxRows: overlayLayout.maxRows,
                    spacing: overlayLayout.spacing,
                    gridSize: gridProxy.size,
                    contentInsets: gridInsets,
                    pageStartIndex: pageStartIndex,
                    pageItemCount: pageApps.count,
                    draggedApp: $draggedFolderApp,
                    resolveDraggedApp: { currentDraggedApp() },
                    isAppInFolder: { app in
                        folder.apps.contains(app)
                    },
                    performReorder: { app, target in
                        reorderApp(app, inFolderWithID: folder.id, to: target, animated: true, animation: folderReorderAnimation)
                    },
                    performLiveReorder: { app, target in
                        reorderApp(
                            app,
                            inFolderWithID: folder.id,
                            to: target,
                            animated: true,
                            animation: folderReorderAnimation
                        )
                    },
                    insertApp: { app, target in
                        insertApp(app, intoFolderWithID: folder.id, at: target)
                    },
                    onDropEnded: {
                        folderDragContext = nil
                        draggedFolderApp = nil
                        draggedItem = nil
                        folderPreviewMatchingDisabled = true
                        folderLiveReorderTargetIndex = nil
                    },
                    lastLiveReorderTargetIndex: $folderLiveReorderTargetIndex
                )
            )
            .animation(folderReorderAnimation, value: folder.apps)
            .animation(folderReorderAnimation, value: folderLiveReorderTargetIndex)
        }
        .frame(maxWidth: .infinity)
        .frame(height: overlayLayout.gridHeight)
    }

    @ViewBuilder
    /// Builds one app cell inside folder overlay grid.
    private func folderGridCellContent(
        app: AppItem,
        layout: LauncherLayoutMetrics,
        tileSize: CGFloat,
        isLaunching: Bool,
        isRenaming: Bool
    ) -> some View {
        // Performance guardrail: keep this as a concrete view (avoid AnyView) to preserve diffing.
        if isRenaming {
            editableAppCell(app: app, layout: layout, fontSize: 14)
        } else {
            let iconBase = iconView(for: .app(app), layout: layout)
                .frame(width: tileSize, height: tileSize)
                .scaleEffect(isLaunching ? 1.08 : 1.0)
                .opacity(isLaunching ? 0.4 : 1.0)
                .animation(.easeInOut(duration: 0.18), value: launchingItemID)
                .opacity(folderIconWaveToggle ? 1 : 0)
                .animation(folderOpenAnimation, value: folderIconWaveToggle)
                .modifier(wiggleMotion(for: app.id, layout: layout, isActive: shouldAllowWiggle(id: app.id)))
                .environment(\.colorScheme, colorScheme)

            Button {
                openItem(.app(app))
            } label: {
                VStack(spacing: 10) {
                    iconBase

                    Text(app.resolvedDisplayName)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(iconLabelColor())
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .opacity(folderIconWaveToggle ? 1 : 0)
                        .animation(folderOpenAnimation, value: folderIconWaveToggle)
                }
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .opacity(folderIconWaveToggle ? 1 : 0)
                .animation(folderOpenAnimation, value: folderIconWaveToggle)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    /// Pager wrapper for folder grid pages.
    private func folderGridPager(
        for folder: FolderItem,
        layout: LauncherLayoutMetrics,
        overlayLayout: FolderOverlayLayout,
        pages: [[AppItem]],
        currentPage: Int,
        pageCapacity: Int
    ) -> some View {
        GeometryReader { pagerProxy in
            let pageWidth = max(pagerProxy.size.width, 1)
            let totalPages = max(pages.count, 1)
            let stackedWidth = CGFloat(totalPages) * pageWidth

            HStack(spacing: 0) {
                ForEach(Array(pages.enumerated()), id: \.offset) { pageIndex, apps in
                    folderGrid(
                        for: folder,
                        layout: layout,
                        overlayLayout: overlayLayout,
                        pageStartIndex: pageIndex * pageCapacity,
                        pageApps: apps
                    )
                    .frame(width: pageWidth)
                    .opacity(folderPageOpacity(for: pageIndex, pageWidth: pageWidth))
                }
            }
            .frame(width: stackedWidth, height: overlayLayout.gridHeight, alignment: .leading)
            .offset(x: folderGridTranslation(
                pageWidth: pageWidth,
                totalPages: totalPages,
                basePageOffset: -CGFloat(currentPage) * pageWidth
            ))
            .onAppear {
                let transaction = Transaction(animation: nil)
                withTransaction(transaction) {
                    folderPagerViewportWidth = pageWidth
                }
            }
            .onChange(of: pageWidth) { newWidth in
                let transaction = Transaction(animation: nil)
                withTransaction(transaction) {
                    folderPagerViewportWidth = max(newWidth, 1)
                }
            }
        }
        .frame(height: overlayLayout.gridHeight)
    }

    /// Renders the full folder overlay card and interaction layers.
    @ViewBuilder
    private func folderOverlay(for folder: FolderItem, layout: LauncherLayoutMetrics) -> some View {
        GeometryReader { proxy in
            let overlayLayout = folderOverlayLayout(for: folder, containerSize: proxy.size, layout: layout)
            let overlayOpacity: Double = folderIconWaveToggle ? 1 : 0
            let dimOpacity: Double = folderIconWaveToggle ? 0.2 : 0

            ZStack {
                LauncherBackgroundLayer(
                    style: backgroundStylePreference,
                    solidBackgroundColor: solidBackgroundColor,
                    launcherMode: launcherMode,
                    colorScheme: colorScheme
                )
                .ignoresSafeArea()
                Color.black
                    .opacity(dimOpacity)
                    .ignoresSafeArea()
                    .animation(folderOpenAnimation, value: folderIconWaveToggle)

                ScrollWheelPagerOverlay(
                    isEnabled: isFolderGesturePagingEnabled,
                    onScrollProgress: { event in
                        handleFolderScrollProgress(
                            deltaX: event.deltaX,
                            phase: event.phase,
                            momentumPhase: event.momentumPhase,
                            isPrecise: event.isPrecise
                        )
                    },
                    onScrollEnd: {
                        folderSettlePagerOffset(pageWidth: folderPagerViewportWidth)
                    },
                    onPreviousPage: {
                        changeFolderPage(.backward)
                    },
                    onNextPage: {
                        changeFolderPage(.forward)
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)

                let pages = folderPages(for: folder, overlayLayout: overlayLayout)
                let pageCount = max(pages.count, 1)
                let pageCapacity = max(overlayLayout.pageCapacity, 1)
                let currentPage = min(activeFolderPage, max(pageCount - 1, 0))
                let showPager = pageCount > 1

                let cardShape = RoundedRectangle(cornerRadius: 22, style: .continuous)

                let cardChrome = cardShape
                    .fill(Color.clear)
                    .shadow(color: .black.opacity(0.3), radius: 24, y: 14)

                VStack(spacing: overlayLayout.titleToGridSpacing) {
                    folderTitleView(for: folder)

                    if pages.isEmpty {
                        Color.clear.frame(height: overlayLayout.gridHeight)
                    } else {
                        folderGridPager(
                            for: folder,
                            layout: layout,
                            overlayLayout: overlayLayout,
                            pages: pages,
                            currentPage: currentPage,
                            pageCapacity: pageCapacity
                        )
                    }

                    if showPager {
                        folderPager(currentPage: currentPage, totalPages: pageCount)
                    }
                }
                .padding(.top, overlayLayout.contentInsets.top)
                .padding(.bottom, overlayLayout.contentInsets.bottom)
                .padding(.leading, overlayLayout.contentInsets.leading)
                .padding(.trailing, overlayLayout.contentInsets.trailing)
                .frame(maxWidth: overlayLayout.cardWidth)
                .scaleEffect(0.96 + 0.04 * folderOverlayOpenProgress)
                .offset(y: (1 - folderOverlayOpenProgress) * 10)
                .background(
                    VisualEffectBackground(
                        material: .hudWindow,
                        blendingMode: .withinWindow,
                        appearance: NSAppearance(named: .vibrantDark)
                    )
                    .clipShape(cardShape)
                )
                .overlay(
                    cardShape
                        .strokeBorder(Color.white.opacity(0.25))
                )
                .clipShape(cardShape)
                .background(cardChrome)
                .opacity(overlayOpacity)
                .animation(folderOpenAnimation, value: folderIconWaveToggle)
                .anchorPreference(key: FolderFramePreference.self, value: .bounds) { anchor in
                    proxy[anchor]
                }
            }
            .onPreferenceChange(FolderFramePreference.self) { frame in
                guard draggedItem != nil || draggedFolderApp != nil else { return }
                guard activeFolderFrame != frame else { return }
                let transaction = Transaction(animation: nil)
                withTransaction(transaction) {
                    activeFolderFrame = frame
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                closeActiveFolder()
            }
            .onDrop(
                of: [.text],
                delegate: FolderExitDropDelegate(
                    activeFrame: $activeFolderFrame,
                    containerSize: proxy.size,
                    edgeThreshold: 18,
                    onExitDrag: {
                        withAnimation(.easeInOut(duration: 0.12)) {
                            dragItemOutOfFolderIfNeeded()
                        }
                    }
                )
            )
            .transition(.opacity)
            .onAppear {
                warmFolderPreviewIcons(for: folder, layout: layout)
                updateActiveFolderPageCount(pageCount)
                if folderIconWaveToggle == false {
                    withAnimation(folderOpenAnimation) {
                        folderIconWaveToggle = true
                    }
                }
                if folderOverlayOpenProgress < 1 {
                    withAnimation(.easeOut(duration: 0.18)) {
                        folderOverlayOpenProgress = 1
                    }
                }
                if pendingFolderRenameID == folder.id {
                    pendingFolderRenameID = nil
                    DispatchQueue.main.async {
                        beginFolderNameEdit(for: folder)
                    }
                }
            }
            .onChange(of: pageCount) { newCount in
                updateActiveFolderPageCount(newCount)
            }
            .onDisappear {
                activeFolderPageCount = 0
                folderPagerDragOffset = 0
                folderPagerViewportWidth = 1
                folderLastPagerDragDate = nil
            }
        }
        .environment(\.colorScheme, colorScheme)
    }

    /// Simple empty state shown when the grid has nothing to display.
    private func emptyState() -> some View {
        let primaryForeground = emptyStatePrimaryForegroundColor
        let secondaryForeground = emptyStateSecondaryForegroundColor

        return VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 32, weight: .light))
                .foregroundColor(primaryForeground)
            Text(orderedItems.isEmpty ? String(localized: "GridNoItemsFoundLabel") : String(localized: "GridNoMatchingItemsLabel"))
                .font(.title3)
                .foregroundColor(primaryForeground)
            if orderedItems.isEmpty == false && searchText.isEmpty == false {
                Text(String(localized: "GridSearchEmptyHint"))
                    .foregroundColor(secondaryForeground)
            } else if orderedItems.isEmpty {
                Text(String(localized: "GridNotIndexedLabel"))
                    .foregroundColor(secondaryForeground)
            }
        }
    }

    /// Asks `NSWorkspace` to launch the tapped application and queues the close animation.
    private func openItem(_ item: LauncherItem) {
        guard isClosingLauncher == false else { return }

        switch item {
        case .folder(let folder):
            enterPerformanceShedding(duration: 1.1)
            lastActiveFolderID = folder.id
            cancelFolderPreviewMatchRelease()
            folderPreviewMatchID = nil
            primeFolderOverlayOpenAnimation()
            folderIconWaveToggle = false
            withAnimation(folderOpenAnimation) {
                activeFolder = folder
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
        if let delegate = NSApp?.delegate as? LaunchyAppDelegate {
            delegate.fadeOutLauncherWindow(restoreFocus: true) { @MainActor in
                isClosingLauncher = false
                launchingItemID = nil
                purgeHighQualityOverrides()
            }
            return
        }

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
                purgeHighQualityOverrides()
                notifyCachesShouldShrink()
                NotificationCenter.default.post(name: .launcherDidHide, object: nil)
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

    /// Instructs the app delegate to aggressively shrink icon caches after hiding.
    private func notifyCachesShouldShrink() {
        guard let delegate = NSApp?.delegate as? LaunchyAppDelegate else { return }
        delegate.shrinkIconCachesForHiddenLauncher()
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

    /// Resolves current backing scale with safe fallback.
    private func currentBackingScale() -> CGFloat {
        PerformanceCapabilityLayer.shared.screenScale(for: hostingWindow()?.screen)
    }

    /// Aligns values to physical pixel boundaries to reduce blur.
    private func pixelAlign(_ value: CGFloat) -> CGFloat {
        let scale = currentBackingScale()
        guard scale > 0 else { return value }
        return (value * scale).rounded(.toNearestOrAwayFromZero) / scale
    }

    /// Applies adaptive runtime tuning limits based on active display capability.
    private func applyPerformanceTuningIfNeeded() {
        let screen = hostingWindow()?.screen
        let capability = PerformanceCapabilityLayer.shared.capabilities(for: screen)
        guard capability != lastPerformanceCapability else { return }
        let tuning = PerformanceCapabilityLayer.shared.tuning(for: screen)
        Self.folderPreviewCache.applyLimits(
            countLimit: tuning.folderPreviewCacheCountLimit,
            totalCostLimit: tuning.folderPreviewCacheCostLimit
        )
        lastPerformanceCapability = capability
    }

    /// Accumulates scroll delta for coalesced page navigation processing.
    private func queueScrollDelta(_ delta: CGFloat, pageSpan: CGFloat) {
        guard delta != 0 else { return }
        if scrollCoalescingNanoseconds == 0 {
            applyPagerScrollDelta(delta, pageSpan: pageSpan)
            return
        }
        pendingScrollDelta += delta
        guard scrollUpdateScheduled == false else { return }
        scrollUpdateScheduled = true
        let delay = scrollCoalescingNanoseconds
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + .nanoseconds(Int(delay))) { [self] in
                applyPendingScrollDelta(pageSpan: pageSpan)
            }
        } else {
            DispatchQueue.main.async { [self] in
                applyPendingScrollDelta(pageSpan: pageSpan)
            }
        }
    }

    /// Applies one live pager delta immediately, preserving a continuous gesture-to-animation handoff.
    private func applyPagerScrollDelta(_ delta: CGFloat, pageSpan: CGFloat) {
        guard delta != 0 else { return }
        pagerDragOffset = clampPagerOffset(pagerDragOffset + delta, pageSpan: pageSpan)
        lastPagerDragDate = Date()
    }

    /// Applies buffered scroll deltas to page offset and navigation state.
    private func applyPendingScrollDelta(pageSpan: CGFloat) {
        scrollUpdateScheduled = false
        let delta = pendingScrollDelta
        pendingScrollDelta = 0
        guard delta != 0 else { return }
        applyPagerScrollDelta(delta, pageSpan: pageSpan)
    }

    /// Forces immediate application of buffered scroll deltas.
    private func flushPendingScrollDelta(pageSpan: CGFloat) {
        guard pendingScrollDelta != 0 || scrollUpdateScheduled else { return }
        applyPendingScrollDelta(pageSpan: pageSpan)
    }

    /// Finalizes scroll gesture and settles to nearest page.
    private func endScrollGesture(pageSpan: CGFloat) {
        let signpostID = Self.beginSignpost("PagerInputEnd")
        flushPendingScrollDelta(pageSpan: pageSpan)
        isScrollGestureActive = false
        settlePagerOffset(pageSpan: pageSpan)
        Self.endSignpost("PagerInputEnd", id: signpostID)
    }


    /// Identifies windows that are rendering the launcher content.
    private func isLauncherHostingWindow(_ window: NSWindow) -> Bool {
        if window.contentViewController is NSHostingController<LauncherView> {
            return true
        }

        return window.contentView is NSHostingView<LauncherView>
    }

    /// Routes keyboard paging commands to either the folder overlay or root grid.
    private func handleKeyboardPager(_ direction: PageShiftDirection) {
        if activeFolder != nil {
            changeFolderPage(direction)
            return
        }

        if isSearchModeActive {
            navigateSearchResults(direction)
            return
        }

        switch direction {
        case .backward:
            pageBackward()
        case .forward:
            pageForward()
        }
    }

    /// Handles vertical keyboard navigation depending on current context.
    private func handleVerticalNavigation(_ direction: KeyPressPagerOverlay.VerticalArrowDirection) {
        if isVerticalPaging {
            if activeFolder != nil {
                changeFolderPage(direction == .up ? .backward : .forward)
                return
            }
            requestPageShift(direction == .down ? 1 : -1)
            return
        }
        handleVerticalArrowNavigation(direction)
    }

    /// Handles vertical paging when search mode is not active.
    private func handleVerticalArrowNavigation(_ direction: KeyPressPagerOverlay.VerticalArrowDirection) {
        guard isSearchModeActive else { return }
        navigateSearchResultsVertically(direction)
    }

    /// Moves search selection horizontally through result set.
    private func navigateSearchResults(_ direction: PageShiftDirection) {
        guard filteredItemList.isEmpty == false else { return }
        if activeSearchSelectionIndex == nil {
            let seed = direction == .forward ? 1 : 0
            createSearchSelectionIfNeeded(seedIndex: seed)
            return
        }
        guard let currentIndex = activeSearchSelectionIndex else { return }
        let delta = direction == .forward ? 1 : -1
        let nextIndex = min(max(currentIndex + delta, 0), filteredItemList.count - 1)
        guard nextIndex != currentIndex else { return }
        selectSearchResult(at: nextIndex)
    }

    /// Moves search selection vertically by grid row stride.
    private func navigateSearchResultsVertically(_ direction: KeyPressPagerOverlay.VerticalArrowDirection) {
        guard filteredItemList.isEmpty == false else { return }
        let columns = gridConfiguration.columnsPerPage

        if activeSearchSelectionIndex == nil {
            let seed = direction == .down ? columns : 0
            createSearchSelectionIfNeeded(seedIndex: seed)
            return
        }

        guard let currentIndex = activeSearchSelectionIndex else { return }
        let delta = direction == .down ? columns : -columns
        let nextIndex = min(max(currentIndex + delta, 0), filteredItemList.count - 1)
        guard nextIndex != currentIndex else { return }
        selectSearchResult(at: nextIndex)
    }

    /// Initializes search selection index when navigating from empty state.
    private func createSearchSelectionIfNeeded(seedIndex: Int) {
        guard isSearchModeActive else { return }
        guard filteredItemList.isEmpty == false else { return }
        guard activeSearchSelectionIndex == nil else { return }
        let bounded = min(max(seedIndex, 0), filteredItemList.count - 1)
        searchSelectionIndex = bounded
        selectSearchResult(at: bounded)
    }

    /// Selects and reveals a search result index.
    private func selectSearchResult(at index: Int, animated: Bool = true) {
        guard isSearchModeActive else { return }
        let bounded = min(max(index, 0), filteredItemList.count - 1)
        guard bounded >= 0 else { return }
        let previousPage = currentPage
        searchSelectionIndex = bounded
        guard let targetPage = pageIndex(forLinearIndex: bounded, sizes: displayPageSizes) else { return }
        guard targetPage != currentPage else { return }

        let dir: PageShiftDirection = targetPage >= previousPage ? .forward : .backward

        if animated {
            performAnimatedPageSwitch(to: targetPage, direction: dir)
        } else {
            pageDirection = dir
            currentPage = targetPage
            pagerDragOffset = 0
            beginPageSwitchPhase1()
            schedulePageSwitchPhase2()
        }
    }

    /// Routes numeric shortcuts (⌘1, ⌘2, etc.) to either the folder pager or the main grid pager.
    private func handlePageShortcutRequest(_ targetPage: Int) {
        if activeFolder != nil {
            jumpToActiveFolderPage(targetPage)
        } else {
            jumpToPage(targetPage)
        }
    }

    /// Jumps folder overlay to a specific page with clamping and animation.
    private func jumpToActiveFolderPage(_ targetPage: Int) {
        guard activeFolder != nil else { return }
        guard activeFolderPageCount > 0 else { return }
        let bounded = min(max(targetPage, 0), activeFolderPageCount - 1)
        guard bounded != activeFolderPage else { return }
        withAnimation(folderOpenAnimation) {
            activeFolderPage = bounded
            folderPagerDragOffset = 0
        }
    }

    /// Moves the active folder pager one step in the specified direction, if possible.
    private func changeFolderPage(_ direction: PageShiftDirection) {
        guard activeFolder != nil else { return }
        let totalPages = max(activeFolderPageCount, 1)
        guard totalPages > 1 else { return }

        switch direction {
        case .backward:
            let target = max(activeFolderPage - 1, 0)
            guard target != activeFolderPage else { return }
            withAnimation(folderOpenAnimation) {
                activeFolderPage = target
                folderPagerDragOffset = 0
            }
        case .forward:
            let target = min(activeFolderPage + 1, totalPages - 1)
            guard target != activeFolderPage else { return }
            withAnimation(folderOpenAnimation) {
                activeFolderPage = target
                folderPagerDragOffset = 0
            }
        }
    }

    /// Handles Escape across rename, multi-select, folder overlays, search, and finally hides the launcher.
    private func handleEscapeKeyPress() {
        if isRenamingItem {
            cancelActiveRename()
            return
        }

        if isMultiSelectModeActive {
            finalizeBulkSelectionAction()
            return
        }

        if activeFolder != nil {
            closeActiveFolder()
            return
        }

        if hasActiveSearchQuery {
            searchText = ""
            focusSearchFieldIfAppropriate()
            return
        }

        hideLauncher()
    }

    /// Animates closing the active folder overlay so the transition stays smooth.
    private func closeActiveFolder(animated: Bool = true) {
        guard activeFolder != nil else { return }
        let signpostID = Self.beginSignpost("FolderOverlayClose")
        if animated {
            folderCloseWorkItem?.cancel()
            enterPerformanceShedding(duration: Self.folderOpenDuration + 0.1, cancelHeavyWork: false)
            // Fade icons in sync with the overlay card (mirrors open animation)
            scheduleFolderIconWaveToggle(false, delay: 0, animated: true)
            withAnimation(.easeOut(duration: Self.folderOpenDuration)) {
                isFolderClosing = true
            }
            let workItem = DispatchWorkItem { [self] in
                isFolderClosing = false
                withAnimation(.easeInOut(duration: 0.35)) {
                    activeFolder = nil   // isFolderOverlayVisible → false → gridBlendOpacity 0.6→1.0
                }
                folderCloseWorkItem = nil
                closingFolder = nil
                Self.endSignpost("FolderOverlayClose", id: signpostID)
            }
            folderCloseWorkItem = workItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Self.folderOpenDuration,
                execute: workItem
            )
        } else {
            isFolderClosing = false
            folderCloseWorkItem?.cancel()
            folderCloseWorkItem = nil
            closingFolder = nil
            activeFolder = nil
            Self.endSignpost("FolderOverlayClose", id: signpostID)
        }
    }

    /// Schedules staged folder-icon wave animation toggles.
    private func scheduleFolderIconWaveToggle(_ value: Bool, delay: TimeInterval, animated: Bool) {
        folderIconWaveWorkItem?.cancel()
        let workItem = DispatchWorkItem { [self] in
            if animated {
                withAnimation(folderOpenAnimation) {
                    folderIconWaveToggle = value
                }
            } else {
                folderIconWaveToggle = value
            }
        }
        folderIconWaveWorkItem = workItem
        if delay <= 0 {
            workItem.perform()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }

    /// Seeds animation flags before presenting folder overlay.
    private func primeFolderOverlayOpenAnimation() {
        withTransaction(Transaction(animation: nil)) {
            folderOverlayOpenProgress = 0
        }
    }

    /// Defers clearing folder-preview match highlight to smooth transient state changes.
    private func scheduleFolderPreviewMatchRelease(for folderID: UUID?) {
        folderPreviewReleaseWorkItem?.cancel()
        folderPreviewReleaseWorkItem = nil
        guard let folderID else {
            folderPreviewMatchID = nil
            return
        }

        let workItem = DispatchWorkItem { [folderID] in
            guard activeFolder == nil, folderPreviewMatchID == folderID else { return }
            folderPreviewMatchID = nil
        }
        folderPreviewReleaseWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + folderPreviewMatchReleaseDelay,
            execute: workItem
        )
    }

    /// Cancels pending delayed folder-preview highlight release.
    private func cancelFolderPreviewMatchRelease() {
        folderPreviewReleaseWorkItem?.cancel()
        folderPreviewReleaseWorkItem = nil
    }

    /// Moves to the previous page if possible.
    private func pageBackward() {
        requestPageShift(-1)
    }

    /// Jumps directly to a target page and animates directionally.
    private func jumpToPage(_ targetPage: Int) {
        guard pageCount > 0 else { return }
        let bounded = min(max(targetPage, 0), pageCount - 1)
        guard bounded != currentPage else { return }
        queuedPageShifts.removeAll()
        let dir: PageShiftDirection = bounded >= currentPage ? .forward : .backward
        performAnimatedPageSwitch(to: bounded, direction: dir)
    }

    /// Queues one-step page shifts so rapid input chains smoothly without multi-page skips.
    private func requestPageShift(_ delta: Int) {
        guard pageCount > 0 else { return }
        guard delta != 0 else { return }

        if isPageSwitchAnimationActive {
            enqueueQueuedPageShifts(for: delta)
            return
        }

        queuedPageShifts.removeAll()
        let step = delta > 0 ? 1 : -1
        let target = clampPageIndex(currentPage + step)
        let direction: PageShiftDirection = target >= currentPage ? .forward : .backward
        if target != currentPage {
            performAnimatedPageSwitch(to: target, direction: direction)
        }
    }

    /// Buffers additional single-page steps while a transition is already underway.
    private func enqueueQueuedPageShifts(for delta: Int) {
        let step = delta > 0 ? 1 : -1

        for _ in 0..<abs(delta) {
            guard queuedPageShifts.count < Self.maxQueuedPageShiftCount else { break }
            let projectedPage = queuedPageShifts.reduce(currentPage) { partial, queuedStep in
                clampPageIndex(partial + queuedStep)
            }
            let nextProjectedPage = clampPageIndex(projectedPage + step)
            guard nextProjectedPage != projectedPage else { break }
            queuedPageShifts.append(step)
        }
    }

    /// Starts the next queued page step once the current transition has settled.
    private func drainQueuedPageShiftIfNeeded() {
        guard isPageSwitchAnimationActive == false else { return }
        guard pageCount > 0 else {
            queuedPageShifts.removeAll()
            return
        }

        while queuedPageShifts.isEmpty == false {
            let step = queuedPageShifts.removeFirst()
            let target = clampPageIndex(currentPage + step)
            guard target != currentPage else { continue }
            let direction: PageShiftDirection = target >= currentPage ? .forward : .backward
            performAnimatedPageSwitch(to: target, direction: direction)
            return
        }
    }

    /// Starts or stops timed paging while a drag is held against a screen edge.
    private func updateDragEdgePaging(for delta: Int?) {
        guard delta != activeDragEdgePagingDelta else { return }
        stopDragEdgePaging()
        guard let delta else { return }
        guard isDragEdgePagingEnabled else { return }
        guard clampPageIndex(currentPage + delta) != currentPage else { return }
        activeDragEdgePagingDelta = delta
        scheduleDragEdgePagingTick(for: delta)
    }

    /// Cancels any in-flight timed edge-paging callbacks.
    private func stopDragEdgePaging() {
        dragEdgePagingToken &+= 1
        activeDragEdgePagingDelta = nil
    }

    /// Schedules the next one-page edge scroll after the configured hold interval.
    private func scheduleDragEdgePagingTick(for delta: Int) {
        dragEdgePagingToken &+= 1
        let token = dragEdgePagingToken
        DispatchQueue.main.asyncAfter(deadline: .now() + dragEdgePagingInterval) { [self] in
            handleDragEdgePagingTick(token: token, delta: delta)
        }
    }

    /// Advances one page while the drag remains pinned to the same edge zone.
    private func handleDragEdgePagingTick(token: UInt, delta: Int) {
        guard token == dragEdgePagingToken else { return }
        guard activeDragEdgePagingDelta == delta else { return }
        guard isDragEdgePagingEnabled else {
            stopDragEdgePaging()
            return
        }

        let target = clampPageIndex(currentPage + delta)
        guard target != currentPage else {
            stopDragEdgePaging()
            return
        }

        requestPageShift(delta)

        guard activeDragEdgePagingDelta == delta else { return }
        scheduleDragEdgePagingTick(for: delta)
    }

    /// Moves to the next page if possible.
    private func pageForward() {
        requestPageShift(1)
    }

    /// Applies a page-level move when the drag is dropped directly on an edge zone.
    private func performDragEdgeDrop(pageDelta _: Int) -> Bool {
        stopDragEdgePaging()
        guard let draggedItem else { return false }

        let targetPage = clampPageIndex(currentPage)
        pendingDropPage = targetPage
        let insertionIndex = pageDropInsertionIndex(for: targetPage)
        let finalIndex = reorderItem(
            draggedItem,
            to: insertionIndex,
            targetPageHint: targetPage
        )
        updatePageAfterDrop(at: finalIndex)
        self.draggedItem = nil
        return true
    }

    /// Hides the launcher when the blurred background is clicked.
    private func dismissLauncherViaBackgroundTap() {
        guard launcherMode == .fullscreen || launcherMode == .floaty else { return }
        guard isClosingLauncher == false else { return }
        guard didTapInteractiveView() == false else { return }
        isClosingLauncher = true
        animateAndDismissLauncher()
    }

    /// Programmatically hides the launcher without needing a background tap.
    private func hideLauncher() {
        guard launcherMode == .fullscreen || launcherMode == .floaty else { return }
        guard isClosingLauncher == false else { return }
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

    private struct LauncherBackgroundLayer: View, Equatable {
        let style: LauncherSettings.PreferredBackgroundStyle
        let solidBackgroundColor: LauncherSettings.SolidBackgroundColor
        let launcherMode: LauncherMode
        let colorScheme: ColorScheme

        @ViewBuilder
        var body: some View {
            switch style {
            case .standard:
                if launcherMode == .floaty {
                    if colorScheme == .dark {
                        floatyStandardBlurBackground()
                    } else {
                        lightBlurBackground()
                    }
                } else {
                    darkBlurBackground()
                }
            case .light:
                lightBlurBackground()
            case .solid:
                Color(nsColor: solidBackgroundColor.nsColor)
            case .transparent:
                Color.clear
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

        /// Builds dark blur material for fullscreen and dark states.
        private func darkBlurBackground() -> VisualEffectBackground {
            blurBackground(material: .hudWindow, preferredAppearance: .vibrantDark)
        }

        /// Builds light blur material for light-mode variants.
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
    }

    /// Soft glassy halo that lifts the floaty panel off the desktop.
    private func floatyBackdropHighlight(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius + 10, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color.white.opacity(colorScheme == .dark ? 0.12 : 0.08),
                        Color.white.opacity(colorScheme == .dark ? 0.04 : 0.03)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .blur(radius: 22)
            .offset(y: -8)
            .padding(-6)
    }

    /// Hairline strokes that mimic the layered glass edges in modern macOS HUDs.
    private func floatyGlassStroke(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [
                        Color.white.opacity(colorScheme == .dark ? 0.42 : 0.28),
                        Color.white.opacity(colorScheme == .dark ? 0.16 : 0.10)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1.1
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.black.opacity(colorScheme == .dark ? 0.30 : 0.20), lineWidth: 0.6)
                    .blendMode(.overlay)
            )
    }

    /// Spacer used to reserve header/search area in fullscreen mode.
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
        ensureSearchFieldCaretHidden()
    }

    /// Makes sure the system text editor uses a transparent caret while the search field is first responder.
    private func ensureSearchFieldCaretHidden() {
        Task { @MainActor in
            guard isSearchFieldFocused,
                  let window = NSApp.keyWindow,
                  let editor = window.firstResponder as? NSTextView else { return }
            editor.insertionPointColor = NSColor.clear
        }
    }

    /// Renders search bar and mode-specific trailing controls.
    @ViewBuilder
    private func searchBar(layout: LauncherLayoutMetrics) -> some View {
        if launcherMode == .floaty {
            floatySearchBar(layout: layout)
        } else {
            fullscreenSearchBar(layout: layout)
        }
    }

    /// Glassy search bar used when the launcher is fullscreen.
    private func fullscreenSearchBar(layout: LauncherLayoutMetrics) -> some View {
        searchFieldBody(layout: layout, isFloaty: false)
    }

    /// Search bar modeled after the floaty panel screenshot (rounded, pill-like, with a settings control).
    private func floatySearchBar(layout: LauncherLayoutMetrics) -> some View {
        searchFieldBody(layout: layout, isFloaty: true)
    }

    /// Builds text field row for search with mode-aware sizing.
    private func searchFieldBody(layout: LauncherLayoutMetrics, isFloaty: Bool) -> some View {
        TextField(String(localized: "GridSearchLabel"), text: $searchText)
            .textFieldStyle(.plain)
            .font(.system(size: layout.searchBarFontSize, weight: .medium))
            .foregroundColor(searchBarForegroundColor())
            .accentColor(searchBarCursorColor)
            .focused($isSearchFieldFocused)
            .onSubmit {
                launchSearchResultIfPossible()
            }
            .padding(.leading, 38)
            .padding(.trailing, 14)
            .frame(width: layout.searchBarWidth, height: layout.searchBarHeight)
            .background(searchFieldBackground(isFloaty: isFloaty, layout: layout))
            .overlay(
                RoundedRectangle(cornerRadius: layout.searchBarCornerRadius, style: .continuous)
                    .strokeBorder(
                        isMultiSelectModeActive ? Color.accentColor.opacity(0.7) :
                            isFloaty
                                ? (usesDarkSearchBarAppearance ? Color.white.opacity(0.4) : Color.black.opacity(0.18))
                                : Color.white.opacity(0.25),
                        lineWidth: isMultiSelectModeActive ? 2 : 1
                    )
            )
            .overlay(alignment: .trailing) {
                searchBarTrailingDecorations()
            }
            .overlay(alignment: .leading) {
                searchBarLeadingMagnifier()
            }
            .shadow(color: .black.opacity(isFloaty ? 0.22 : 0.2), radius: isFloaty ? 20 : 12, y: isFloaty ? 10 : 4)
            .shadow(color: Color.white.opacity(isFloaty ? (colorScheme == .dark ? 0.16 : 0.26) : 0), radius: isFloaty ? 2.4 : 0, y: isFloaty ? 1 : 0)
            .frame(width: layout.searchBarWidth)
            .frame(maxWidth: .infinity)
            .environment(\.colorScheme, searchBarColorSchemeOverride())
    }

    /// Returns layered search-field background visuals.
    private func searchFieldBackground(isFloaty: Bool, layout: LauncherLayoutMetrics) -> some View {
        let shape = RoundedRectangle(cornerRadius: layout.searchBarCornerRadius, style: .continuous)
        return Group {
            if isFloaty {
                ZStack {
                    searchBarBackgroundMaterial()
                    LinearGradient(
                        colors: [
                            Color.white.opacity(colorScheme == .dark ? 0.18 : 0.14),
                            Color(red: 0.76, green: 0.86, blue: 0.99).opacity(colorScheme == .dark ? 0.18 : 0.14),
                            Color(red: 0.54, green: 0.66, blue: 0.88).opacity(colorScheme == .dark ? 0.16 : 0.10)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Color.white.opacity(colorScheme == .dark ? 0.08 : 0.10)
                        .blendMode(.screen)
                }
                .overlay(
                    shape.strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.36 : 0.28), lineWidth: 0.9)
                )
                .overlay(
                    shape.strokeBorder(Color.black.opacity(colorScheme == .dark ? 0.28 : 0.12), lineWidth: 0.6)
                        .blendMode(.overlay)
                )
            } else {
                searchBarBackgroundMaterial()
            }
        }
        .clipShape(shape)
    }

    private var isSearchControlsVisible: Bool {
        searchControlsExpanded && searchText.isEmpty
    }

    private var searchControlsAnimation: Animation {
        .spring(response: 0.45, dampingFraction: 0.72, blendDuration: 0.25)
    }

    private var searchBarIconTransition: Animation {
        .easeInOut(duration: 0.32)
    }

    @ViewBuilder
    /// Renders trailing decoration stack for search bar.
    private func searchBarTrailingDecorations() -> some View {
        ZStack(alignment: .trailing) {
            Button {
                if searchText.isEmpty {
                    toggleSearchControlsExpansion()
                } else {
                    searchText = ""
                }
            } label: {
                searchIconStack(isEmpty: searchText.isEmpty)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 14)
            .contentShape(Rectangle())
            .opacity(isSearchControlsVisible ? 0 : 1)
            .allowsHitTesting(!isSearchControlsVisible)
            .help(searchText.isEmpty ? String(localized: "GridMoreActionsButton") : String(localized: "GridSearchClearButton"))

            HStack(spacing: 12) {
                Button {
                    Task { @MainActor in
                        onAppInfoRequested?()
                    }
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(searchBarForegroundColor().opacity(0.85))
                }
                .buttonStyle(.plain)
                .help(String(localized: "StatusBarInfoButton"))

                multiSelectToggleControl()

                Button {
                    Task { @MainActor in
                        onSettingsRequested?()
                    }
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(searchBarForegroundColor().opacity(0.85))
                }
                .buttonStyle(.plain)
                .help(String(localized: "StatusBarLauncherSettingsButton"))
            }
            .padding(.trailing, 14)
            .opacity(isSearchControlsVisible ? 1 : 0)
            .allowsHitTesting(isSearchControlsVisible)
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
            .animation(searchControlsAnimation, value: searchControlsExpanded)
        }
    }

    @ViewBuilder
    /// Leading search icon and context glyphs for search field.
    private func searchIconStack(isEmpty: Bool) -> some View {
        ZStack {
            Image(systemName: "ellipsis.circle")
                .scaleEffect(isEmpty ? 1 : 0.03)
                .opacity(isEmpty ? 1 : 0)
            HStack(spacing: 6) {
                if showSearchLoadingIndicator && isEmpty == false {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .scaleEffect(0.78)
                        .tint(searchBarForegroundColor().opacity(0.7))
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
                Image(systemName: "xmark.circle.fill")
                    .opacity(isEmpty ? 0 : 1)
            }
            .scaleEffect(isEmpty ? 0.03 : 1)
            .opacity(isEmpty ? 0 : 1)
        }
        .font(.system(size: 16, weight: .semibold))
        .foregroundColor(searchBarForegroundColor().opacity(0.58))
        .frame(width: showSearchLoadingIndicator && isEmpty == false ? 32 : 18, height: 18, alignment: .trailing)
        .animation(searchBarIconTransition, value: isEmpty)
        .animation(searchBarIconTransition, value: showSearchLoadingIndicator)
    }

    @ViewBuilder
    /// Magnifier icon on the leading edge of the search bar; fades out while typing.
    private func searchBarLeadingMagnifier() -> some View {
        Image(systemName: "magnifyingglass")
            .font(.system(size: 16, weight: .semibold))
            .foregroundColor(searchBarForegroundColor().opacity(0.45))
            .padding(.leading, 12)
            .opacity(searchText.isEmpty ? 1 : 0)
            .scaleEffect(searchText.isEmpty ? 1 : 0.6, anchor: .leading)
            .animation(searchBarIconTransition, value: searchText.isEmpty)
    }

    /// Toggles multi-select mode from search/control area.
    private func multiSelectToggleControl() -> some View {
        Button {
            toggleMultiSelectMode()
        } label: {
            Image(systemName: "checklist")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(isMultiSelectModeActive ? Color.accentColor : searchBarForegroundColor().opacity(0.65))
                .frame(width: 32, height: 32)
                .background(
                    Circle()
                        .strokeBorder(
                            isMultiSelectModeActive ? Color.accentColor.opacity(0.9) : searchBarForegroundColor().opacity(0.4),
                            lineWidth: isMultiSelectModeActive ? 2.2 : 1
                        )
                )
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .help(isMultiSelectModeActive ? String(localized: "GridExitMultiSelectButton") : String(localized: "GridEnterMultiSelectButton"))
    }

    /// Toggles expansion state for compact search controls.
    private func toggleSearchControlsExpansion() {
        guard searchText.isEmpty else { return }
        let shouldExpand = !searchControlsExpanded
        if shouldExpand == false {
            exitMultiSelectMode()
        }
        updateSearchControlsExpansion(to: shouldExpand)
    }

    /// Applies expanded/collapsed state and related animation bookkeeping.
    private func updateSearchControlsExpansion(to expanded: Bool) {
        withAnimation(.none) {
            searchControlsExpanded = expanded
        }
        if expanded {
            scheduleExpansionAutoCollapse()
        } else {
            cancelExpansionAutoCollapse()
        }
    }

    /// Enters or exits multi-selection mode.
    private func toggleMultiSelectMode() {
        if isMultiSelectModeActive {
            exitMultiSelectMode()
            updateSearchControlsExpansion(to: false)
        } else {
            cancelExpansionAutoCollapse()
            multiSelectedItemIDs.removeAll()
            isMultiSelectModeActive = true
            updateSearchControlsExpansion(to: true)
        }
    }

    /// Schedules automatic collapse of expanded control tray.
    private func scheduleExpansionAutoCollapse() {
        guard isMultiSelectModeActive == false else { return }
        cancelExpansionAutoCollapse()
        expansionAutoCollapseTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard searchControlsExpanded && isMultiSelectModeActive == false else { return }
            updateSearchControlsExpansion(to: false)
            expansionAutoCollapseTask = nil
        }
    }

    /// Cancels pending auto-collapse timer/task.
    private func cancelExpansionAutoCollapse() {
        expansionAutoCollapseTask?.cancel()
        expansionAutoCollapseTask = nil
    }

    /// Clears multi-select state and exits selection mode.
    private func exitMultiSelectMode() {
        isMultiSelectModeActive = false
        multiSelectedItemIDs.removeAll()
        isPerformingMultiSelectionDrag = false
    }

    private var selectedLauncherItems: [LauncherItem] {
        orderedItems.filter { multiSelectedItemIDs.contains($0.id) }
    }

    private var isMultiSelectionDragActive: Bool {
        isMultiSelectModeActive && isPerformingMultiSelectionDrag && selectedLauncherItems.count > 1
    }

    /// Determines whether drag should include current multi-selection set.
    private func shouldStartMultiSelectionDrag(for item: LauncherItem) -> Bool {
        guard isMultiSelectModeActive else { return false }
        guard multiSelectedItemIDs.contains(item.id) else { return false }
        guard selectedLauncherItems.count > 1 else { return false }
        return true
    }

    /// Returns launcher-item targets participating in current multi-select action.
    private func multiSelectTargets(for item: LauncherItem) -> [LauncherItem] {
        let selection = selectedLauncherItems
        if isMultiSelectModeActive && selection.isEmpty == false {
            return selection
        }
        return [item]
    }

    /// Returns app-only targets participating in current multi-select action.
    private func multiSelectAppTargets(for item: LauncherItem) -> [AppItem] {
        multiSelectTargets(for: item).compactMap { target in
            if case let .app(app) = target {
                return app
            }
            return nil
        }
    }

    private var selectedAppEntries: [(index: Int, app: AppItem)] {
        orderedItems.enumerated().compactMap { index, item in
            guard
                isMultiSelectModeActive,
                multiSelectedItemIDs.contains(item.id),
                case let .app(app) = item
            else {
                return nil
            }
            return (index: index, app: app)
        }
    }

    /// Checks whether selected apps can be added to target folder.
    private func canAddSelection(to folder: FolderItem) -> Bool {
        guard isMultiSelectModeActive else { return false }
        let selection = selectedLauncherItems.filter { $0.id != folder.id }
        return selection.isEmpty == false
    }

    private var canCreateFolderFromSelection: Bool {
        selectedAppEntries.count >= 2
    }

    /// Toggles membership of an item in the multi-select set.
    private func toggleSelection(for item: LauncherItem) {
        guard isMultiSelectModeActive else { return }
        if multiSelectedItemIDs.contains(item.id) {
            multiSelectedItemIDs.remove(item.id)
        } else {
            multiSelectedItemIDs.insert(item.id)
        }
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

    /// Ensures the search bar caret/tracking is invisible even while focused.
    private var searchBarCursorColor: Color {
        Color.clear
    }

    /// Overrides the color scheme locally so placeholder and accent colors match the background.
    private func searchBarColorSchemeOverride() -> ColorScheme {
        usesDarkSearchBarAppearance ? .dark : colorScheme
    }

    /// Whether the search bar should use the darker tinted style.
    private var usesDarkSearchBarAppearance: Bool {
        if backgroundStylePreference == .transparent { return true }
        if backgroundStylePreference == .standard {
            // Floaty in light system appearance uses a light window background, so match it.
            if launcherMode == .floaty && colorScheme == .light { return false }
            return true
        }
        return false
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
            return solidBackgroundColor.nsColor.launchy_perceivedBrightness < 0.75
        case .transparent:
            return colorScheme == .dark
        }
    }

    /// Primary color used in the empty state view to stay readable on any backdrop.
    private var emptyStatePrimaryForegroundColor: Color {
        shouldUseLightEmptyStateText ? Color.white : Color.black.opacity(0.9)
    }

    /// Secondary color for supporting empty state details when the primary text is bright.
    private var emptyStateSecondaryForegroundColor: Color {
        shouldUseLightEmptyStateText ? Color.white.opacity(0.72) : Color.black.opacity(0.65)
    }

    /// Decides whether the empty state should stick to light text for better contrast.
    private var shouldUseLightEmptyStateText: Bool {
        switch backgroundStylePreference {
        case .standard, .transparent:
            return true
        case .light:
            return false
        case .solid:
            return solidBackgroundColor.nsColor.launchy_perceivedBrightness < 0.95
        }
    }

    /// Pager controls stay white unless the solid background is nearly pure white.
    private var pagerControlForegroundColor: Color {
        shouldUseLightPagerControls ? Color.white : Color.black.opacity(0.9)
    }

    /// Determines whether pager buttons/dots should invert to a darker tint.
    private var shouldUseLightPagerControls: Bool {
        switch backgroundStylePreference {
        case .solid:
            let brightness = solidBackgroundColor.nsColor.launchy_perceivedBrightness
            return brightness < 0.95
        default:
            return true
        }
    }

    /// Launches the first matched app when a user submits the search field.
    private func launchSearchResultIfPossible() {
        let trimmedQuery = normalizedSearchText
        guard trimmedQuery.isEmpty == false else { return }
        guard let selection = activeSearchSelectionItem ?? filteredItemList.first else { return }
        openItem(selection)
    }

    /// Context menu for app/folder items with move/rename/group actions.
    @ViewBuilder
    private func itemContextMenu(for item: LauncherItem) -> some View {
        Button(String(localized: "ItemActionOpen")) {
            openItem(item)
        }

        switch item {
        case .app(let app):
            Button(String(localized: "ItemActionRenameApp")) {
                beginAppRename(app)
            }

            Button(String(localized: "ItemActionShowInFinder")) {
                showInFinder(app)
            }
            .disabled(app.bundleURL == nil)

            Menu(String(localized: "ItemActionMoveToFolder")) {
                folderMoveMenu(for: multiSelectAppTargets(for: item))
            }

            Menu(String(localized: "ItemActionMoveToPage")) {
                pageMoveMenu(for: item)
            }

            Button(String(localized: "ItemActionHideApp")) {
                hideApps(multiSelectAppTargets(for: item))
                finalizeBulkSelectionAction()
            }

            if isMultiSelectModeActive,
               multiSelectedItemIDs.contains(app.id),
               canCreateFolderFromSelection
            {
                Button(String(localized: "ItemActionCreateFolderWithSelection")) {
                    createFolderFromSelection(promptForName: true)
                }
            }

            if isMultiSelectModeActive == false || multiSelectedItemIDs.contains(app.id) == false {
                Button(String(localized: "ItemActionCreateFolderWithApp")) {
                    createFolder(from: app, promptForName: true)
                }
            }
        case .folder(let folder):
            Button(String(localized: "ItemActionFolderDetails")) {
                showItemDetails(item)
            }

            Button(String(localized: "ItemActionRenameFolder")) {
                beginFolderRename(folder)
            }

            if isMultiSelectModeActive {
                Button(String(localized: "ItemActionAddSelectionToFolder")) {
                    mergeMultiSelection(into: .folder(folder))
                }
                .disabled(canAddSelection(to: folder) == false)
            }

            Menu(String(localized: "ItemActionMoveToPage")) {
                pageMoveMenu(for: item)
            }
        }
    }

    /// Context submenu listing destination folders for selected apps.
    @ViewBuilder
    private func folderMoveMenu(for apps: [AppItem]) -> some View {
        let folders = orderedItems.compactMap { item -> FolderItem? in
            if case let .folder(folder) = item { return folder }
            return nil
        }

        let folderOptions = folders.map { folder -> (folder: FolderItem, title: String) in
            let title = folder.name.isEmpty ? FolderItem.defaultName : folder.name
            return (folder: folder, title: title)
        }
        let sortedFolders = folderOptions.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }

        if apps.isEmpty {
            Button(String(localized: "ItemNoAppsSelected")) { }
                .disabled(true)
        } else if sortedFolders.isEmpty {
            Button(String(localized: "ItemMoveToFolderNoneAvailable")) { }
                .disabled(true)
        } else {
            ForEach(sortedFolders, id: \.folder.id) { entry in
                Button(entry.title) {
                    moveApps(apps, toFolderID: entry.folder.id)
                    finalizeBulkSelectionAction()
                }
                .disabled(apps.allSatisfy { isApp($0, inFolderWithID: entry.folder.id) })
            }
        }
    }

    /// Builds insertion options for creating a new page via move actions.
    private func newPageInsertionOptions(totalPages: Int) -> [PageInsertionOption] {
        let pageCount = max(totalPages, 1)
        var options: [PageInsertionOption] = [
            PageInsertionOption(
                insertionIndex: 0,
                title: String(localized: "ItemActionInsertAtBeginning")
            )
        ]
        if pageCount > 1 {
            for gap in 1..<pageCount {
                let start = gap
                let end = gap + 1
                options.append(
                    PageInsertionOption(
                        insertionIndex: gap,
                        title: String.localizedStringWithFormat(
                            String(localized: "ItemActionInsertBetweenPagesFormat"),
                            start,
                            end
                        )
                    )
                )
            }
        }
        options.append(
            PageInsertionOption(
                insertionIndex: pageCount,
                title: String(localized: "ItemActionInsertAtEnd")
            )
        )
        return options
    }

    /// Context submenu for moving an item to existing or new pages.
    @ViewBuilder
    private func pageMoveMenu(for item: LauncherItem) -> some View {
        let totalPages = max(fullPageCount, 1)
        let pageIndices = Array(0..<totalPages)
        let usesFolderOverlay = activeFolder != nil
        let targets: [LauncherItem] = {
            if usesFolderOverlay {
                return [item]
            }
            return multiSelectTargets(for: item)
        }()
        let insertionOptions = newPageInsertionOptions(totalPages: totalPages)

        ForEach(pageIndices, id: \.self) { targetPage in
            let pageIsFull = pageHasSpace(targetPage) == false
            let onPage = targets.allSatisfy {
                pageIndex(for: $0) == targetPage
            }
            let shouldDisable = usesFolderOverlay ? pageIsFull : onPage
            Button(
                String.localizedStringWithFormat(
                    String(localized: "ItemPageLabel"),
                    targetPage + 1
                )
            ) {
                if usesFolderOverlay, let first = targets.first {
                    moveAppOutOfFolderToPage(first, targetPage: targetPage)
                } else {
                    moveItems(targets, toPage: targetPage)
                    finalizeBulkSelectionAction()
                }
            }
            .disabled(shouldDisable)
        }

        Divider()

        Menu(String(localized: "ItemActionCreateNewPage")) {
            ForEach(insertionOptions) { option in
                Button(option.title) {
                    if usesFolderOverlay, let first = targets.first {
                        moveItemsToNewPage([first], atInsertionIndex: option.insertionIndex)
                    } else {
                        moveItemsToNewPage(targets, atInsertionIndex: option.insertionIndex)
                        finalizeBulkSelectionAction()
                    }
                }
            }
        }
    }

    /// Context menu shown when right-clicking launcher background.
    @ViewBuilder
    private func backgroundContextMenu() -> some View {
        if isMultiSelectModeActive && canCreateFolderFromSelection {
            Button(String(localized: "ItemActionCreateFolderWithSelection")) {
                createFolderFromSelection(promptForName: true)
            }
        }

        Button(String(localized: "ItemActionCreateFolder")) {
            createEmptyFolder(onPage: currentPage, promptForName: true)
        }

        Button(String(localized: "SettingsFloatyToggleLabel")) {
            onToggleLauncherModeRequested?()
        }

        Button(String(localized: "MenuItemSettings")) {
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
        alert.addButton(withTitle: String(localized: "CommonOKButton"))
        presentModalAlert(alert)
    }

    /// Displays folder information and contained apps.
    private func showFolderDetails(_ folder: FolderItem) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = folder.name.isEmpty ? FolderItem.defaultName : folder.name
        let appList = folder.apps.map { "- \($0.resolvedDisplayName)" }.joined(separator: "\n")
        alert.informativeText = appList.isEmpty ? String(localized: "ItemDetailFolderEmptyLabel") : String(format: String(localized: "ItemDetailAppsFormat"), appList)
        alert.addButton(withTitle: String(localized: "CommonOKButton"))
        presentModalAlert(alert)
    }

    /// Prefills the app rename field with either the custom name or the bundle's display name.
    private func appRenameDraft(for app: AppItem) -> String {
        sanitizedCustomName(app.customName ?? app.resolvedDisplayName) ?? app.resolvedDisplayName
    }

    /// Begins inline app renaming on the targeted item.
    private func beginAppRename(_ app: AppItem) {
        renamingAppID = app.id
        appNameDraft = appRenameDraft(for: app)
        isEditingFolderName = false
        DispatchQueue.main.async {
            isAppNameFieldFocused = true
        }
    }

    /// Starts inline folder renaming by opening and focusing the overlay title.
    private func beginFolderRename(_ folder: FolderItem) {
        if activeFolder?.id == folder.id {
            beginFolderNameEdit(for: folder)
            return
        }
        pendingFolderRenameID = folder.id
        primeFolderOverlayOpenAnimation()
        folderPreviewMatchID = nil
        folderIconWaveToggle = false
        withAnimation(folderOpenAnimation) {
            activeFolder = folder
        }
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

    /// Cancels any in-progress rename without persisting the edits.
    private func cancelActiveRename() {
        if isEditingFolderName {
            cancelFolderNameEdit()
        }

        if let renamingID = renamingAppID {
            cancelAppRename(appID: renamingID)
        }
    }

    /// Resets the folder title editor back to the current folder name.
    private func cancelFolderNameEdit() {
        isEditingFolderName = false
        isFolderNameFieldFocused = false
        if let folder = activeFolder {
            folderNameDraft = folder.name.isEmpty ? FolderItem.defaultName : folder.name
        } else {
            folderNameDraft = ""
        }
    }

    /// Restores the app rename draft to the existing name and exits edit mode.
    private func cancelAppRename(appID: UUID) {
        renamingAppID = nil
        isAppNameFieldFocused = false
        if let app = appWithID(appID) {
            appNameDraft = appRenameDraft(for: app)
        } else {
            appNameDraft = ""
        }
    }

    /// Resets temporary rename UI state for both apps and folders.
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
        let directoryURL = url.deletingLastPathComponent()
        // Open the containing folder directly to avoid triggering file-access prompts when revealing bundles.
        NSWorkspace.shared.open(directoryURL)
    }

    /// Adds or updates hidden app entries and removes them from the current grid.
    private func hideApps(_ apps: [AppItem]) {
        guard apps.isEmpty == false else { return }

        var identifiers = Set(LauncherSettingsPersistence.hiddenBundleIdentifiers())
        for app in apps {
            identifiers.insert(app.bundleIdentifier)
        }
        LauncherSettingsPersistence.setHiddenBundleIdentifiers(Array(identifiers).sorted())

        var didRemoveAny = false
        withAnimation(gridSpringAnimation) {
            for app in apps {
                if let removal = removeAppFromHierarchy(app) {
                    orderedItems = removal.items
                    didRemoveAny = true
                }
            }
        }

        guard didRemoveAny else { return }
        persistOrderChange(using: pageSizes)
        currentPage = min(currentPage, fullPageCount - 1)
        pagerDragOffset = 0
    }

    private func hideApp(_ app: AppItem) {
        hideApps([app])
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
            updateFilteredItems(using: updated)
        }
        if activeFolder?.id == folder.id {
            shouldSkipActiveFolderChangeEffects = true
            activeFolder = folder
        }
        ensureCurrentPageWithinBounds()
        persistOrderChange(using: pageSizes)
    }

    /// Moves apps into target folder and persists resulting arrangement.
    private func moveApps(_ apps: [AppItem], toFolderID folderID: UUID) {
        for app in apps {
            moveApp(app, toFolderID: folderID)
        }
    }

    /// Moves an item (or app extracted from a folder) to a target page.
    private func moveItem(_ item: LauncherItem, toPage targetPage: Int) {
        var items = orderedItems
        let currentSizes = activePageSizes(for: items.count)
        let itemToInsert: LauncherItem
        var workingSizes = currentSizes

        switch item {
        case .app(let app):
            guard let removal = removeAppFromHierarchy(
                app,
                updatePageSizes: false,
                normalizePageSizes: false
            ) else { return }
            items = removal.items
            itemToInsert = .app(removal.app)
            workingSizes = removal.removedRootItem ? removal.pageSizesAfterRemoval : currentSizes
        case .folder(let folder):
            guard let index = items.firstIndex(where: { entry in
                if case let .folder(existing) = entry {
                    return existing.id == folder.id
                }
                return false
            }) else { return }
            workingSizes = pageSizesAfterRemoval(currentSizes, removingIndex: index, currentCount: items.count, normalize: false)
            itemToInsert = items.remove(at: index)
        }

        let resolvedPage = resolveTargetPageForInsertion(hint: max(0, targetPage), sizes: workingSizes)
        while resolvedPage >= workingSizes.count {
            workingSizes.append(0)
        }
        let insertionIndex = insertionIndexForPage(resolvedPage, sizes: workingSizes)
        items.insert(itemToInsert, at: insertionIndex)
        workingSizes[resolvedPage] += 1
        let finalSizes = trimTrailingEmptyPages(workingSizes)
        withAnimation(gridSpringAnimation) {
            orderedItems = items
        }
        pageSizes = finalSizes
        ensureCurrentPageWithinBounds()
        persistOrderChange(using: finalSizes)
    }

    /// Moves items to an existing page while preserving relative order.
    private func moveItems(_ items: [LauncherItem], toPage targetPage: Int) {
        for item in items {
            moveItem(item, toPage: targetPage)
        }
    }

    /// Creates a new page and inserts selected targets at the requested insertion point.
    private func moveItemsToNewPage(_ targets: [LauncherItem], atInsertionIndex insertionIndex: Int) {
        guard targets.isEmpty == false else { return }

        var workingItems = orderedItems
        var workingSizes = activePageSizes(for: workingItems.count)
        var removedItems: [LauncherItem] = []

        for target in targets {
            switch target {
            case .app(let app):
                guard let location = locateApp(app, in: workingItems) else { continue }
                switch location {
                case .root(let index):
                    let previousCount = workingItems.count
                    guard case let .app(existing) = workingItems.remove(at: index) else { continue }
                    workingSizes = pageSizesAfterRemoval(
                        workingSizes,
                        removingIndex: index,
                        currentCount: previousCount,
                        normalize: false
                    )
                    removedItems.append(.app(existing))
                case .folder(let folderIndex, let appIndex):
                    guard case var .folder(folder) = workingItems[folderIndex] else { continue }
                    guard folder.apps.indices.contains(appIndex) else { continue }
                    let removedApp = folder.apps.remove(at: appIndex)
                    if folder.apps.isEmpty {
                        let previousCount = workingItems.count
                        workingItems.remove(at: folderIndex)
                        workingSizes = pageSizesAfterRemoval(
                            workingSizes,
                            removingIndex: folderIndex,
                            currentCount: previousCount,
                            normalize: false
                        )
                        if activeFolder?.id == folder.id {
                            closeActiveFolder()
                        }
                    } else {
                        workingItems[folderIndex] = .folder(folder)
                        if activeFolder?.id == folder.id {
                            shouldSkipActiveFolderChangeEffects = true
                            activeFolder = folder
                        }
                    }
                    removedItems.append(.app(removedApp))
                }
            case .folder(let folder):
                guard let index = workingItems.firstIndex(where: { item in
                    if case let .folder(existing) = item {
                        return existing.id == folder.id
                    }
                    return false
                }) else { continue }
                let previousCount = workingItems.count
                let removed = workingItems.remove(at: index)
                workingSizes = pageSizesAfterRemoval(
                    workingSizes,
                    removingIndex: index,
                    currentCount: previousCount,
                    normalize: false
                )
                removedItems.append(removed)
                if activeFolder?.id == folder.id {
                    closeActiveFolder()
                }
            }
        }

        guard removedItems.isEmpty == false else { return }

        let boundedInsertion = max(0, min(insertionIndex, workingSizes.count))
        let chunkSize = pageCapacity > 0 ? pageCapacity : removedItems.count
        let chunks: [[LauncherItem]] = stride(from: 0, to: removedItems.count, by: chunkSize).map { start in
            Array(removedItems[start..<min(start + chunkSize, removedItems.count)])
        }

        var updatedSizes = workingSizes
        var workingInsertionIndex = boundedInsertion
        var workingInsertionPosition = pageStartIndex(for: workingInsertionIndex, sizes: updatedSizes)

        for chunk in chunks {
            workingItems.insert(contentsOf: chunk, at: workingInsertionPosition)
            updatedSizes.insert(chunk.count, at: workingInsertionIndex)
            workingInsertionIndex += 1
            workingInsertionPosition = pageStartIndex(for: workingInsertionIndex, sizes: updatedSizes)
        }

        let finalSizes = fillsGapsAutomatically
            ? densePageSizes(for: workingItems.count)
            : trimTrailingEmptyPages(updatedSizes)

        withAnimation(gridSpringAnimation) {
            orderedItems = workingItems
            updateFilteredItems(using: workingItems)
        }
        pageSizes = finalSizes
        ensureCurrentPageWithinBounds()
        persistOrderChange(using: finalSizes)
    }

    /// Extracts an app from its folder and inserts it onto a target page.
    private func moveAppOutOfFolderToPage(_ item: LauncherItem, targetPage: Int) {
        guard case .app(let app) = item else { return }
        guard let removal = removeAppFromHierarchy(
            app,
            updatePageSizes: false,
            normalizePageSizes: false
        ) else { return }

        var items = removal.items
        var afterRemovalSizes = removal.pageSizesAfterRemoval
        let resolvedPage = resolveTargetPageForInsertion(hint: max(0, targetPage), sizes: afterRemovalSizes)
        while resolvedPage >= afterRemovalSizes.count {
            afterRemovalSizes.append(0)
        }
        let insertionIndex = insertionIndexForPage(resolvedPage, sizes: afterRemovalSizes)
        items.insert(.app(removal.app), at: insertionIndex)
        afterRemovalSizes[resolvedPage] += 1
        let finalSizes = trimTrailingEmptyPages(afterRemovalSizes)

        withAnimation(gridSpringAnimation) {
            orderedItems = items
            updateFilteredItems(using: items)
        }
        pageSizes = finalSizes
        ensureCurrentPageWithinBounds()
        persistOrderChange(using: finalSizes)
    }

    /// Runs shared cleanup after completing a bulk selection action.
    private func finalizeBulkSelectionAction() {
        guard isMultiSelectModeActive else { return }
        exitMultiSelectMode()
        updateSearchControlsExpansion(to: false)
    }

    /// Creates a folder from current selection and optionally enters rename flow.
    private func createFolderFromSelection(promptForName: Bool) {
        let selection = selectedAppEntries
        guard selection.count >= 2 else { return }

        var updatedItems = orderedItems
        let indices = selection.map { $0.index }.sorted()
        for index in indices.reversed() {
            updatedItems.remove(at: index)
        }

        let folder = FolderItem(apps: selection.map { $0.app })
        let insertIndex = min(indices.first ?? 0, updatedItems.count)
        updatedItems.insert(.folder(folder), at: insertIndex)

        orderedItems = updatedItems
        persistOrderChange()

        if promptForName {
            beginFolderRename(folder)
        }

        finalizeBulkSelectionAction()
    }

    /// Inserts item into a page and returns updated normalized page sizes.
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

    /// Looks up an app by UUID across both root items and folders.
    private func appWithID(_ id: UUID) -> AppItem? {
        for item in orderedItems {
            switch item {
            case .app(let app) where app.id == id:
                return app
            case .folder(let folder):
                if let match = folder.apps.first(where: { $0.id == id }) {
                    return match
                }
            default:
                continue
            }
        }
        return nil
    }

    /// Finds folder model by ID from mixed launcher items.
    private func folderItem(withID id: UUID, in items: [LauncherItem]) -> FolderItem? {
        for item in items {
            if case let .folder(folder) = item, folder.id == id {
                return folder
            }
        }
        return nil
    }

    /// Returns the location of an app in the overall arrangement.
    private func locateApp(_ app: AppItem) -> AppLocation? {
        locateApp(app, in: orderedItems)
    }

    /// Locates app either at root or within a folder, returning positional metadata.
    private func locateApp(_ app: AppItem, in items: [LauncherItem]) -> AppLocation? {
        for (index, item) in items.enumerated() {
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
    private func removeAppFromHierarchy(
        _ app: AppItem,
        updatePageSizes: Bool = true,
        normalizePageSizes: Bool = true
    ) -> RemovedAppContext? {
        guard let location = locateApp(app) else { return nil }
        let currentSizes = activePageSizes(for: orderedItems.count)
        var items = orderedItems

        switch location {
        case .root(let index):
            guard case let .app(existing) = items.remove(at: index) else { return nil }
            let removalSizes = pageSizesAfterRemoval(
                currentSizes,
                removingIndex: index,
                currentCount: orderedItems.count,
                normalize: normalizePageSizes
            )
            if updatePageSizes {
                pageSizes = removalSizes
            }
            return RemovedAppContext(
                items: items,
                app: existing,
                suggestedIndex: index,
                removedRootItem: true,
                pageSizesAfterRemoval: removalSizes
            )
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
                    shouldSkipActiveFolderChangeEffects = true
                    activeFolder = folder
                }
                return RemovedAppContext(
                    items: items,
                    app: removedApp,
                    suggestedIndex: insertionIndex,
                    removedRootItem: false,
                    pageSizesAfterRemoval: currentSizes
                )
            } else if activeFolder?.id == folder.id {
                closeActiveFolder()
            }

            let removalSizes = pageSizesAfterRemoval(
                currentSizes,
                removingIndex: folderIndex,
                currentCount: orderedItems.count,
                normalize: normalizePageSizes
            )
            if updatePageSizes {
                pageSizes = removalSizes
            }
            return RemovedAppContext(
                items: items,
                app: removedApp,
                suggestedIndex: insertionIndex,
                removedRootItem: true,
                pageSizesAfterRemoval: removalSizes
            )
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
    /// Presents alert modally above launcher windows and returns response.
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
            .app(AppItem(
                id: UUID(),
                displayName: "Safari",
                bundleIdentifier: "com.apple.Safari",
                iconImage: NSImage(named: NSImage.networkName),
                bundleURL: nil,
                isUserApplication: false
            )),
            .app(AppItem(
                id: UUID(),
                displayName: "Xcode",
                bundleIdentifier: "com.apple.dt.Xcode",
                iconImage: nil,
                bundleURL: nil,
                isUserApplication: false
            )),
            .folder(FolderItem(name: FolderItem.defaultName, apps: [
                AppItem(
                    id: UUID(),
                    displayName: "Notes",
                    bundleIdentifier: "com.apple.Notes",
                    iconImage: nil,
                    bundleURL: nil,
                    isUserApplication: false
                ),
                AppItem(
                    id: UUID(),
                    displayName: "Mail",
                    bundleIdentifier: "com.apple.mail",
                    iconImage: nil,
                    bundleURL: nil,
                    isUserApplication: false
                )
            ]))
        ],
        backgroundStylePreference: .standard
    )
}

private struct FolderFramePreference: PreferenceKey {
    static let defaultValue: CGRect = .zero

    /// Preference reduction keeps latest folder frame emitted by subtree.
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
