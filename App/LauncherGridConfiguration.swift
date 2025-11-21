import Foundation

/// Shared grid sizing used by the launcher so paging math stays consistent everywhere.
enum LauncherGridConfiguration {
    static let columnsPerPage = 7
    static let rowsPerPage = 5
    /// Total number of apps displayed on a single grid page.
    static var pageCapacity: Int { columnsPerPage * rowsPerPage }
    /// Backwards-compatible alias until callers migrate to `pageCapacity`.
    static var appsPerPage: Int { pageCapacity }
}
