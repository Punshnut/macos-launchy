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
    var performFolderDrop: (LauncherItem, LauncherItem) -> Void
    var onFolderHoverExit: () -> Void

    func dropEntered(info: DropInfo) {
        handleHover(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        handleHover(info)
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer { draggedItem = nil }
        guard let draggedItem else { return false }

        let targetIndex = targetIndex(for: info.location)
        let modifiersActive = shouldSuppressReorder()
        let targetItemIndex = itemIndex(for: info.location)
        let targetItem = targetItemIndex.flatMap { index in
            items.indices.contains(index) ? items[index] : nil
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
                performFolderDrop(draggedItem, targetItem)
                return true
            }
        }

        let finalIndex = performReorder(draggedItem, targetIndex, false)
        afterReorder(finalIndex)

        return true
    }

    private func handleHover(_ info: DropInfo) {
        // Keep grid stable while hovering; no live reordering or folder auto-creation.
        onFolderHoverExit()
    }

    /// Converts a cursor point into a linear index within the overall arranged apps.
    private func targetIndex(for location: CGPoint) -> Int {
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

        return clampedIndexWithinPage(pageStartIndex + linearIndexInPage(row: row, column: column))
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

    private func clampedIndexWithinPage(_ rawIndex: Int) -> Int {
        let start = max(pageStartIndex, 0)
        let end = max(lastIndexInPage, start)
        return min(max(rawIndex, start), end)
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
    let appCount: Int
    @Binding var draggedApp: AppItem?
    var resolveDraggedApp: () -> AppItem?
    var isAppInFolder: (AppItem) -> Bool
    var performReorder: (AppItem, Int) -> Void
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
        performReorder(draggedApp, target)
    }

    private func targetIndex(for location: CGPoint) -> Int {
        let rows = max(1, Int(ceil(Double(appCount) / Double(columns))))

        let totalSpacingX = spacing * CGFloat(columns - 1)
        let totalSpacingY = spacing * CGFloat(rows - 1)

        let cellWidth = max((gridSize.width - totalSpacingX) / CGFloat(columns), 1)
        let cellHeight = max((gridSize.height - totalSpacingY) / CGFloat(max(rows, 1)), 1)

        let clampedX = min(max(location.x, 0), gridSize.width - 0.001)
        let clampedY = min(max(location.y, 0), gridSize.height - 0.001)

        let column = min(max(Int((clampedX / (cellWidth + spacing)).rounded(.down)), 0), columns - 1)
        let row = max(Int((clampedY / (cellHeight + spacing)).rounded(.down)), 0)

        let linearIndex = row * columns + column
        return max(linearIndex, 0)
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
