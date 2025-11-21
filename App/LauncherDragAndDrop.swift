import SwiftUI

/// Enables dropping items onto the grid background or pager buttons to move across pages.
struct PageReorderDropDelegate: DropDelegate {
    let targetPage: Int
    let pageCapacity: Int
    @Binding var apps: [AppItem]
    @Binding var draggedApp: AppItem?
    var performReorder: (AppItem, Int) -> Int?
    var afterReorder: (Int?) -> Void

    func dropEntered(info: DropInfo) {
        handleDropUpdate(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        handleDropUpdate(info)
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedApp = nil
        return true
    }

    private func handleDropUpdate(_ info: DropInfo) {
        guard let draggedApp else { return }
        guard pageCapacity > 0 else { return }

        let clampedPage = max(targetPage, 0)
        let pageStart = clampedPage * pageCapacity
        let pageEnd = min(pageStart + pageCapacity, apps.count)
        let destinationIndex = min(pageEnd, max(apps.count, 0))

        let finalIndex = performReorder(draggedApp, destinationIndex)
        afterReorder(finalIndex)
    }
}

/// Reorders items as the cursor moves across the grid, so neighbors slide aside in real time.
struct GridReorderDropDelegate: DropDelegate {
    let layout: LauncherLayoutMetrics
    let gridSize: CGSize
    let currentPage: Int
    let pageCapacity: Int
    @Binding var apps: [AppItem]
    @Binding var draggedApp: AppItem?
    var performReorder: (AppItem, Int) -> Int?
    var afterReorder: (Int?) -> Void

    func dropEntered(info: DropInfo) {
        handleDropUpdate(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        handleDropUpdate(info)
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedApp = nil
        return true
    }

    private func handleDropUpdate(_ info: DropInfo) {
        guard let draggedApp else { return }
        guard pageCapacity > 0 else { return }

        let targetIndex = targetIndex(for: info.location)
        let finalIndex = performReorder(draggedApp, targetIndex)
        afterReorder(finalIndex)
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
        return min(max(linearIndex, 0), apps.count)
    }
}
