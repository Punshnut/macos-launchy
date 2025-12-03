import SwiftUI

/// Enables dropping items onto the grid background or pager buttons to move across pages.
struct PageReorderDropDelegate: DropDelegate {
    let targetPage: Int
    let pageCapacity: Int
    @Binding var items: [LauncherItem]
    @Binding var draggedItem: LauncherItem?
    var performReorder: (LauncherItem, Int) -> Int?
    var afterReorder: (Int?) -> Void

    private static var lastPageSwitchDate: Date = .distantPast
    private static let minSwitchInterval: TimeInterval = 1.0

    func dropEntered(info: DropInfo) {
        // Intentionally no-op to avoid premature page jumps while hovering.
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        handleDropUpdate(info, isFinal: true)
        draggedItem = nil
        return true
    }

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
    var shouldSuppressReorder: () -> Bool
    var performReorder: (LauncherItem, Int, Bool) -> Int?
    var afterReorder: (Int?) -> Void
    var performFolderDrop: ([LauncherItem], LauncherItem) -> Void
    var isMultiSelectionDragActive: () -> Bool
    var multiSelectionItems: () -> [LauncherItem]
    var onFolderHoverExit: () -> Void
    var onFolderSnapPreviewChange: (UUID?) -> Void
    var lastLiveReorderTargetIndex: Binding<Int?>
    var performLiveReorder: (LauncherItem, Int) -> Int?
    var onModifierStateChange: ((Bool) -> Void)?

    func dropEntered(info: DropInfo) {
        let modifiersActive = shouldSuppressReorder()
        onModifierStateChange?(modifiersActive)
        handleHover(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let modifiersActive = shouldSuppressReorder()
        onModifierStateChange?(modifiersActive)
        handleHover(info)
        applyLiveReorder(info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        onModifierStateChange?(false)
        onFolderSnapPreviewChange(nil)
        onFolderHoverExit()
        lastLiveReorderTargetIndex.wrappedValue = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            draggedItem = nil
            onFolderSnapPreviewChange(nil)
            lastLiveReorderTargetIndex.wrappedValue = nil
            onModifierStateChange?(false)
        }
        guard let draggedItem else { return false }

        let targetIndex = targetIndex(for: info.location)
        let modifiersActive = shouldSuppressReorder()
        let targetItemIndex = itemIndex(for: info.location)
        let targetItem = targetItemIndex.flatMap { index in
            items.indices.contains(index) ? items[index] : nil
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

        if modifiersActive, let targetItem {
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
                // With Option/Shift held, treat a drop onto another item as a folder create/append instead of a reorder.
                onFolderHoverExit()
                performFolderDrop([draggedItem], targetItem)
                return true
            }
        }

        let finalIndex = performReorder(draggedItem, targetIndex, false)
        afterReorder(finalIndex)

        return true
    }

    private func handleHover(_ info: DropInfo) {
        updateFolderSnapPreview(for: info)
        // Keep grid stable while hovering; no live reordering or folder auto-creation.
        onFolderHoverExit()
    }

    private func applyLiveReorder(_ info: DropInfo) {
        guard let draggedItem else { return }
        guard shouldSuppressReorder() == false else {
            lastLiveReorderTargetIndex.wrappedValue = nil
            return
        }
        if isLocationInEmptySlot(info.location) {
            lastLiveReorderTargetIndex.wrappedValue = nil
            return
        }
        let targetIndex = targetIndex(for: info.location)
        guard lastLiveReorderTargetIndex.wrappedValue != targetIndex else { return }
        lastLiveReorderTargetIndex.wrappedValue = targetIndex
        _ = performLiveReorder(draggedItem, targetIndex)
    }

    private func updateFolderSnapPreview(for info: DropInfo) {
        guard draggedItem != nil else {
            onFolderSnapPreviewChange(nil)
            return
        }

        guard shouldSuppressReorder() else {
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

    private func linearIndex(for location: CGPoint) -> Int {
        let location = adjustedLocation(location)
        let columns = LauncherGridConfiguration.columnsPerPage
        let rows = LauncherGridConfiguration.rowsPerPage

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

    private func targetIndex(for location: CGPoint) -> Int {
        let linearIndex = linearIndex(for: location)
        let pageEndIndex = pageStartIndex + effectivePageItemCount
        if linearIndex >= effectivePageItemCount {
            return min(pageEndIndex, items.count)
        }
        return min(pageStartIndex + linearIndex, items.count)
    }

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

    private func indexInCurrentPage(for location: CGPoint) -> Int? {
        let location = adjustedLocation(location)
        let columns = LauncherGridConfiguration.columnsPerPage
        let rows = LauncherGridConfiguration.rowsPerPage

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

    private func linearIndexInPage(row: Int, column: Int) -> Int {
        row * LauncherGridConfiguration.columnsPerPage + column
    }

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

    func dropEntered(info: DropInfo) {
        handleDropUpdate(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        handleDropUpdate(info)
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
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

    private func handleDropUpdate(_ info: DropInfo) {
        guard let draggedApp = draggedApp ?? resolveDraggedApp() else { return }
        guard isAppInFolder(draggedApp) else { return }
        let target = targetIndex(for: info.location)
        performLiveReorder(draggedApp, target)
    }

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
    var onExitDrag: () -> Void

    func dropEntered(info: DropInfo) {
        attemptExit(at: info.location)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        attemptExit(at: info.location)
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        return true
    }

    private func attemptExit(at location: CGPoint) {
        guard activeFrame.isEmpty == false else { return }
        guard activeFrame.contains(location) == false else { return }
        onExitDrag()
    }
}
