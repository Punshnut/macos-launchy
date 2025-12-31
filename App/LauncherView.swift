import SwiftUI
import AppKit

extension Notification.Name {
    /// Informs the launcher view that the search bar should regain focus after a mode switch.
    static let launcherShouldRefocusSearch = Notification.Name("launchyLauncherShouldRefocusSearch")
    /// Triggers the fullscreen grid fly-in animation when the launcher appears.
    static let launcherShouldAnimateGridEntrance = Notification.Name("launchyLauncherShouldAnimateGridEntrance")
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

    func cacheKey(for app: AppItem, dimension: CGFloat, quality: IconRenderQuality) -> String {
        let rounded = Int(dimension.rounded())
        return "\(app.bundleIdentifier)|\(rounded)|\(quality.rawValue)"
    }

    func cachedIcon(for key: String) -> NSImage? {
        cache.object(forKey: key as NSString)
    }

    func store(_ icon: NSImage, for key: String) {
        let cost = Int(icon.size.width * icon.size.height)
        cache.setObject(icon, forKey: key as NSString, cost: cost)
    }

    func beginWarmupIfNeeded(token: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if warmupTokens.contains(token) {
            return false
        }
        warmupTokens.insert(token)
        return true
    }

    func finishWarmup(token: String) {
        lock.lock()
        warmupTokens.remove(token)
        lock.unlock()
    }

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
    /// Whether items should collapse upward to fill earlier gaps.
    var fillsGapsAutomatically: Bool = true
    /// Callback fired when the user requests to open settings from a context menu.
    var onSettingsRequested: (() -> Void)?
    /// Callback fired when the user requests app info/about.
    var onAppInfoRequested: (() -> Void)?
    /// Callback fired whenever the user changes the arrangement.
    var onItemOrderChange: (([LauncherItem], [Int]) -> Void)?
    /// Callback fired when the visible pages change so icons can be preheated.
    var onVisiblePagesChanged: (([AppItem]) -> Void)?
    /// Provides the icon that should be used for a specific app.
    var iconProvider: @Sendable (AppItem, CGFloat, IconRenderQuality) -> NSImage? = { app, _, _ in app.iconImage }

    private var pageCapacity: Int { LauncherGridConfiguration.pageCapacity }
    private let closeAnimationDuration: TimeInterval = 0.25
    private let wiggleCycleDuration: TimeInterval = 0.58
    private let wiggleRotationDegrees: Double = 1.65
    private let wiggleHorizontalSwayFactor: CGFloat = 0.018
    private let wiggleVerticalBobFactor: CGFloat = 0.0085
    private let wiggleAnchor = UnitPoint(x: 0.5, y: 0.2)
    private var fullscreenGridEntranceScale: CGFloat {
        guard launcherMode == .fullscreen else { return 1 }
        return 0.97 + 0.03 * CGFloat(fullscreenGridEntranceProgress)
    }

    /// Calculates the folder overlay's horizontal translation, clamping it within the available pages.
    private func folderGridTranslation(pageWidth: CGFloat, totalPages: Int, basePageOffset: CGFloat) -> CGFloat {
        guard totalPages > 0 else { return basePageOffset }
        let maxScroll = CGFloat(max(totalPages - 1, 0)) * pageWidth
        let minTranslation = min(0, -maxScroll)
        let rawTranslation = basePageOffset + folderPagerDragOffset
        return min(max(rawTranslation, minTranslation), 0)
    }

    /// Builds the grid layer including empty state, the paged grid, and invisible gesture overlays.
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
                isEnabled: isKeyboardPagingEnabled || isRenamingItem || shouldHandleEscapeKeys,
                shouldCaptureArrowKeys: { shouldCaptureArrowKeys },
                shouldHandleEscape: { shouldHandleEscapeKeys },
                onPreviousPage: { handleKeyboardPager(.backward) },
                onNextPage: { handleKeyboardPager(.forward) },
                onEscape: { handleEscapeKeyPress() },
                onPageShortcut: { handlePageShortcutRequest($0) },
                onVerticalNavigation: { handleVerticalArrowNavigation($0) }
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

