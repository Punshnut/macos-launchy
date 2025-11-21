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
        handleDropUpdate(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        handleDropUpdate(info)
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedItem = nil
        return true
    }

    private func handleDropUpdate(_ info: DropInfo) {
        guard let draggedItem else { return }
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
    let currentPage: Int
    let pageCapacity: Int
    @Binding var items: [LauncherItem]
    @Binding var draggedItem: LauncherItem?
    var shouldSuppressReorder: () -> Bool
    var performReorder: (LauncherItem, Int, Bool) -> Int?
    var afterReorder: (Int?) -> Void
    var onDropOnItem: (LauncherItem, LauncherItem) -> Void
    var onFolderHoverExit: () -> Void

    func dropEntered(info: DropInfo) {
        handleDropUpdate(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        handleDropUpdate(info)
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer { draggedItem = nil }
        guard let draggedItem else { return false }

        let targetIndex = targetIndex(for: info.location)
        let suppressReorder = shouldSuppressReorder()

        if targetIndex < items.count,
           shouldAttemptFolderDrop(for: info.location, targetIndex: targetIndex) {
            onDropOnItem(draggedItem, items[targetIndex])
            if suppressReorder {
                let finalIndex = performReorder(draggedItem, targetIndex, false)
                afterReorder(finalIndex)
            }
        } else if suppressReorder {
            let finalIndex = performReorder(draggedItem, targetIndex, false)
            afterReorder(finalIndex)
        }

        return true
    }

    private func handleDropUpdate(_ info: DropInfo) {
        guard let draggedItem else { return }
        guard pageCapacity > 0 else { return }

        let targetIndex = targetIndex(for: info.location)
        let suppressReorder = shouldSuppressReorder()
        if suppressReorder == false {
            let preferSwap = shouldSwapToward(targetIndex: targetIndex, dragged: draggedItem)
            let finalIndex = performReorder(draggedItem, targetIndex, preferSwap)
            afterReorder(finalIndex)
        }

        if shouldAttemptFolder(for: info.location, targetIndex: targetIndex) {
            onDropOnItem(draggedItem, items[min(targetIndex, items.count - 1)])
        } else {
            onFolderHoverExit()
        }
    }

    /// Converts a cursor point into a linear index within the overall arranged apps.
    private func targetIndex(for location: CGPoint) -> Int {
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

        let linearIndex = currentPage * pageCapacity + row * columns + column
        return min(max(linearIndex, 0), items.count)
    }

    private func shouldSwapToward(targetIndex: Int, dragged: LauncherItem) -> Bool {
        guard let originalIndex = items.firstIndex(of: dragged) else { return false }
        guard targetIndex < items.count else { return false }

        let columns = LauncherGridConfiguration.columnsPerPage
        let originalRow = originalIndex / columns
        let targetRow = targetIndex / columns
        return originalRow == targetRow && abs(originalIndex - targetIndex) == 1
    }

    private func shouldAttemptFolder(for location: CGPoint, targetIndex: Int) -> Bool {
        guard targetIndex < items.count else { return false }
        guard let frame = cellFrame(at: targetIndex) else { return false }

        let center = CGPoint(x: frame.midX, y: frame.midY)
        let dx = abs(location.x - center.x)
        let dy = abs(location.y - center.y)
        let horizontalTolerance = frame.width * 0.38

        let verticalApproach = dy > (frame.height * 0.25) && dx <= horizontalTolerance
        let centeredHover = dx <= frame.width * 0.3 && dy <= frame.height * 0.3

        return verticalApproach || centeredHover
    }

    /// Returns the item index for the cell under the cursor within the current page.
    private func itemIndex(for location: CGPoint) -> Int? {
        let cellIndex = indexInCurrentPage(for: location)
        guard let cellIndex else { return nil }
        let linearIndex = currentPage * pageCapacity + cellIndex
        let maxVisibleIndex = min((currentPage + 1) * pageCapacity, items.count)
        return linearIndex < maxVisibleIndex ? linearIndex : nil
    }

    private func indexInCurrentPage(for location: CGPoint) -> Int? {
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
        let start = currentPage * pageCapacity
        let remaining = max(items.count - start, 0)
        let visibleCount = min(remaining, pageCapacity)
        return linearIndex < visibleCount ? linearIndex : nil
    }

    private func shouldAttemptFolderDrop(for location: CGPoint, targetIndex: Int) -> Bool {
        guard let frame = cellFrame(at: targetIndex) else { return false }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let dx = location.x - center.x
        let dy = location.y - center.y
        let distance = sqrt(dx * dx + dy * dy)
        let threshold = min(frame.width, frame.height) * 0.32
        return distance <= threshold
    }

    private func cellFrame(at itemIndex: Int) -> CGRect? {
        let columns = LauncherGridConfiguration.columnsPerPage
        let totalSpacingX = layout.iconSpacing * CGFloat(columns - 1)
        let rows = LauncherGridConfiguration.rowsPerPage
        let totalSpacingY = layout.iconSpacing * CGFloat(rows - 1)

        let cellWidth = max((gridSize.width - totalSpacingX) / CGFloat(columns), 1)
        let cellHeight = max((gridSize.height - totalSpacingY) / CGFloat(rows), 1)

        let indexInPage = itemIndex - currentPage * pageCapacity
        guard indexInPage >= 0 else { return nil }

        let row = indexInPage / columns
        let column = indexInPage % columns

        let x = CGFloat(column) * (cellWidth + layout.iconSpacing)
        let y = CGFloat(row) * (cellHeight + layout.iconSpacing)

        return CGRect(x: x, y: y, width: cellWidth, height: cellHeight)
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
