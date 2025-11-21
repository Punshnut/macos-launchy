import Foundation

/// Shared grid sizing used by the launcher so paging math stays consistent everywhere.
enum LauncherGridConfiguration {
    static let columnsPerPage = 7
    static let rowsPerPage = 5
    /// Total number of apps displayed on a single grid page.
    static var pageCapacity: Int { columnsPerPage * rowsPerPage }
    /// Backwards-compatible alias until callers migrate to `pageCapacity`.
    static var appsPerPage: Int { pageCapacity }

    /// Returns an insertion index that keeps the item within the target page, pushing overflow forward.
    static func insertionIndex(for targetPage: Int, itemsCount: Int, pageCapacity: Int = LauncherGridConfiguration.pageCapacity) -> Int {
        guard pageCapacity > 0 else { return itemsCount }

        let clampedPage = max(targetPage, 0)
        let safeStart = min(clampedPage * pageCapacity, itemsCount)
        let pageEnd = min(safeStart + pageCapacity, itemsCount)
        let itemsOnPage = pageEnd - safeStart

        if itemsOnPage < pageCapacity {
            return pageEnd
        } else {
            return max(pageEnd - 1, safeStart)
        }
    }
}
