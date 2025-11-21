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

private struct RemovedAppContext {
    var items: [LauncherItem]
    var app: AppItem
    var suggestedIndex: Int
}

/// Displays the grid of discovered items (apps and folders) and handles pagination/launch events.
struct LauncherView: View {
    /// Data source backing the grid.
    let itemCatalog: [LauncherItem]
    /// Selected background presentation.
    var backgroundStylePreference: LauncherSettings.PreferredBackgroundStyle = .automatic
    /// Current presentation mode so layout can adapt between floaty and fullscreen.
    var launcherMode: LauncherMode = .floaty
    /// Callback fired whenever the user changes the arrangement.
    var onItemOrderChange: (([LauncherItem]) -> Void)?

    private var pageCapacity: Int { LauncherGridConfiguration.pageCapacity }
    private let closeAnimationDuration: TimeInterval = 0.25
    private let closeAnimationSlideOffset: CGFloat = 28

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
    @State private var folderNameDraft = ""
    @FocusState private var isFolderNameFieldFocused: Bool

    init(
        itemCatalog: [LauncherItem],
        backgroundStylePreference: LauncherSettings.PreferredBackgroundStyle = .automatic,
        launcherMode: LauncherMode = .floaty,
        onItemOrderChange: (([LauncherItem]) -> Void)? = nil
    ) {
        self.itemCatalog = itemCatalog
        self.backgroundStylePreference = backgroundStylePreference
        self.launcherMode = launcherMode
        self.onItemOrderChange = onItemOrderChange
        _orderedItems = State(initialValue: itemCatalog)
    }

