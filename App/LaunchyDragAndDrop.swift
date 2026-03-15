import SwiftUI

enum DragModifierMode {
    case normal
    case swap
    case folderMerge

    var suppressesLiveReorder: Bool {
        self != .normal
    }
}

/// Enables dropping items onto the grid background or pager buttons to move across pages.
struct PageReorderDropDelegate: DropDelegate {
    let targetPage: Int
    let pageCapacity: Int
    @Binding var items: [LauncherItem]
    @Binding var draggedItem: LauncherItem?
    var performReorder: (LauncherItem, Int) -> Int?
    var afterReorder: (Int?) -> Void

    private static var lastPageSwitchDate: Date = .distantPast
    /// Soft debounce to avoid rapid-fire page hopping while dragging.
    private static let minSwitchInterval: TimeInterval = 1.0

    /// Intentionally ignores hover entry; paging only happens on final drop.
    func dropEntered(info: DropInfo) {
        // Intentionally no-op to avoid premature page jumps while hovering.
    }

    /// Advertises move semantics while dragging over page targets.
    func dropUpdated(info: DropInfo) -> DropProposal? {
        return DropProposal(operation: .move)
    }

    /// Commits a page-level reorder and clears drag state.
    func performDrop(info: DropInfo) -> Bool {
        handleDropUpdate(info, isFinal: true)
        draggedItem = nil
        return true
    }

    /// Moves the dragged item to the target page insertion slot with a debounce gate.
    private func handleDropUpdate(_ info: DropInfo, isFinal: Bool) {
        guard isFinal, let draggedItem else { return }
        guard pageCapacity > 0 else { return }

        let now = Date()
        guard now.timeIntervalSince(Self.lastPageSwitchDate) >= Self.minSwitchInterval else { return }

        let destinationIndex = LauncherGridConfiguration.insertionIndex(
            for: targetPage,
            itemsCount: items.count,
            pageCapacity: pageCapacity
        )

        let finalIndex = performReorder(draggedItem, destinationIndex)
        if finalIndex != nil {
            Self.lastPageSwitchDate = now
        }
        afterReorder(finalIndex)
    }
}

/// Reorders items as the cursor moves across the grid, so neighbors slide aside in real time.
struct GridReorderDropDelegate: DropDelegate {
    let layout: LauncherLayoutMetrics
    let gridSize: CGSize
    let pageStartIndex: Int
    let pageItemCount: Int
    @Binding var items: [LauncherItem]
    @Binding var draggedItem: LauncherItem?
    var dragModifierMode: () -> DragModifierMode
    var performReorder: (LauncherItem, Int, Bool) -> Int?
    var afterReorder: (Int?) -> Void
    var performFolderDrop: ([LauncherItem], LauncherItem) -> Void
    var isMultiSelectionDragActive: () -> Bool
    var multiSelectionItems: () -> [LauncherItem]
    var onFolderHoverExit: () -> Void
    var onFolderSnapPreviewChange: (UUID?) -> Void
    var lastLiveReorderTargetIndex: Binding<Int?>
    var dragReferenceItems: () -> [LauncherItem]
    var consumePendingModifierPreviewReset: () -> Bool
    var restoreDraggedLayoutSnapshot: () -> Void
    var performLiveSwapPreview: (LauncherItem, Int) -> Int?
    var performLiveReorder: (LauncherItem, Int, Bool) -> Int?
    var onModifierStateChange: ((DragModifierMode) -> Void)?

    /// Captures modifier state early so folder-merge previews appear immediately.
    func dropEntered(info: DropInfo) {
        let modifierMode = dragModifierMode()
        onModifierStateChange?(modifierMode)
        handleHover(info)
    }

    /// Continuously updates hover affordances and optional live reordering.
    func dropUpdated(info: DropInfo) -> DropProposal? {
        let modifierMode = dragModifierMode()
        onModifierStateChange?(modifierMode)
        handleHover(info)
        applyLiveReorder(info)
        return DropProposal(operation: .move)
    }

    /// Clears transient hover/reorder state when leaving the grid.
    func dropExited(info: DropInfo) {
        onModifierStateChange?(.normal)
        onFolderSnapPreviewChange(nil)
        onFolderHoverExit()
        lastLiveReorderTargetIndex.wrappedValue = nil
    }