    /// Renders the lazy grid pages and wires drag gestures used for swiping between them.
    @ViewBuilder
    private func launcherGridPages(
        layout: LauncherLayoutMetrics,
        canReorder: Bool,
        gridProxy: GeometryProxy
    ) -> some View {
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

        launcherGridPage(
            layout: layout,
            pageIndex: pageIndex,
            pageWidth: pageWidth,
            pageItems: pageItems,
            pageStart: pageStart,
            itemCountOnPage: itemCountOnPage,
            canReorder: canReorder,
            gridProxy: gridProxy
        )
                .opacity(pageOpacity(for: pageIndex, pageWidth: pageWidth))
                .offset(x: pageOffset(for: pageIndex, pageWidth: pageWidth))
            }
        }
        .frame(width: pageWidth, height: layout.gridHeight, alignment: .leading)
        .gesture(dragGesture)
        .animation(activeGridAnimation, value: orderedItems)
        .onAppear {
            pagerViewportWidth = pageWidth
        }
        .onChange(of: gridProxy.size.width) { newWidth in
            pagerViewportWidth = max(newWidth, 1)
        }
    }

    /// Displays a single paged grid of items with drag-and-drop reordering and context menus.
    @ViewBuilder
    private func launcherGridPage(
        layout: LauncherLayoutMetrics,
        pageIndex: Int,
        pageWidth: CGFloat,
        pageItems: [LauncherItem],
        pageStart: Int,
        itemCountOnPage: Int,
        canReorder: Bool,
        gridProxy: GeometryProxy
    ) -> some View {
        LazyVGrid(
            columns: layout.gridColumns,
            alignment: .center,
            spacing: layout.iconSpacing
        ) {
            ForEach(Array(pageItems.enumerated()), id: \.element.id) { localIndex, item in
                let globalIndex = pageStart + localIndex
                let isLaunching = launchingItemID == item.id
                let isFolderBeingOpened = activeFolder?.id == item.id
                let isRenamingApp = renamingAppID == item.id
                let shouldShowSearchSelection = isRenamingApp == false && isSearchResultSelected(item: item, globalIndex: globalIndex)

                let cell: AnyView = {
                    if isRenamingApp, case let .app(app) = item {
                        return AnyView(
                            editableAppCell(app: app, layout: layout)
                        )
                    }

                    return AnyView(
                        Button {
                            if isMultiSelectModeActive {
                                toggleSelection(for: item)
                            } else {
                                openItem(item)
                            }
                        } label: {
                            VStack(spacing: 10) {
                                iconCell(for: item, layout: layout)
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

                let decoratedCell = AnyView(
                    cell
                        .background(alignment: .center) {
                            if shouldShowSearchSelection {
                                searchSelectionTile(layout: layout)
                                    .allowsHitTesting(false)
                                    .transition(.opacity)
                            }
                        }
                )
                .contentShape(Rectangle())
                .contextMenu {
                    itemContextMenu(for: item)
                }

                let liftEffect = gridArrangementEffect(for: item)
                let animatedCell = AnyView(
                    decoratedCell
                        .scaleEffect(liftEffect.scale)
                        .offset(y: liftEffect.offset)
                        .shadow(
                            color: Color.black.opacity(liftEffect.shadowOpacity),
                            radius: liftEffect.shadowRadius,
                            y: liftEffect.shadowYOffset
                        )
                        .animation(reorderLiftAnimation, value: liftEffect)
                )

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
        }
        .transaction { transaction in
            transaction.animation = activeGridAnimation
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
                performLiveReorder: { item, targetIndex in
                    reorderItem(
                        item,
                        to: targetIndex,
                        animated: true,
                        animation: liveReorderSpringAnimation
                    )
                },
                onModifierStateChange: handleDragModifierChange
            )
        )

    }

    private var fullscreenGridEntranceOpacity: Double {
        guard launcherMode == .fullscreen else { return 1 }
        return 0.35 + 0.65 * fullscreenGridEntranceProgress
    }

    private var fullscreenGridEntranceSaturation: Double {
        guard launcherMode == .fullscreen else { return 1 }
        return 0.6 + 0.4 * fullscreenGridEntranceProgress
    }

    private var fullscreenGridEntranceOffset: CGFloat {
        guard launcherMode == .fullscreen else { return 0 }
        return (1 - CGFloat(fullscreenGridEntranceProgress)) * fullscreenGridEntranceTranslation
    }
    private let gridSpringAnimation = Animation.spring(response: 0.42, dampingFraction: 0.86, blendDuration: 0.12)
    private let liveReorderSpringAnimation = Animation.interactiveSpring(response: 0.2, dampingFraction: 0.78, blendDuration: 0.12)
    private let folderReorderAnimation = Animation.interactiveSpring(response: 0.23, dampingFraction: 0.8, blendDuration: 0.12)
    private let reorderLiftAnimation = Animation.spring(response: 0.26, dampingFraction: 0.82, blendDuration: 0.1)
    private let fullscreenGridEntranceAnimation = Animation.easeOut(duration: 0.22)
    private let fullscreenGridEntranceTranslation: CGFloat = 28
    private let pageSwitchAnimation = Animation.easeOut(duration: 0.14)
    private let gestureSettleAnimation = Animation.easeOut(duration: 0.14)
    private let folderOpenAnimation = Animation.easeInOut(duration: 0.2)
    private let folderPreviewMatchReleaseDelay: TimeInterval = 0.42
    private let pagerButtonHitPadding: CGFloat = 12
    private let pagerButtonHitSize: CGFloat = 44
    private let pagerButtonHitExpansion: CGFloat = 12
    private let highQualityIconCacheLimit = 90
    private let highQualityRequestDelay: TimeInterval = 0.28
    private let searchInputDebounceNanoseconds: UInt64 = 35_000_000

    @State private var orderedItems: [LauncherItem]
    @State private var draggedItem: LauncherItem?
    @State private var dragOriginIndex: Int?
    @State private var isPerformingMultiSelectionDrag = false
    @State private var isDragModifierSnapActive = false
    @State private var currentPage: Int = 0
    @State private var isClosingLauncher = false
    @State private var searchText = ""
    @State private var cachedFilteredItems: [LauncherItem]
    @State private var searchMetadataByAppID: [UUID: SearchableAppEntry]
    @State private var searchSelectionIndex: Int?
    @State private var searchTask: Task<Void, Never>?
    @State private var searchRequestID: UInt = 0
    @State private var isSearchLoading = false
    @State private var searchDebounceTask: Task<Void, Never>?
    @State private var searchControlsExpanded = false
    @State private var lastNormalizedSearchQuery = ""
    @State private var isMultiSelectModeActive = false
    @State private var multiSelectedItemIDs: Set<UUID> = []
    @State private var expansionAutoCollapseTask: Task<Void, Never>?
    @State private var activeFolder: FolderItem?
    @State private var folderDragContext: FolderDragContext?
    @State private var draggedFolderApp: AppItem?
    @State private var activeFolderFrame: CGRect = .zero
    @State private var folderHoverWorkItem: DispatchWorkItem?
    @State private var folderHoverTargetID: UUID?
    @State private var folderHoverWithSuppressedReorder = false
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
    @State private var folderPreviewReleaseWorkItem: DispatchWorkItem?
    @State private var lastActiveFolderID: UUID?
    @State private var shouldSkipActiveFolderChangeEffects = false
    @Namespace private var folderIconAnimationNamespace
    private let highQualityRenderQueue = DispatchQueue(label: "com.launchy.icon.high", qos: .utility)
    private static let folderPreviewWarmupQueue = DispatchQueue(label: "com.launchy.icon.folder-preview", qos: .utility)
    private static let folderPreviewCache = FolderPreviewCache()
    @State private var pagerDragOffset: CGFloat = 0
    @State private var pagerViewportWidth: CGFloat = 1
    @State private var lastPagerDragDate: Date?
    @State private var folderPagerDragOffset: CGFloat = 0
    @State private var folderPagerViewportWidth: CGFloat = 1
    @State private var folderLastPagerDragDate: Date?
    @State private var pendingDropPage: Int?
    @State private var folderLiveReorderTargetIndex: Int?
    @State private var folderPreviewMatchingDisabled = false
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
        onAppInfoRequested: (() -> Void)? = nil,
        onItemOrderChange: (([LauncherItem], [Int]) -> Void)? = nil,
        onVisiblePagesChanged: (([AppItem]) -> Void)? = nil,
        iconProvider: @escaping @Sendable (AppItem, CGFloat, IconRenderQuality) -> NSImage? = { app, _, _ in app.iconImage }
    ) {
        self.itemCatalog = itemCatalog
        self.initialPageSizes = initialPageSizes
        self.backgroundStylePreference = backgroundStylePreference
        self.solidBackgroundColor = solidBackgroundColor
        self.launcherMode = launcherMode
        self.fillsGapsAutomatically = fillsGapsAutomatically
        self.onSettingsRequested = onSettingsRequested
        self.onAppInfoRequested = onAppInfoRequested
        self.onItemOrderChange = onItemOrderChange
        self.onVisiblePagesChanged = onVisiblePagesChanged
        self.iconProvider = iconProvider
        _orderedItems = State(initialValue: itemCatalog)
        _cachedFilteredItems = State(initialValue: itemCatalog)
        _searchMetadataByAppID = State(initialValue: Self.buildSearchMetadata(from: itemCatalog))
        _pageSizes = State(initialValue: initialPageSizes)
    }

    /// Builds the full launcher UI including background, grid, and pager controls.
    var body: some View {
        AnyView(bodyContent)
    }

    private var bodyContent: some View {
        GeometryReader { proxy in
            buildLauncherContent(for: proxy.size)
        }
        .onChange(of: itemCatalog) { newValue in
            orderedItems = newValue
            rebuildSearchMetadata(for: newValue)
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
        .onChange(of: activeFolder) { newValue in
            if shouldSkipActiveFolderChangeEffects {
                shouldSkipActiveFolderChangeEffects = false
                return
            }
            if newValue == nil {
                activeFolderFrame = .zero
                folderDragContext = nil
                draggedFolderApp = nil
                cancelFolderHover()
                isEditingFolderName = false
                folderNameDraft = ""
                isFolderNameFieldFocused = false
                withAnimation(folderOpenAnimation) {
                    folderIconWaveToggle = false
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
                lastActiveFolderID = folder.id
                folderPreviewMatchID = folder.id
                cancelFolderPreviewMatchRelease()
                folderNameDraft = folder.name
                isEditingFolderName = false
                folderPreviewMatchingDisabled = false
                launchingItemID = nil
                activeFolderPage = 0
                activeFolderPageCount = 1
            }
        }
        .onChange(of: searchText) { newValue in
            currentPage = 0
            pageDirection = .forward
            pagerDragOffset = 0
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
                folderSnapPreviewTargetID = nil
                dragOriginIndex = nil
                isDragModifierSnapActive = false
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
            rebuildSearchMetadata(for: newItems)
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

    /// Builds the full-screen filling layers for either floaty or fullscreen modes.
    @ViewBuilder
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

        let content = launcherContentBody(
            layout: layout,
            topInset: topInset,
            canReorder: canReorder,
            containerSize: containerSize
        )

        if launcherMode == .floaty {
            content
                .clipShape(RoundedRectangle(cornerRadius: layout.floatyCornerRadius, style: .continuous))
                .shadow(color: Color.black.opacity(0.25), radius: 40, y: 18)
                .overlay(
                    RoundedRectangle(cornerRadius: layout.floatyCornerRadius, style: .continuous)
                        .stroke(Color.white.opacity(0.4), lineWidth: 1.2)
                )
        } else {
            content
        }
    }

    /// Lays out the gradient background, search controls, and grid stack sized for the current mode.
    @ViewBuilder
    private func launcherContentBody(
        layout: LauncherLayoutMetrics,
        topInset: CGFloat,
        canReorder: Bool,
        containerSize: CGSize
    ) -> some View {
        ZStack {
            backgroundView()
                .ignoresSafeArea()

            if launcherMode == .floaty {
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.45),
                        Color(red: 0.56, green: 0.78, blue: 0.97).opacity(0.35),
                        Color(red: 0.45, green: 0.66, blue: 0.93).opacity(0.35)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .blendMode(.screen)
                .ignoresSafeArea()
            }

            VStack(spacing: 0) {
                fullscreenSpacer(height: topInset)

                VStack(spacing: 0) {
                    searchBar(layout: layout)
                    .padding(.top, layout.floatySearchBarTopPadding)
                    .padding(.bottom, layout.searchToGridSpacing)

                    launcherGridLayer(layout: layout, canReorder: canReorder)

                    gridPager(canReorder: canReorder, layout: layout)
                }
                .animation(nil, value: searchControlsExpanded)
                .padding(.horizontal, layout.horizontalPadding)
                .padding(.bottom, layout.bottomPadding)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            if let folder = activeFolder {
                folderOverlay(for: folder, layout: layout)
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

    /// Page count ignoring active search filters, used by context menus.
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
        isMultiSelectModeActive || draggedItem != nil || isRenamingItem || isEditingFolderName
    }

    private var isReorderDragActive: Bool {
        draggedItem != nil || draggedFolderApp != nil
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

    /// Calculates the current horizontal offset for the paged grid stack.
    private func pageOffset(for page: Int, pageWidth: CGFloat) -> CGFloat {
        let current = clampPageIndex(currentPage)
        return CGFloat(page - current) * pageWidth + pagerDragOffset
    }

    private var activeGridAnimation: Animation? {
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

    private func baseIconRequest(for layout: LauncherLayoutMetrics) -> (dimension: CGFloat, quality: IconRenderQuality) {
        if shouldUseHighQualityIcons {
            return (layout.iconDimension, .medium)
        }
        let scale = currentBackingScale()

        // Keep drag-time downgrade subtle and avoid over-blurring on low-DPI displays.
        let reduction: CGFloat = {
            if isArrangementEditingActive {
                return 1.0 // keep size stable during drag to avoid popping
            }
            return scale <= 1.2 ? 0.9 : 0.7
        }()

        let reduced = max(layout.iconDimension * reduction, scale <= 1.2 ? 58 : 52)
        let quality: IconRenderQuality = {
            if isArrangementEditingActive {
                return .medium // avoid quality swap on drag start
            }
            if scale <= 1.2 {
                return .medium
            }
            return launcherMode == .floaty ? .low : .medium
        }()
        return (reduced, quality)
    }

    private func folderTileIconRequest(for layout: LauncherLayoutMetrics) -> (dimension: CGFloat, quality: IconRenderQuality) {
        let base = baseIconRequest(for: layout)
        let scaledDimension = max(base.dimension * 0.6, 34)
        return (scaledDimension, .low)
    }

    private func folderPreviewIcon(for app: AppItem, layout: LauncherLayoutMetrics) -> NSImage? {
        let request = folderTileIconRequest(for: layout)
        let cache = Self.folderPreviewCache
        let key = cache.cacheKey(for: app, dimension: request.dimension, quality: request.quality)
        if let cached = cache.cachedIcon(for: key) {
            return cached
        }
        let resolved = iconProvider(app, request.dimension, request.quality) ?? app.iconImage
        if let resolved {
            cache.store(resolved, for: key)
        }
        return resolved
    }

    private func warmFolderPreviewIcons(for folder: FolderItem, layout: LauncherLayoutMetrics) {
        let request = folderTileIconRequest(for: layout)
        let apps = Array(folder.apps.prefix(9))
        guard apps.isEmpty == false else { return }
        let cache = Self.folderPreviewCache
        let keys = apps.map { cache.cacheKey(for: $0, dimension: request.dimension, quality: request.quality) }
        let missing = keys.contains { cache.cachedIcon(for: $0) == nil }
        guard missing else { return }

        let token = "\(folder.id.uuidString)|\(Int(request.dimension.rounded()))|\(apps.map(\.id).hashValue)"
        guard cache.beginWarmupIfNeeded(token: token) else { return }

        let provider: @Sendable (AppItem, CGFloat, IconRenderQuality) -> NSImage? = iconProvider
        let dimension = request.dimension
        let quality = request.quality
        let queue = Self.folderPreviewWarmupQueue
        queue.async {
            for (app, key) in zip(apps, keys) {
                if cache.cachedIcon(for: key) != nil {
                    continue
                }
                let resolved = provider(app, dimension, quality) ?? app.iconImage
                if let resolved {
                    cache.store(resolved, for: key)
                }
            }
            cache.finishWarmup(token: token)
        }
    }

    private func purgeFolderPreviewCache() {
        Self.folderPreviewCache.purge()
    }

    private func highQualityRequestDimension(for layout: LauncherLayoutMetrics) -> CGFloat {
        let boosted = max(layout.iconDimension * 1.2, layout.iconDimension)
        return min(boosted, 200)
    }

    private func markPageSwitch() {
        lastPageChangeDate = Date()
        bumpHighQualityRequestEpoch(resetPending: true)
        enterPerformanceShedding(duration: 0.45)
    }

    private func bumpHighQualityRequestEpoch(resetPending: Bool = false) {
        highQualityRequestEpoch &+= 1
        if resetPending {
            pendingHighQualityIconIDs.removeAll()
            delayedHighQualityRequests.removeAll()
        }
    }

    private func purgeHighQualityOverrides() {
        highQualityIconOverrides.removeAll()
        highQualityIconOrder.removeAll()
        pendingHighQualityIconIDs.removeAll()
        delayedHighQualityRequests.removeAll()
        bumpHighQualityRequestEpoch(resetPending: true)
    }

    private func cancelPendingHighQualityRequests() {
        pendingHighQualityIconIDs.removeAll()
        delayedHighQualityRequests.removeAll()
        bumpHighQualityRequestEpoch(resetPending: true)
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
        if isUnderInteractionPressure == false {
            enterPerformanceShedding(duration: 0.55, cancelHeavyWork: false)
        }

        let scale: CGFloat = isPrecise ? 1.0 : 13.0
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
        let snapThreshold: CGFloat = 0.07
        let fastThreshold: CGFloat = 0.18
        let doubleProgressThreshold: CGFloat = 1.35
        let highVelocityThreshold: CGFloat = 0.9
        let velocity = projectedDelta / normalizedWidth
        let absVelocity = abs(velocity)
        let absProgress = abs(progress)
        let recentDrag = (lastPagerDragDate.map { Date().timeIntervalSince($0) < 0.2 }) ?? false
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

        let targetPage = clampPageIndex(currentPage - delta)
        enterPerformanceShedding()
        withAnimation(gestureSettleAnimation) {
            pageDirection = targetPage >= currentPage ? .forward : .backward
            currentPage = targetPage
            pagerDragOffset = 0
            markPageSwitch()
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

    private func folderBeginPagerInteraction(pageWidth: CGFloat) {
        folderPagerViewportWidth = max(pageWidth, 1)
    }

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
        let snapThreshold: CGFloat = 0.07
        let fastThreshold: CGFloat = 0.22
        let doubleProgressThreshold: CGFloat = 1.65
        let highVelocityThreshold: CGFloat = 1.15
        let velocity = projectedDelta / normalizedWidth
        let absVelocity = abs(velocity)
        let absProgress = abs(progress)
        let recentDrag = (folderLastPagerDragDate.map { Date().timeIntervalSince($0) < 0.12 }) ?? false
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
        enterPerformanceShedding()
        withAnimation(gestureSettleAnimation) {
            pageDirection = targetPage >= activeFolderPage ? .forward : .backward
            activeFolderPage = targetPage
            folderPagerDragOffset = 0
            markPageSwitch()
        }
        folderLastPagerDragDate = nil
    }

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

    private func folderPageOpacity(for page: Int, pageWidth: CGFloat) -> Double {
        guard pageWidth > 0 else { return page == activeFolderPage ? 1 : 0 }
        let dragProgress = folderPagerDragOffset / pageWidth
        let distance = abs(CGFloat(page - activeFolderPage) + dragProgress)
        let visibility = max(0, 1 - distance)
        return Double(min(1, visibility))
    }

    private func folderClampPageIndex(_ index: Int) -> Int {
        guard activeFolderPageCount > 0 else { return 0 }
        return min(max(index, 0), activeFolderPageCount - 1)
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

    private func notifyVisiblePagesChanged() {
        guard let onVisiblePagesChanged else { return }
        let sizes = displayPageSizes
        let pages = visiblePageIndices(total: pageCount)
        var seen = Set<UUID>()
        var apps: [AppItem] = []
        for page in pages {
            for item in itemsForPage(page, sizes: sizes) {
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
        }
        onVisiblePagesChanged(apps)
    }

    /// Detects modifier keys that disable live reordering during a drag.
    private func isDragReorderSuppressed() -> Bool {
        if isMultiSelectionDragActive {
            return true
        }

        let flags = NSApp?.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
        return flags.contains(.shift) || flags.contains(.option)
    }

    private func handleDragModifierChange(_ active: Bool) {
        guard draggedItem != nil else {
            isDragModifierSnapActive = false
            return
        }
        guard isMultiSelectionDragActive == false else {
            return
        }

        if active {
            guard isDragModifierSnapActive == false else { return }
            isDragModifierSnapActive = true
            snapDraggedItemToOrigin()
        } else {
            isDragModifierSnapActive = false
        }
    }

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

    private func captureDragOrigin(for item: LauncherItem) {
        dragOriginIndex = orderedItems.firstIndex(of: item)
        isDragModifierSnapActive = false
        lastLiveReorderTargetIndex = nil
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

    /// Convenience overload for callers that do not care about swap semantics.
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
                activeFolder = folder
            }
        } else {
            orderedItems = updated
            activeFolder = folder
        }
        persistOrderChange()
    }

    /// Removes the dragged app from its folder and inserts it into the root grid to continue dragging.
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
        withAnimation(pageSwitchAnimation) {
            pageDirection = boundedTarget >= currentPage ? .forward : .backward
            currentPage = boundedTarget
            pagerDragOffset = 0
            markPageSwitch()
        }
    }

    /// Keeps the visible page index inside the bounds of the current arrangement.
    private func ensureCurrentPageWithinBounds() {
        let maxPage = max(fullPageCount - 1, 0)
        let boundedPage = min(currentPage, maxPage)
        if boundedPage != currentPage {
            withAnimation(pageSwitchAnimation) {
                pageDirection = boundedPage >= currentPage ? .forward : .backward
                currentPage = boundedPage
                pagerDragOffset = 0
                markPageSwitch()
            }
        } else {
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
        LauncherGridConfiguration.insertionIndex(
            for: page,
            itemsCount: orderedItems.count,
            pageCapacity: pageCapacity
        )
    }

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

    private func rebuildSearchMetadata(for items: [LauncherItem]) {
        searchMetadataByAppID = Self.buildSearchMetadata(from: items)
    }

    private func applySearchResults(_ results: [LauncherItem]) {
        cachedFilteredItems = results
        clampSearchSelectionIfNeeded()
        alignSearchSelectionWithCurrentPageIfNeeded()
        notifyVisiblePagesChanged()
    }

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

    private func updateFilteredItems(using itemsOverride: [LauncherItem]? = nil) {
        searchDebounceTask?.cancel()
        searchDebounceTask = nil
        let items = itemsOverride ?? orderedItems
        let query = normalizedSearchText
        let normalizedQuery = Self.primarySearchCacheKey(for: query)
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
        let metadata = searchMetadataByAppID
        let shouldFilterFromCache = itemsOverride == nil
            && lastNormalizedSearchQuery.isEmpty == false
            && normalizedQuery.hasPrefix(lastNormalizedSearchQuery)
            && cachedFilteredItems.isEmpty == false
        let filterBaseItems = shouldFilterFromCache ? cachedFilteredItems : items

        searchTask = Task(priority: .userInitiated) {
            let results = await Task.detached(priority: .userInitiated) {
                Self.filterItems(items: filterBaseItems, query: query, metadata: metadata)
            }.value

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

    private func cancelSearchTasks() {
        searchDebounceTask?.cancel()
        searchDebounceTask = nil
        searchTask?.cancel()
        searchTask = nil
    }

    nonisolated private static func filterItems(
        items: [LauncherItem],
        query: String,
        metadata: [UUID: SearchableAppEntry]
    ) -> [LauncherItem] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedQuery.isEmpty == false else { return items }

        let queryVariants = normalizedSearchVariants(for: trimmedQuery)
        guard queryVariants.isEmpty == false else { return items }
        let tokenVariants = queryVariants.map { tokenizeSearchValue($0) }
        let normalizedQuery = primarySearchCacheKey(for: trimmedQuery)
        var matches: [(score: Int, order: Int, item: LauncherItem)] = []
        var seenAppIDs = Set<UUID>()
        var orderIndex = 0

        for item in items {
            if Task.isCancelled {
                break
            }
            switch item {
            case .app(let app):
                if let score = appMatchScore(
                    app,
                    normalizedQuery: normalizedQuery,
                    queryVariants: queryVariants,
                    tokenVariants: tokenVariants,
                    metadata: metadata
                ),
                   seenAppIDs.insert(app.id).inserted {
                    matches.append((score: score, order: orderIndex, item: .app(app)))
                    orderIndex += 1
                } else {
                    orderIndex += 1
                }
            case .folder(let folder):
                let folderNameVariants = normalizedSearchVariants(for: folder.name)
                let folderNameMatches = queryVariants.contains { query in
                    folderNameVariants.contains { $0.contains(query) }
                }
                for app in folder.apps {
                    if Task.isCancelled {
                        break
                    }
                    let appScore = appMatchScore(
                        app,
                        normalizedQuery: normalizedQuery,
                        queryVariants: queryVariants,
                        tokenVariants: tokenVariants,
                        metadata: metadata
                    )
                    let score: Int? = {
                        if folderNameMatches {
                            return min(appScore ?? 2, 2)
                        }
                        return appScore
                    }()
                    if let score,
                       seenAppIDs.insert(app.id).inserted {
                        matches.append((score: score, order: orderIndex, item: .app(app)))
                        orderIndex += 1
                    } else {
                        orderIndex += 1
                    }
                }
            }
        }

        return matches
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.order < rhs.order
                }
                return lhs.score < rhs.score
            }
            .map(\.item)
    }

    nonisolated private static func appMatchScore(
        _ app: AppItem,
        normalizedQuery: String,
        queryVariants: [String],
        tokenVariants: [[String]],
        metadata: [UUID: SearchableAppEntry]
    ) -> Int? {
        if let entry = metadata[app.id] {
            return matchScore(
                entry: entry,
                queryVariants: queryVariants,
                tokenVariants: tokenVariants,
                fallbackQuery: normalizedQuery
            )
        }
        return app.matches(query: normalizedQuery) ? 4 : nil
    }

    nonisolated private static func buildSearchMetadata(from items: [LauncherItem]) -> [UUID: SearchableAppEntry] {
        var metadata: [UUID: SearchableAppEntry] = [:]

        let record: (AppItem) -> Void = { app in
            metadata[app.id] = buildSearchEntry(for: app)
        }

        for item in items {
            switch item {
            case .app(let app):
                record(app)
            case .folder(let folder):
                for app in folder.apps {
                    record(app)
                }
            }
        }

        return metadata
    }

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

    nonisolated private static func uniqueSearchValues(from values: [String]) -> [String] {
        values.reduce(into: [String]()) { unique, value in
            guard value.isEmpty == false else { return }
            let exists = unique.contains { $0.caseInsensitiveCompare(value) == .orderedSame }
            if exists == false {
                unique.append(value)
            }
        }
    }

    nonisolated private static func tokenizeSearchValue(_ value: String) -> [String] {
        let parts = value.components(separatedBy: CharacterSet.alphanumerics.inverted)
        return parts.filter { $0.isEmpty == false }
    }

    nonisolated private static func normalizedSearchVariants(for value: String) -> [String] {
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

    nonisolated private static func normalizeSearchValue(_ value: String, locale: Locale) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: locale)
    }

    nonisolated private static func latinizedSearchValue(_ value: String, locale: Locale) -> String? {
        guard let latin = value.applyingTransform(.toLatin, reverse: false) else { return nil }
        let stripped = latin.applyingTransform(.stripCombiningMarks, reverse: false) ?? latin
        let normalized = normalizeSearchValue(stripped, locale: locale)
        return normalized.isEmpty ? nil : normalized
    }

    nonisolated private static func primarySearchCacheKey(for value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return "" }
        return normalizeSearchValue(trimmed, locale: .current)
    }

    private func clampSearchSelectionIfNeeded() {
        guard isSearchModeActive else {
            searchSelectionIndex = nil
            return
        }
        guard let index = activeSearchSelectionIndex else { return }
        selectSearchResult(at: index, animated: false)
    }

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

    private func pageHasSpace(_ page: Int) -> Bool {
        guard pageCapacity > 0 else { return false }
        let sizes = activePageSizes(for: orderedItems.count)
        guard page < sizes.count else { return true }
        return sizes[page] < pageCapacity
    }

    private func shouldAllowWiggle(id: UUID) -> Bool {
        guard isArrangementEditingActive else { return false }
        guard hasActiveSearchQuery == false else { return false }
        guard isClosingLauncher == false else { return false }
        guard launchingItemID != id else { return false }
        guard draggedItem?.id != id else { return false }
        return true
    }

    private func shouldWiggle(item: LauncherItem) -> Bool {
        switch item {
        case .app(let app):
            return shouldAllowWiggle(id: app.id)
        case .folder(let folder):
            return shouldAllowWiggle(id: folder.id)
        }
    }

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

    nonisolated private static func wiggleSeed(for id: UUID) -> WiggleSeed {
        let hash = wiggleHash(for: id)
        let phase = wiggleComponent(from: hash, lower: 0, upper: 2 * .pi)
        let intensity = wiggleComponent(from: hash >> 16, lower: 0.9, upper: 1.1)
        let rate = wiggleComponent(from: hash >> 32, lower: 0.92, upper: 1.08)
        return WiggleSeed(phase: phase, intensity: intensity, rate: rate)
    }

    nonisolated private static func wiggleComponent(from value: UInt64, lower: Double, upper: Double) -> Double {
        let normalized = Double(value & 0xFFFF) / Double(UInt16.max)
        return lower + (upper - lower) * normalized
    }

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

    private func gridArrangementEffect(for item: LauncherItem) -> ArrangementEffect {
        arrangementEffect(
            isDragged: draggedItem?.id == item.id,
            neighborDistance: gridNeighborDistance(for: item.id)
        )
    }

    private func folderArrangementEffect(for app: AppItem, in folder: FolderItem) -> ArrangementEffect {
        arrangementEffect(
            isDragged: draggedFolderApp?.id == app.id || currentDraggedApp()?.id == app.id,
            neighborDistance: folderNeighborDistance(for: app, in: folder)
        )
    }

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

    private func gridNeighborDistance(for id: UUID) -> Int? {
        neighborDistance(
            for: id,
            in: orderedItems,
            targetIndex: currentGridReorderTargetIndex()
        )
    }

    private func folderNeighborDistance(for app: AppItem, in folder: FolderItem) -> Int? {
        neighborDistance(
            for: app.id,
            in: folder.apps,
            targetIndex: currentFolderReorderTargetIndex(for: folder)
        )
    }

    private func currentGridReorderTargetIndex() -> Int? {
        if let live = lastLiveReorderTargetIndex {
            return live
        }
        if let dragged = draggedItem, let index = orderedItems.firstIndex(of: dragged) {
            return index
        }
        return dragOriginIndex
    }

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

    /// Picks either the discovered icon or the fallback system glyph.
    @ViewBuilder
    private func iconView(for item: LauncherItem, layout: LauncherLayoutMetrics) -> some View {
        switch item {
        case .app(let app):
            iconForApp(app, layout: layout)
        case .folder(let folder):
            folderIcon(for: folder, layout: layout)
        }
    }

    @ViewBuilder
    private func iconForApp(_ app: AppItem, layout: LauncherLayoutMetrics) -> some View {
        let request = baseIconRequest(for: layout)
        let baseIcon = iconProvider(app, request.dimension, request.quality) ?? app.iconImage
        let highIcon = shouldUseHighQualityIcons ? highQualityIconOverrides[app.id] : nil
        let baseScale: CGFloat = request.quality == .low ? 0.994 : 1

        ZStack {
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

            if let detailedIcon = highIcon {
                Image(nsImage: detailedIcon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .transition(.opacity)
                    .opacity(1)
            }
        }
        .onAppear {
            requestHighQualityIconIfNeeded(for: app, layout: layout)
        }
    }

    private func iconCell(for item: LauncherItem, layout: LauncherLayoutMetrics) -> some View {
        let isSelected = isMultiSelectModeActive && multiSelectedItemIDs.contains(item.id)
        return iconView(for: item, layout: layout)
            .frame(width: layout.iconDimension, height: layout.iconDimension)
            .overlay(selectionHighlight(for: item, layout: layout, isSelected: isSelected))
            .modifier(wiggleMotion(for: item.id, layout: layout, isActive: shouldWiggle(item: item)))
            .shadow(color: Color.accentColor.opacity(isSelected ? 0.28 : 0), radius: isSelected ? 10 : 0, y: isSelected ? 2 : 0)
            .blendMode(isSelected ? .screen : .normal)
            .animation(.easeInOut(duration: 0.18), value: isSelected)
    }

    @ViewBuilder
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

    private func searchSelectionTileSize(for layout: LauncherLayoutMetrics) -> CGSize {
        let widthPadding = max(layout.iconDimension * 0.42, 32)
        let heightPadding = max(layout.iconDimension * 0.62, 48)
        return CGSize(
            width: layout.iconDimension + widthPadding,
            height: layout.iconDimension + heightPadding
        )
    }

    private func searchSelectionCornerRadius(for layout: LauncherLayoutMetrics) -> CGFloat {
        max(layout.iconDimension * 0.34, 18)
    }

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
    private func folderIcon(for folder: FolderItem, layout: LauncherLayoutMetrics) -> some View {
        let previews = Array(folder.apps.prefix(9))
        let spacing = max(layout.iconDimension * 0.035, 2)
        let padding = spacing * 1.05
        let tileSize = max(((layout.iconDimension * 0.9) - padding * 2 - spacing * 2) / 3, 9)
        let columns = Array(repeating: GridItem(.fixed(tileSize), spacing: spacing, alignment: .center), count: 3)
        let isSnapPreviewTarget = folder.id == folderSnapPreviewTargetID

        let isActiveFolder = activeFolder?.id == folder.id
        let shouldAnimatePreview = folderPreviewMatchID == folder.id
            && folderPreviewMatchingDisabled == false

        return ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.35))
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)

            LazyVGrid(columns: columns, alignment: .center, spacing: spacing) {
                ForEach(previews, id: \.id) { app in
                    let tile = folderTile(for: app, layout: layout)
                        .frame(width: tileSize, height: tileSize)

                    if shouldAnimatePreview {
                        tile.matchedGeometryEffect(
                            id: folderPreviewAnimationID(for: folder, app: app),
                            in: folderIconAnimationNamespace,
                            isSource: isActiveFolder
                        )
                    } else {
                        tile
                    }
                }
                ForEach(0..<max(0, 9 - previews.count), id: \.self) { _ in
                    Color.clear
                        .frame(width: tileSize, height: tileSize)
                }
            }
            .padding(padding)
            .animation(folderOpenAnimation, value: folderIconWaveToggle)

            if isSnapPreviewTarget {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
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
        .animation(.easeInOut(duration: 0.25), value: isSnapPreviewTarget)
        .animation(folderOpenAnimation, value: folderIconWaveToggle)
        .environment(\.colorScheme, colorScheme)
        .animation(nil, value: searchControlsExpanded)
        .onAppear {
            warmFolderPreviewIcons(for: folder, layout: layout)
        }
        .onChange(of: folder.apps.map(\.id)) { _ in
            warmFolderPreviewIcons(for: folder, layout: layout)
        }
    }

    /// Shows a single tiny app icon inside the folder preview grid.
    @ViewBuilder
    private func folderTile(for app: AppItem, layout: LauncherLayoutMetrics) -> some View {
        let resolvedIcon = folderPreviewIcon(for: app, layout: layout)
        Group {
            if let icon = resolvedIcon {
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
        .onAppear {
            requestHighQualityIconIfNeeded(for: app, layout: layout)
        }
    }

    private func folderPreviewAnimationID(for folder: FolderItem, app: AppItem) -> String {
        "\(folder.id.uuidString)-\(app.id.uuidString)"
    }

    private func isPreviewApp(_ app: AppItem, in folder: FolderItem) -> Bool {
        guard let index = folder.apps.firstIndex(where: { $0.id == app.id }) else { return false }
        return index < 9
    }

    private func displayIcon(for app: AppItem, layout: LauncherLayoutMetrics) -> NSImage? {
        // Prefer any cached high-quality icon to avoid visible swaps when entering wiggle/drag.
        if let detailed = highQualityIconOverrides[app.id] {
            return detailed
        }
        let request = baseIconRequest(for: layout)
        return iconProvider(app, request.dimension, request.quality) ?? app.iconImage
    }

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
        let provider: @Sendable (AppItem, CGFloat, IconRenderQuality) -> NSImage? = iconProvider
        let cachedAppIcon = app.iconImage
        if pendingHighQualityIconIDs.insert(app.id).inserted == false {
            return
        }
        let requestEpoch = highQualityRequestEpoch
        let pressureEpoch = interactionPressureEpoch
        highQualityRenderQueue.async {
            let detailed = provider(app, targetDimension, .high)
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
    private func recordHighQualityIcon(_ icon: NSImage, for id: UUID) {
        guard highQualityIconOverrides[id] == nil else { return }
        withAnimation(.easeInOut(duration: 0.16)) {
            highQualityIconOverrides[id] = icon
            highQualityIconOrder.append(id)
            trimHighQualityIconCacheIfNeeded()
        }
    }

    @MainActor
    private func trimHighQualityIconCacheIfNeeded() {
        let overflow = highQualityIconOverrides.count - highQualityIconCacheLimit
        guard overflow > 0 else { return }
        let removable = highQualityIconOrder.prefix(overflow)
        for id in removable {
            highQualityIconOverrides.removeValue(forKey: id)
        }
        highQualityIconOrder.removeFirst(min(overflow, highQualityIconOrder.count))
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
    private func pagerDots(currentPage: Int, totalPages: Int, onSelect: ((Int) -> Void)? = nil) -> some View {
        HStack(spacing: 6) {
            let pageCount = max(totalPages, 1)
            ForEach(0..<pageCount, id: \.self) { index in
                let isDisabled = onSelect == nil || index >= totalPages
                Button {
                    onSelect?(index)
                } label: {
                    Circle()
                        .fill(pagerControlForegroundColor.opacity(index == currentPage ? 0.9 : 0.35))
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
        let button = PagerChevronButtonView(
            systemName: systemName,
            disabled: disabled,
            foregroundColor: pagerControlForegroundColor.opacity(disabled ? 0.35 : 0.8),
            hitPadding: pagerButtonHitPadding,
            hitSize: pagerButtonHitSize,
            hitExpansion: pagerButtonHitExpansion,
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
        let action: () -> Void

        @State private var didTriggerOnPress = false

        var body: some View {
            Button(action: triggerIfNeededFromRelease) {
                Image(systemName: systemName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(foregroundColor)
                    .frame(width: 28, height: 28)
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

        private func triggerFromPress() {
            guard didTriggerOnPress == false else { return }
            didTriggerOnPress = true
            action()
        }

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
        let allowPreviewMatch = folderPreviewMatchID == folder.id
            && isArrangementEditingActive == false
            && folderPreviewMatchingDisabled == false
        let gridInsets = overlayLayout.gridInsets

        GeometryReader { gridProxy in
            LazyVGrid(columns: columns, alignment: .center, spacing: overlayLayout.spacing) {
                ForEach(Array(pageApps.enumerated()), id: \.element.id) { _, app in
                    let isLaunching = launchingItemID == app.id
                    let isRenaming = renamingAppID == app.id
                    let cell: AnyView = {
                        if isRenaming {
                            return AnyView(
                                editableAppCell(app: app, layout: layout, fontSize: 14)
                            )
                        }

                        let iconBase = iconView(for: .app(app), layout: layout)
                            .frame(width: tileSize, height: tileSize)
                            .scaleEffect(isLaunching ? 1.08 : 1.0)
                            .opacity(isLaunching ? 0.4 : 1.0)
                            .animation(.easeInOut(duration: 0.18), value: launchingItemID)
                            .opacity(folderIconWaveToggle ? 1 : 0)
                            .animation(folderOpenAnimation, value: folderIconWaveToggle)
                            .modifier(wiggleMotion(for: app.id, layout: layout, isActive: shouldAllowWiggle(id: app.id)))
                            .environment(\.colorScheme, colorScheme)

                        return AnyView(
                            Button {
                                openItem(.app(app))
                            } label: {
                                VStack(spacing: 10) {
                                    if isPreviewApp(app, in: folder), allowPreviewMatch {
                                        iconBase
                                            .matchedGeometryEffect(
                                                id: folderPreviewAnimationID(for: folder, app: app),
                                                in: folderIconAnimationNamespace,
                                                isSource: activeFolder?.id != folder.id
                                            )
                                    } else {
                                        iconBase
                                    }

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
                        )
                    }()

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
                                draggedItem = .app(app)
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
                transaction.animation = folderReorderAnimation
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
                folderPagerViewportWidth = pageWidth
            }
            .onChange(of: pageWidth) { newWidth in
                folderPagerViewportWidth = max(newWidth, 1)
            }
        }
        .frame(height: overlayLayout.gridHeight)
    }

    /// Displays a blurred overlay showing a folder's contents with Launchpad-inspired styling.
    @ViewBuilder
    private func folderOverlay(for folder: FolderItem, layout: LauncherLayoutMetrics) -> some View {
        GeometryReader { proxy in
            let overlayLayout = folderOverlayLayout(for: folder, containerSize: proxy.size, layout: layout)
            ZStack {
                backgroundView()
                    .ignoresSafeArea()
                Color.black
                    .opacity(folderIconWaveToggle ? 0.2 : 0)
                    .ignoresSafeArea()

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
                .background(
                    searchBarBackgroundMaterial()
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.25))
                )
                .shadow(color: .black.opacity(0.3), radius: 24, y: 14)
                .opacity(folderIconWaveToggle ? 1 : 0)
                .animation(folderOpenAnimation, value: folderIconWaveToggle)
                .anchorPreference(key: FolderFramePreference.self, value: .bounds) { anchor in
                    proxy[anchor]
                }
            }
            .onPreferenceChange(FolderFramePreference.self) { frame in
                activeFolderFrame = frame
            }
            .contentShape(Rectangle())
            .onTapGesture {
                closeActiveFolder()
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
            .transition(.opacity)
            .onAppear {
                warmFolderPreviewIcons(for: folder, layout: layout)
                updateActiveFolderPageCount(pageCount)
                if folderIconWaveToggle == false {
                    withAnimation(folderOpenAnimation) {
                        folderIconWaveToggle = true
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
            Text(orderedItems.isEmpty ? String(localized: "No items found") : String(localized: "No matching items"))
                .font(.title3)
                .foregroundColor(primaryForeground)
            if orderedItems.isEmpty == false && searchText.isEmpty == false {
                Text(String(localized: "Try a different search term."))
                    .foregroundColor(secondaryForeground)
            } else if orderedItems.isEmpty {
                Text(String(localized: "Launchy has not indexed any applications yet."))
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
            folderPreviewMatchID = folder.id
            cancelFolderPreviewMatchRelease()
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

    private func currentBackingScale() -> CGFloat {
        hostingWindow()?.backingScaleFactor
        ?? NSScreen.main?.backingScaleFactor
        ?? 2.0
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

    private func handleVerticalArrowNavigation(_ direction: KeyPressPagerOverlay.VerticalArrowDirection) {
        guard isSearchModeActive else { return }
        navigateSearchResultsVertically(direction)
    }

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

    private func navigateSearchResultsVertically(_ direction: KeyPressPagerOverlay.VerticalArrowDirection) {
        guard filteredItemList.isEmpty == false else { return }
        let columns = LauncherGridConfiguration.columnsPerPage

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

    private func createSearchSelectionIfNeeded(seedIndex: Int) {
        guard isSearchModeActive else { return }
        guard filteredItemList.isEmpty == false else { return }
        guard activeSearchSelectionIndex == nil else { return }
        let bounded = min(max(seedIndex, 0), filteredItemList.count - 1)
        searchSelectionIndex = bounded
        selectSearchResult(at: bounded)
    }

    private func selectSearchResult(at index: Int, animated: Bool = true) {
        guard isSearchModeActive else { return }
        let bounded = min(max(index, 0), filteredItemList.count - 1)
        guard bounded >= 0 else { return }
        let previousPage = currentPage
        searchSelectionIndex = bounded
        guard let targetPage = pageIndex(forLinearIndex: bounded, sizes: displayPageSizes) else { return }
        guard targetPage != currentPage else { return }

        let applyPageChange = {
            pageDirection = targetPage >= previousPage ? .forward : .backward
            currentPage = targetPage
            pagerDragOffset = 0
            markPageSwitch()
        }

        if animated {
            enterPerformanceShedding()
            withAnimation(pageSwitchAnimation) {
                applyPageChange()
            }
        } else {
            applyPageChange()
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
        if animated {
            withAnimation(folderOpenAnimation) {
                activeFolder = nil
            }
        } else {
            activeFolder = nil
        }
    }

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

    private func cancelFolderPreviewMatchRelease() {
        folderPreviewReleaseWorkItem?.cancel()
        folderPreviewReleaseWorkItem = nil
    }

    /// Moves to the previous page if possible.
    private func pageBackward() {
        guard pageCount > 0 else { return }
        enterPerformanceShedding()
        withAnimation(pageSwitchAnimation) {
            pageDirection = .backward
            currentPage = max(currentPage - 1, 0)
            pagerDragOffset = 0
            markPageSwitch()
        }
    }

    /// Jumps directly to a target page and animates directionally.
    private func jumpToPage(_ targetPage: Int) {
        guard pageCount > 0 else { return }
        let bounded = min(max(targetPage, 0), pageCount - 1)
        guard bounded != currentPage else { return }
        enterPerformanceShedding()
        withAnimation(pageSwitchAnimation) {
            pageDirection = bounded >= currentPage ? .forward : .backward
            currentPage = bounded
            pagerDragOffset = 0
            markPageSwitch()
        }
    }

    /// Moves to the next page if possible.
    private func pageForward() {
        guard pageCount > 0 else { return }
        enterPerformanceShedding()
        withAnimation(pageSwitchAnimation) {
            pageDirection = .forward
            currentPage = min(currentPage + 1, pageCount - 1)
            pagerDragOffset = 0
            markPageSwitch()
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

    /// Chooses the right search bar variant based on the launcher mode.
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

    private func searchFieldBody(layout: LauncherLayoutMetrics, isFloaty: Bool) -> some View {
        TextField(String(localized: "Search"), text: $searchText)
            .textFieldStyle(.plain)
            .font(.system(size: layout.searchBarFontSize, weight: .medium))
            .foregroundColor(searchBarForegroundColor())
            .accentColor(searchBarCursorColor)
            .focused($isSearchFieldFocused)
            .onSubmit {
                launchSearchResultIfPossible()
            }
            .padding(.leading, 18)
            .padding(.trailing, 14)
            .frame(width: layout.searchBarWidth, height: layout.searchBarHeight)
            .background(searchFieldBackground(isFloaty: isFloaty, layout: layout))
            .overlay(
                RoundedRectangle(cornerRadius: layout.searchBarCornerRadius, style: .continuous)
                    .strokeBorder(isMultiSelectModeActive ? Color.accentColor.opacity(0.7) : Color.white.opacity(isFloaty ? 0.4 : 0.25), lineWidth: isMultiSelectModeActive ? 2 : 1)
            )
            .overlay(alignment: .trailing) {
                searchBarTrailingDecorations()
            }
            .shadow(color: .black.opacity(isFloaty ? 0.18 : 0.2), radius: isFloaty ? 18 : 12, y: isFloaty ? 6 : 4)
            .frame(width: layout.searchBarWidth)
            .frame(maxWidth: .infinity)
            .environment(\.colorScheme, searchBarColorSchemeOverride())
    }

    private func searchFieldBackground(isFloaty: Bool, layout: LauncherLayoutMetrics) -> some View {
        Group {
            if isFloaty {
                ZStack {
                    searchBarBackgroundMaterial()
                    Color.white.opacity(colorScheme == .dark ? 0.12 : 0.78)
                }
            } else {
                searchBarBackgroundMaterial()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: layout.searchBarCornerRadius, style: .continuous))
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
            .help(searchText.isEmpty ? String(localized: "More actions") : String(localized: "Clear search text"))

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
                .help(String(localized: "Launchy info"))

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
                .help(String(localized: "Launcher settings"))
            }
            .padding(.trailing, 14)
            .opacity(isSearchControlsVisible ? 1 : 0)
            .allowsHitTesting(isSearchControlsVisible)
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
            .animation(searchControlsAnimation, value: searchControlsExpanded)
        }
    }

    @ViewBuilder
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
                            isMultiSelectModeActive ? Color.accentColor.opacity(0.9) : Color.white.opacity(0.4),
                            lineWidth: isMultiSelectModeActive ? 2.2 : 1
                        )
                )
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .help(isMultiSelectModeActive ? String(localized: "Exit multi-select mode") : String(localized: "Enter multi-select mode"))
    }

    private func toggleSearchControlsExpansion() {
        guard searchText.isEmpty else { return }
        let shouldExpand = !searchControlsExpanded
        if shouldExpand == false {
            exitMultiSelectMode()
        }
        updateSearchControlsExpansion(to: shouldExpand)
    }

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

    private func cancelExpansionAutoCollapse() {
        expansionAutoCollapseTask?.cancel()
        expansionAutoCollapseTask = nil
    }

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

    private func shouldStartMultiSelectionDrag(for item: LauncherItem) -> Bool {
        guard isMultiSelectModeActive else { return false }
        guard multiSelectedItemIDs.contains(item.id) else { return false }
        guard selectedLauncherItems.count > 1 else { return false }
        return true
    }

    private func multiSelectTargets(for item: LauncherItem) -> [LauncherItem] {
        let selection = selectedLauncherItems
        if isMultiSelectModeActive && selection.isEmpty == false {
            return selection
        }
        return [item]
    }

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

    private func canAddSelection(to folder: FolderItem) -> Bool {
        guard isMultiSelectModeActive else { return false }
        let selection = selectedLauncherItems.filter { $0.id != folder.id }
        return selection.isEmpty == false
    }

    private var canCreateFolderFromSelection: Bool {
        selectedAppEntries.count >= 2
    }

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

    /// Context menu shown for each grid item.
    @ViewBuilder
    private func itemContextMenu(for item: LauncherItem) -> some View {
        Button(String(localized: "Open")) {
            openItem(item)
        }

        switch item {
        case .app(let app):
            Button(String(localized: "Rename App")) {
                beginAppRename(app)
            }

            Button(String(localized: "Show in Finder")) {
                showInFinder(app)
            }
            .disabled(app.bundleURL == nil)

            Menu(String(localized: "Move to Folder")) {
                folderMoveMenu(for: multiSelectAppTargets(for: item))
            }

            Menu(String(localized: "Move to Page")) {
                pageMoveMenu(for: item)
            }

            Button(String(localized: "Hide App")) {
                hideApp(app)
                finalizeBulkSelectionAction()
            }

            if isMultiSelectModeActive,
               multiSelectedItemIDs.contains(app.id),
               canCreateFolderFromSelection
            {
                Button(String(localized: "Create Folder with Selection")) {
                    createFolderFromSelection(promptForName: true)
                }
            }

            if isMultiSelectModeActive == false || multiSelectedItemIDs.contains(app.id) == false {
                Button(String(localized: "Create Folder with App")) {
                    createFolder(from: app, promptForName: true)
                }
            }
        case .folder(let folder):
            Button(String(localized: "Folder Details")) {
                showItemDetails(item)
            }

            Button(String(localized: "Rename Folder")) {
                beginFolderRename(folder)
            }

            if isMultiSelectModeActive {
                Button(String(localized: "Add Selection to Folder")) {
                    mergeMultiSelection(into: .folder(folder))
                }
                .disabled(canAddSelection(to: folder) == false)
            }

            Menu(String(localized: "Move to Page")) {
                pageMoveMenu(for: item)
            }
        }
    }

    /// Nested menu showing available folders for an app move.
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
            Button(String(localized: "No apps selected")) { }
                .disabled(true)
        } else if sortedFolders.isEmpty {
            Button(String(localized: "No folders available")) { }
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

    private func newPageInsertionOptions(totalPages: Int) -> [PageInsertionOption] {
        let pageCount = max(totalPages, 1)
        var options: [PageInsertionOption] = [
            PageInsertionOption(
                insertionIndex: 0,
                title: String(localized: "Insert at Beginning")
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
                            String(localized: "Insert between Page %lld and %lld"),
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
                title: String(localized: "Insert at End")
            )
        )
        return options
    }

    /// Nested menu listing pages for quick jumps.
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
                    String(localized: "Page %lld"),
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

        Menu(String(localized: "Create New Page")) {
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

    /// Context menu for the empty grid background.
    @ViewBuilder
    private func backgroundContextMenu() -> some View {
        if isMultiSelectModeActive && canCreateFolderFromSelection {
            Button(String(localized: "Create Folder with Selection")) {
                createFolderFromSelection(promptForName: true)
            }
        }

        Button(String(localized: "Create Folder")) {
            createEmptyFolder(onPage: currentPage, promptForName: true)
        }

        Button(String(localized: "Settings...")) {
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
        folderIconWaveToggle = false
        withAnimation(folderOpenAnimation) {
            activeFolder = folder
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
            persistOrderChange(using: pageSizes)
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
        if activeFolder?.id == folder.id {
            activeFolder = folder
        }
        ensureCurrentPageWithinBounds()
        persistOrderChange(using: pageSizes)
    }

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

    private func moveItems(_ items: [LauncherItem], toPage targetPage: Int) {
        for item in items {
            moveItem(item, toPage: targetPage)
        }
    }

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
        }
        pageSizes = finalSizes
        ensureCurrentPageWithinBounds()
        persistOrderChange(using: finalSizes)
    }

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
        }
        pageSizes = finalSizes
        ensureCurrentPageWithinBounds()
        persistOrderChange(using: finalSizes)
    }

    private func finalizeBulkSelectionAction() {
        guard isMultiSelectModeActive else { return }
        exitMultiSelectMode()
        updateSearchControlsExpansion(to: false)
    }

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