    /// Builds the full launcher UI including background, grid, and pager controls.
    var body: some View {
        GeometryReader { proxy in
            buildLauncherContent(for: proxy.size)
        }
        .onChange(of: itemCatalog) { newValue in
            orderedItems = newValue
            currentPage = 0
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
            } else if let folder = newValue {
                folderNameDraft = folder.name
                isEditingFolderName = false
            }
        }
        .onChange(of: searchText) { _ in
            currentPage = 0
        }
        .onChange(of: orderedItems) { newItems in
            let maxPage = max(pageCount - 1, 0)
            currentPage = min(currentPage, maxPage)
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
                                    LazyVGrid(
                                        columns: layout.gridColumns,
                                        alignment: .center,
                                        spacing: layout.iconSpacing
                                    ) {
                                        ForEach(Array(itemsForVisiblePage.enumerated()), id: \.element.id) { _, item in
                                            let cell = Button {
                                                openItem(item)
                                            } label: {
                                                VStack(spacing: 10) {
                                                    iconView(for: item, layout: layout)
                                                        .frame(
                                                            width: layout.iconDimension,
                                                            height: layout.iconDimension
                                                        )
                                                    Text(item.displayName)
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
                                            .contextMenu {
                                                itemContextMenu(for: item)
                                            }

                                            if canReorder {
                                                cell
                                                    .onDrag {
                                                        draggedItem = item
                                                        return NSItemProvider(object: NSString(string: item.id.uuidString))
                                                    }
                                            } else {
                                                cell
                                            }
                                        }
                                    }
                                    .frame(maxWidth: .infinity, minHeight: layout.gridHeight, alignment: .top)
                                    .contentShape(Rectangle())
                                    .contextMenu {
                                        backgroundContextMenu()
                                    }
                                    .onDrop(
                                        of: [.text],
                                            delegate: GridReorderDropDelegate(
                                                layout: layout,
                                                gridSize: gridProxy.size,
                                                currentPage: currentPage,
                                                pageCapacity: pageCapacity,
                                                items: $orderedItems,
                                                draggedItem: $draggedItem,
                                                shouldSuppressReorder: { isDragReorderSuppressed() },
                                                performReorder: reorderItem(_:to:preferSwap:),
                                                afterReorder: updatePageAfterDrop(at:),
                                                onDropOnItem: handleFolderHover(dragged:onto:),
                                                onFolderHoverExit: cancelFolderHover
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
                        .disabled(currentPage == 0 || orderedItems.isEmpty)

                        if canReorder {
                            previousButton.onDrop(
                                of: [.text],
                                delegate: PageReorderDropDelegate(
                                    targetPage: currentPage - 1,
                                    pageCapacity: pageCapacity,
                                    items: $orderedItems,
                                    draggedItem: $draggedItem,
                                    performReorder: reorderItem(_:to:),
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
                        .disabled(orderedItems.isEmpty || currentPage >= pageCount - 1)

                        if canReorder {
                            nextButton.onDrop(
                                of: [.text],
                                delegate: PageReorderDropDelegate(
                                    targetPage: currentPage + 1,
                                    pageCapacity: pageCapacity,
                                    items: $orderedItems,
                                    draggedItem: $draggedItem,
                                    performReorder: reorderItem(_:to:),
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

            if let folder = activeFolder {
                folderOverlay(for: folder, layout: layout)
            }
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
        guard filteredItemList.isEmpty == false else { return 1 }
        return (filteredItemList.count + pageCapacity - 1) / pageCapacity
    }

    /// Page count ignoring active search filters, used by context menus.
    private var fullPageCount: Int {
        guard orderedItems.isEmpty == false else { return 1 }
        return (orderedItems.count + pageCapacity - 1) / pageCapacity
    }

    /// Determines when gesture-driven paging should be active.
    private var isGesturePagingEnabled: Bool {
        pageCount > 1 && isClosingLauncher == false
    }

    /// Detects modifier keys that disable live reordering during a drag.
    private func isDragReorderSuppressed() -> Bool {
        let flags = NSApp?.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
        return flags.contains(.shift) || flags.contains(.option)
    }

    /// Returns the slice of apps that should be visible for the current page index.
    private var itemsForVisiblePage: [LauncherItem] {
        guard filteredItemList.isEmpty == false else { return [] }
        let startIndex = currentPage * pageCapacity
        guard startIndex < filteredItemList.count else { return [] }
        let endIndex = min(startIndex + pageCapacity, filteredItemList.count)
        return Array(filteredItemList[startIndex..<endIndex])
    }

    /// Convenience accessor for the currently dragged app, if any.
    private func currentDraggedApp() -> AppItem? {
        guard case let .app(app) = draggedItem else { return nil }
        return app
    }

    /// Moves the dragged app to a new linear position and persists the arrangement.
    @discardableResult
    private func reorderItem(_ item: LauncherItem, to targetIndex: Int, preferSwap: Bool = false) -> Int? {
        guard let originalIndex = orderedItems.firstIndex(of: item) else { return nil }
        var updated = orderedItems
        if preferSwap,
           targetIndex < updated.count,
           targetIndex >= 0,
           targetIndex != originalIndex {
            updated.swapAt(originalIndex, targetIndex)
            orderedItems = updated
            onItemOrderChange?(updated)
            return targetIndex
        } else {
            updated.remove(at: originalIndex)

            let boundedIndex = max(0, min(targetIndex, updated.count))
            if originalIndex == boundedIndex {
                return nil
            }

            updated.insert(item, at: boundedIndex)
            orderedItems = updated
            onItemOrderChange?(updated)
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
        orderedItems = removal.items
        activeFolder = folder
        currentPage = folderIndex / max(pageCapacity, 1)
        onItemOrderChange?(removal.items)
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
        orderedItems = updated
        activeFolder = folder
        onItemOrderChange?(updated)
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

        orderedItems = updated
        activeFolder = nil
        onItemOrderChange?(updated)
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
        activeFolder = folder
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
            delay = suppressReorder ? 0 : 0.6
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

    /// Combines the dragged app with the target item to form or append to a folder.
    private func mergeItemsIfNeeded(dragged: LauncherItem, onto target: LauncherItem) {
        guard case let .app(appToMove) = dragged else { return }
        guard dragged.id != target.id else { return }

        var updated = orderedItems
        guard let draggedIndex = updated.firstIndex(of: dragged) else { return }
        updated.remove(at: draggedIndex)
        guard let targetIndex = updated.firstIndex(of: target) else { return }

        var folder: FolderItem
        switch target {
        case .app(let targetApp):
            folder = FolderItem(name: FolderItem.defaultName, apps: [targetApp, appToMove])
        case .folder(let existingFolder):
            var mutableFolder = existingFolder
            mutableFolder.apps.append(appToMove)
            folder = mutableFolder
            if activeFolder?.id == existingFolder.id {
                activeFolder = mutableFolder
            }
        }

        updated.remove(at: targetIndex)
        updated.insert(.folder(folder), at: targetIndex)
        orderedItems = updated
        onItemOrderChange?(updated)
        updatePageAfterDrop(at: targetIndex)
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
        if filteredItemList.isEmpty {
            return orderedItems.isEmpty ? "No items found" : "No matching items"
        }
        return "Page \(currentPage + 1) of \(pageCount)"
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

    /// Renders the folder title and allows inline editing when tapped.
    @ViewBuilder
    private func folderTitleView(for folder: FolderItem) -> some View {
        if isEditingFolderName {
            TextField("", text: $folderNameDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 22, weight: .semibold))
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
                .padding(.top, 8)
                .onTapGesture {
                    beginFolderNameEdit(for: folder)
                }
        }
    }

    /// Lays out the folder contents with a Launchpad-inspired grid that supports reordering.
    @ViewBuilder
    private func folderGrid(for folder: FolderItem, layout: LauncherLayoutMetrics) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 22, alignment: .center), count: max(3, min(4, LauncherGridConfiguration.columnsPerPage - 2)))
        let spacing: CGFloat = 22
        let tileSize = layout.iconDimension

        GeometryReader { gridProxy in
            LazyVGrid(columns: columns, alignment: .center, spacing: spacing) {
                ForEach(folder.apps, id: \.id) { app in
                    let cell = Button {
                        openItem(.app(app))
                    } label: {
                        VStack(spacing: 10) {
                            iconView(for: .app(app), layout: layout)
                                .frame(width: tileSize, height: tileSize)
                            Text(app.resolvedDisplayName)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        itemContextMenu(for: .app(app))
                    }

                    cell
                        .onDrag {
                            folderDragContext = FolderDragContext(folderID: folder.id, app: app)
                            draggedFolderApp = app
                            draggedItem = .app(app)
                            return NSItemProvider(object: NSString(string: app.bundleIdentifier))
                        }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 6)
            .padding(.bottom, 4)
            .onDrop(
                of: [.text],
                delegate: FolderReorderDropDelegate(
                    columns: columns.count,
                    spacing: spacing,
                    gridSize: gridProxy.size,
                    appCount: folder.apps.count,
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
        .frame(maxWidth: .infinity)
    }

    /// Displays a blurred overlay showing a folder's contents with Launchpad-inspired styling.
    @ViewBuilder
    private func folderOverlay(for folder: FolderItem, layout: LauncherLayoutMetrics) -> some View {
        GeometryReader { proxy in
            ZStack {
                VisualEffectBackground(material: .hudWindow, blendingMode: .behindWindow)
                    .ignoresSafeArea()
                Color.black.opacity(0.35)
                    .ignoresSafeArea()

                VStack(spacing: 20) {
                    folderTitleView(for: folder)

                    folderGrid(for: folder, layout: layout)
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 26)
                .frame(maxWidth: min(proxy.size.width * 0.82, 640))
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
                withAnimation(.easeInOut(duration: 0.15)) {
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
            .transition(.opacity)
        }
    }

    /// Simple empty state shown when the grid has nothing to display.
    private func emptyState() -> some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 32, weight: .light))
                .foregroundColor(.secondary)
            Text(orderedItems.isEmpty ? "No items found" : "No matching items")
                .font(.title3)
            if orderedItems.isEmpty == false && searchText.isEmpty == false {
                Text("Try a different search term.")
                    .foregroundStyle(.secondary)
            } else if orderedItems.isEmpty {
                Text("Launchy has not indexed any applications yet.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Asks `NSWorkspace` to launch the tapped application and queues the close animation.
    private func openItem(_ item: LauncherItem) {
        guard isClosingLauncher == false else { return }

        switch item {
        case .folder(let folder):
            activeFolder = folder
            return
        case .app(let app):
            activeFolder = nil
            guard let bundleURL = app.bundleURL else { return }

            isClosingLauncher = true

            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration, completionHandler: nil)

            animateAndDismissLauncher()
        }
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
        TextField("Search items", text: $searchText)
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
                promptRenameApp(app)
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
                promptRenameFolder(folder)
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
            "Bundle ID: \(app.bundleIdentifier)"
        ]
        if let url = app.bundleURL {
            lines.append("Location: \(url.path)")
        }
        if let custom = sanitizedCustomName(app.customName ?? ""), custom.isEmpty == false {
            lines.append("Custom Name: \(custom)")
        }

        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Displays folder information and contained apps.
    private func showFolderDetails(_ folder: FolderItem) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = folder.name.isEmpty ? FolderItem.defaultName : folder.name
        let appList = folder.apps.map { "- \($0.resolvedDisplayName)" }.joined(separator: "\n")
        alert.informativeText = appList.isEmpty ? "Folder is empty." : "Apps:\n\(appList)"
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Prompts the user for a new app name and saves it.
    private func promptRenameApp(_ app: AppItem) {
        let initial = sanitizedCustomName(app.customName ?? app.displayName)
        requestNameInput(
            title: "Rename App",
            message: "Enter a custom name for this app. Leave empty to reset.",
            initialValue: initial ?? ""
        ) { newName in
            guard let newName else { return }
            applyAppRename(app, newName: newName)
        }
    }

    /// Prompts the user for a new folder name and saves it.
    private func promptRenameFolder(_ folder: FolderItem) {
        requestNameInput(
            title: "Rename Folder",
            message: "Enter a name for this folder.",
            initialValue: folder.name
        ) { newName in
            guard let newName else { return }
            applyFolderRename(folder, newName: newName)
        }
    }

    /// Starts inline editing for the folder title displayed in the overlay.
    private func beginFolderNameEdit(for folder: FolderItem) {
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
        onItemOrderChange?(items)
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
            orderedItems = removal.items
            onItemOrderChange?(removal.items)
            currentPage = min(currentPage, fullPageCount - 1)
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
        orderedItems = updated
        currentPage = folderIndex / pageCapacity
        if activeFolder?.id == folder.id {
            activeFolder = folder
        }
        onItemOrderChange?(updated)
    }

    /// Moves an item (or app extracted from a folder) to a target page.
    private func moveItem(_ item: LauncherItem, toPage targetPage: Int) {
        var items = orderedItems
        let itemToInsert: LauncherItem

        switch item {
        case .app(let app):
            guard let removal = removeAppFromHierarchy(app) else { return }
            items = removal.items
            itemToInsert = .app(removal.app)
        case .folder(let folder):
            guard let index = items.firstIndex(where: { entry in
                if case let .folder(existing) = entry {
                    return existing.id == folder.id
                }
                return false
            }) else { return }
            itemToInsert = items.remove(at: index)
        }

        let updatedPageCount = max((items.count + pageCapacity - 1) / max(pageCapacity, 1), 1)
        let boundedPage = max(0, min(targetPage, updatedPageCount - 1))

        insert(itemToInsert, into: &items, atPage: boundedPage)
        orderedItems = items
        currentPage = boundedPage
        onItemOrderChange?(items)
    }

    /// Inserts a launcher item at the end of the requested page slice.
    private func insert(_ item: LauncherItem, into items: inout [LauncherItem], atPage page: Int) {
        guard pageCapacity > 0 else {
            items.append(item)
            return
        }

        let startIndex = max(page, 0) * pageCapacity
        let safeStart = min(startIndex, items.count)
        let endIndex = min(safeStart + pageCapacity, items.count)
        let insertionIndex = min(endIndex, items.count)
        items.insert(item, at: insertionIndex)
    }

    /// Builds the page index for the selected item irrespective of search filters.
    private func pageIndex(for item: LauncherItem) -> Int? {
        switch item {
        case .app(let app):
            guard let location = locateApp(app) else { return nil }
            switch location {
            case .root(let index):
                return index / pageCapacity
            case .folder(let folderIndex, _):
                return folderIndex / pageCapacity
            }
        case .folder(let folder):
            guard let index = orderedItems.firstIndex(where: { entry in
                if case let .folder(existing) = entry {
                    return existing.id == folder.id
                }
                return false
            }) else { return nil }
            return index / pageCapacity
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
        var items = orderedItems

        switch location {
        case .root(let index):
            guard case let .app(existing) = items.remove(at: index) else { return nil }
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
            } else if activeFolder?.id == folder.id {
                activeFolder = nil
            }

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
        onItemOrderChange?(items)

        guard promptForName else { return }
        promptRenameFolder(newFolder)
    }

    /// Creates an empty folder at the start of the current page.
    private func createEmptyFolder(onPage pageIndex: Int, promptForName: Bool) {
        var items = orderedItems
        let folder = FolderItem(apps: [])
        insert(.folder(folder), into: &items, atPage: pageIndex)
        orderedItems = items
        onItemOrderChange?(items)

        guard promptForName else { return }
        promptRenameFolder(folder)
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

    /// Simple helper for text entry alerts.
    private func requestNameInput(
        title: String,
        message: String,
        initialValue: String,
        onCompletion: (String?) -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message

        let field = NSTextField(string: initialValue)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field

        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else {
            onCompletion(nil)
            return
        }
        onCompletion(field.stringValue)
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
        backgroundStylePreference: .automatic
    )
}

private struct FolderFramePreference: PreferenceKey {
    static let defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}
