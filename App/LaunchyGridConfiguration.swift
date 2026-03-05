import Foundation

/// Shared grid sizing for the launcher so paging math stays consistent everywhere.
struct LauncherGridConfiguration: Equatable {
    let columnsPerPage: Int
    let rowsPerPage: Int

    /// Total number of apps displayed on a single grid page.
    var pageCapacity: Int { max(columnsPerPage, 1) * max(rowsPerPage, 1) }
    /// Backwards-compatible alias until callers migrate to `pageCapacity`.
    var appsPerPage: Int { pageCapacity }

    /// Returns a configuration tuned for the selected icon size and launcher mode.
    static func configuration(
        for iconSizePreference: IconSizePreference,
        mode: LauncherMode
    ) -> LauncherGridConfiguration {
        let effectivePreference = iconSizePreference.effectivePreference(for: mode)
        switch effectivePreference {
        case .small:
            return LauncherGridConfiguration(columnsPerPage: 7, rowsPerPage: 5)
        case .medium:
            return LauncherGridConfiguration(columnsPerPage: 6, rowsPerPage: 4)
        case .large:
            return LauncherGridConfiguration(columnsPerPage: 5, rowsPerPage: 3)
        }
    }

    /// Returns insertion index for a target page while preserving page overflow behavior.
    static func insertionIndex(for targetPage: Int, itemsCount: Int, pageCapacity: Int) -> Int {
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
