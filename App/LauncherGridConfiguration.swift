import Foundation

/// Shared grid sizing used by the launcher so paging math stays consistent everywhere.
enum LauncherGridConfiguration {
    static let columnsPerPage = 7
    static let rowsPerPage = 5
    static var appsPerPage: Int { columnsPerPage * rowsPerPage }
}