    /// Finalizes either reorder or folder-merge behavior based on modifiers/target.
    func performDrop(info: DropInfo) -> Bool {
        defer {
            draggedItem = nil
            onFolderSnapPreviewChange(nil)
            lastLiveReorderTargetIndex.wrappedValue = nil
            onModifierStateChange?(.normal)
        }
        guard let draggedItem else { return false }

        let targetIndex = targetIndex(for: info.location)
        let modifierMode = dragModifierMode()
        let targetItemIndex = itemIndex(for: info.location)
        let targetItem = targetItemIndex.flatMap { index in
            items.indices.contains(index) ? items[index] : nil
        }
        let referenceItems = dragReferenceItems()
        let swapTargetItem = targetItemIndex.flatMap { index in
            referenceItems.indices.contains(index) ? referenceItems[index] : nil
        }

        if isMultiSelectionDragActive() {
            guard let folderTarget = targetItem,
                  case .folder = folderTarget else {
                return false
            }
            let selection = multiSelectionItems().filter { $0.id != folderTarget.id }
            guard selection.isEmpty == false else { return false }
            onFolderHoverExit()
            performFolderDrop(selection, folderTarget)
            return true
        }

        if modifierMode == .folderMerge, let targetItem {
            let shouldMerge: Bool
            switch (draggedItem, targetItem) {
            case (.app, _):
                shouldMerge = true
            case (.folder, .folder):
                shouldMerge = true
            default:
                shouldMerge = false
            }

            if shouldMerge {
                // With Option held, treat a drop onto another item as a folder create/append instead of a reorder.
                onFolderHoverExit()
                performFolderDrop([draggedItem], targetItem)
                return true
            }
        }

        let finalIndex: Int?
        if modifierMode == .swap {
            guard let targetItemIndex,
                  items.indices.contains(targetItemIndex),
                  let currentDraggedIndex = items.firstIndex(of: draggedItem) else {
                afterReorder(nil)
                return true
            }

            if currentDraggedIndex == targetItemIndex {
                afterReorder(targetItemIndex)
                return true
            }

            guard let targetItem = swapTargetItem,
                  targetItem.id != draggedItem.id else {
                afterReorder(nil)
                return true
            }

            finalIndex = performReorder(draggedItem, targetItemIndex, true)
        } else {
            finalIndex = performReorder(draggedItem, targetIndex, false)
        }
        afterReorder(finalIndex)

        return true
    }

    /// Updates folder-hover and modifier-driven preview state while dragging.
    private func handleHover(_ info: DropInfo) {
        updateFolderSnapPreview(for: info)
        // Keep grid stable while hovering; no live reordering or folder auto-creation.
        onFolderHoverExit()
    }

    /// Performs non-destructive live reordering while hovering over occupied cells.
    private func applyLiveReorder(_ info: DropInfo) {
        guard let draggedItem else { return }
        let modifierMode = dragModifierMode()

        if modifierMode == .folderMerge {
            restoreDraggedLayoutSnapshot()
            lastLiveReorderTargetIndex.wrappedValue = nil
            return
        }

        if modifierMode == .swap {
            if consumePendingModifierPreviewReset() {
                restoreDraggedLayoutSnapshot()
                lastLiveReorderTargetIndex.wrappedValue = nil
                return
            }
            guard let targetItemIndex = itemIndex(for: info.location),
                  let targetItem = swapTargetItem(at: targetItemIndex, draggedItem: draggedItem),
                  targetItem.id != draggedItem.id else {
                restoreDraggedLayoutSnapshot()
                lastLiveReorderTargetIndex.wrappedValue = nil
                return
            }
            guard lastLiveReorderTargetIndex.wrappedValue != targetItemIndex else { return }
            lastLiveReorderTargetIndex.wrappedValue = targetItemIndex
            _ = performLiveSwapPreview(draggedItem, targetItemIndex)
            return
        }

        if isLocationInEmptySlot(info.location) {
            lastLiveReorderTargetIndex.wrappedValue = nil
            return
        }
        let targetIndex = targetIndex(for: info.location)
        guard lastLiveReorderTargetIndex.wrappedValue != targetIndex else { return }
        lastLiveReorderTargetIndex.wrappedValue = targetIndex
        _ = performLiveReorder(draggedItem, targetIndex, false)
    }

    /// Resolves the hovered swap target from the original drag snapshot rather than the animated live layout.
    private func swapTargetItem(at index: Int, draggedItem: LauncherItem) -> LauncherItem? {
        let referenceItems = dragReferenceItems()
        guard referenceItems.indices.contains(index) else { return nil }
        let targetItem = referenceItems[index]
        return targetItem.id == draggedItem.id ? nil : targetItem
    }

    /// Shows a folder snap hint when modifier keys indicate we should merge instead of reorder.
    private func updateFolderSnapPreview(for info: DropInfo) {
        guard draggedItem != nil else {
            onFolderSnapPreviewChange(nil)
            return
        }

        guard dragModifierMode() == .folderMerge else {
            onFolderSnapPreviewChange(nil)
            return
        }

        guard let targetIndex = itemIndex(for: info.location),
              items.indices.contains(targetIndex),
              case .folder = items[targetIndex] else {
            onFolderSnapPreviewChange(nil)
            return
        }

        onFolderSnapPreviewChange(items[targetIndex].id)
    }

    /// Maps a drop location to a linear index within the current page.
    private func linearIndex(for location: CGPoint) -> Int {
        let location = adjustedLocation(location)
        let columns = layout.columnsPerPage
        let rows = layout.rowsPerPage

        let totalSpacingX = layout.iconSpacing * CGFloat(columns - 1)
        let totalSpacingY = layout.iconSpacing * CGFloat(rows - 1)

        let cellWidth = max((gridSize.width - totalSpacingX) / CGFloat(columns), 1)
        let cellHeight = max((gridSize.height - totalSpacingY) / CGFloat(rows), 1)

        let clampedX = min(max(location.x, 0), gridSize.width - 0.001)
        let clampedY = min(max(location.y, 0), gridSize.height - 0.001)

        let column = min(
            max(Int((clampedX / (cellWidth + layout.iconSpacing)).rounded(.down)), 0),
            columns - 1
        )
        let row = min(
            max(Int((clampedY / (cellHeight + layout.iconSpacing)).rounded(.down)), 0),
            rows - 1
        )

        return linearIndexInPage(row: row, column: column)
    }

    private var effectivePageItemCount: Int {
        let baseCount = max(min(pageItemCount, boundedPageItemCount), 0)
        guard let draggedItem else { return baseCount }
        guard let draggedIndex = items.firstIndex(of: draggedItem) else { return baseCount }
        if draggedIndex >= pageStartIndex && draggedIndex < pageStartIndex + baseCount {
            return max(baseCount - 1, 0)
        }
        return baseCount
    }

    /// Resolves a pointer location into the absolute insertion index for the current page.
    private func targetIndex(for location: CGPoint) -> Int {
        let linearIndex = linearIndex(for: location)
        let pageEndIndex = pageStartIndex + effectivePageItemCount
        if linearIndex >= effectivePageItemCount {
            return min(pageEndIndex, items.count)
        }
        return min(pageStartIndex + linearIndex, items.count)
    }

    /// Returns whether the pointer is over an empty grid slot beyond current item count.
    private func isLocationInEmptySlot(_ location: CGPoint) -> Bool {
        linearIndex(for: location) >= effectivePageItemCount
    }

    /// Returns the item index for the cell under the cursor within the current page.
    private func itemIndex(for location: CGPoint) -> Int? {
        let cellIndex = indexInCurrentPage(for: location)
        guard let cellIndex else { return nil }
        let linearIndex = pageStartIndex + cellIndex
        return linearIndex <= lastIndexInPage ? linearIndex : nil
    }

    /// Computes the visible cell index under the pointer for the active page.
    private func indexInCurrentPage(for location: CGPoint) -> Int? {
        let location = adjustedLocation(location)
        let columns = layout.columnsPerPage
        let rows = layout.rowsPerPage

        let totalSpacingX = layout.iconSpacing * CGFloat(columns - 1)
        let totalSpacingY = layout.iconSpacing * CGFloat(rows - 1)

        let cellWidth = max((gridSize.width - totalSpacingX) / CGFloat(columns), 1)
        let cellHeight = max((gridSize.height - totalSpacingY) / CGFloat(rows), 1)

        let clampedX = min(max(location.x, 0), gridSize.width - 0.001)
        let clampedY = min(max(location.y, 0), gridSize.height - 0.001)

        let column = min(
            max(Int((clampedX / (cellWidth + layout.iconSpacing)).rounded(.down)), 0),
            columns - 1
        )
        let row = min(
            max(Int((clampedY / (cellHeight + layout.iconSpacing)).rounded(.down)), 0),
            rows - 1
        )

        let linearIndex = row * columns + column
        return linearIndex < visibleItemCount ? linearIndex : nil
    }

    /// Align drop coordinates with the visually shifted grid.
    private func adjustedLocation(_ location: CGPoint) -> CGPoint {
        location
    }

    private var visibleItemCount: Int {
        boundedPageItemCount
    }

    private var boundedPageItemCount: Int {
        let available = max(items.count - pageStartIndex, 0)
        return max(min(pageItemCount, available), 0)
    }

    /// Converts 2D grid coordinates into a page-local linear index.
    private func linearIndexInPage(row: Int, column: Int) -> Int {
        row * layout.columnsPerPage + column
    }

    /// Converts an absolute item index into a page-local index when visible.
    private func indexInCurrentPage(forAbsoluteIndex index: Int) -> Int? {
        let local = index - pageStartIndex
        guard local >= 0, local < boundedPageItemCount else { return nil }
        return local
    }

    private var lastIndexInPage: Int {
        guard boundedPageItemCount > 0 else { return pageStartIndex }
        return pageStartIndex + boundedPageItemCount - 1
    }
}

/// Reorders apps inside an open folder overlay.
struct FolderReorderDropDelegate: DropDelegate {
    let columns: Int
    let spacing: CGFloat
    let gridSize: CGSize
    let pageStartIndex: Int
    let pageItemCount: Int
    @Binding var draggedApp: AppItem?
    var resolveDraggedApp: () -> AppItem?
    var isAppInFolder: (AppItem) -> Bool
    var performReorder: (AppItem, Int) -> Void
    var performLiveReorder: (AppItem, Int) -> Void
    var insertApp: (AppItem, Int) -> Void
    var onDropEnded: (() -> Void)?
    var lastLiveReorderTargetIndex: Binding<Int?>

    /// Updates live reorder preview immediately when entering folder grid.
    func dropEntered(info: DropInfo) {
        handleDropUpdate(info)
    }

    /// Recomputes folder insertion/reorder target while hovering.
    func dropUpdated(info: DropInfo) -> DropProposal? {
        handleDropUpdate(info)
        return DropProposal(operation: .move)
    }

    /// Clears folder live-reorder target when pointer leaves the drop zone.
    func dropExited(info: DropInfo) {
        lastLiveReorderTargetIndex.wrappedValue = nil
    }

    /// Commits in-folder reorder or inserts external apps into the folder.
    func performDrop(info: DropInfo) -> Bool {
        defer { lastLiveReorderTargetIndex.wrappedValue = nil }
        let app = draggedApp ?? resolveDraggedApp()
        let target = targetIndex(for: info.location)

        if let app {
            if isAppInFolder(app) {
                performReorder(app, target)
            } else {
                insertApp(app, target)
            }
        }

        draggedApp = nil
        onDropEnded?()
        return true
    }

    /// Applies non-committal live reorder updates for folder dragging.
    private func handleDropUpdate(_ info: DropInfo) {
        let target = targetIndex(for: info.location)
        guard lastLiveReorderTargetIndex.wrappedValue != target else { return }
        lastLiveReorderTargetIndex.wrappedValue = target
        guard let draggedApp = draggedApp ?? resolveDraggedApp() else { return }
        guard isAppInFolder(draggedApp) else { return }
        performLiveReorder(draggedApp, target)
    }

    /// Maps folder-grid pointer position to an absolute insertion index.
    private func targetIndex(for location: CGPoint) -> Int {
        let rows = max(1, Int(ceil(Double(max(pageItemCount, 1)) / Double(columns))))

        let totalSpacingX = spacing * CGFloat(columns - 1)
        let totalSpacingY = spacing * CGFloat(rows - 1)

        let cellWidth = max((gridSize.width - totalSpacingX) / CGFloat(columns), 1)
        let cellHeight = max((gridSize.height - totalSpacingY) / CGFloat(max(rows, 1)), 1)

        let clampedX = min(max(location.x, 0), gridSize.width - 0.001)
        let clampedY = min(max(location.y, 0), gridSize.height - 0.001)

        let column = min(max(Int((clampedX / (cellWidth + spacing)).rounded(.down)), 0), columns - 1)
        let row = max(Int((clampedY / (cellHeight + spacing)).rounded(.down)), 0)

        let linearIndex = row * columns + column
        let bounded = min(max(linearIndex, 0), max(pageItemCount, 0))
        return pageStartIndex + bounded
    }
}

/// Detects when a drag leaves the folder card so the app can be moved back to the root grid.
struct FolderExitDropDelegate: DropDelegate {
    @Binding var activeFrame: CGRect
    var containerSize: CGSize
    var edgeThreshold: CGFloat
    var onExitDrag: () -> Void

    /// No-op entry point for edge-exit detection delegate.
    func dropEntered(info: DropInfo) {
    }

    /// Keeps move semantics while monitoring edge proximity.
    func dropUpdated(info: DropInfo) -> DropProposal? {
        return DropProposal(operation: .move)
    }

    /// Triggers folder-exit behavior when a drop finishes near container edges.
    func performDrop(info: DropInfo) -> Bool {
        attemptExit(at: info.location)
        return true
    }

    /// Emits exit callback only when pointer is both outside the folder and near container boundaries.
    private func attemptExit(at location: CGPoint) {
        guard activeFrame.isEmpty == false else { return }
        guard activeFrame.contains(location) == false else { return }
        guard isNearEdge(location) else { return }
        onExitDrag()
    }

    /// Tests whether a location is inside the configured edge threshold.
    private func isNearEdge(_ location: CGPoint) -> Bool {
        let threshold = max(edgeThreshold, 0)
        return location.x <= threshold
            || location.y <= threshold
            || location.x >= containerSize.width - threshold
            || location.y >= containerSize.height - threshold
    }
}
