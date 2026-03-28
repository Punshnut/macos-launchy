import SwiftUI
import AppKit

/// Describes layout constants for the launcher grid based on the current mode and container size.
struct LauncherLayoutMetrics {
    let containerSize: CGSize
    let launcherMode: LauncherMode
    let topInset: CGFloat
    let columnsPerPage: Int
    let rowsPerPage: Int

    /// Left/right padding surrounding the grid.
    var horizontalPadding: CGFloat {
        switch launcherMode {
        case .floaty:
            return 36
        case .fullscreen:
            return max(60, containerSize.width * 0.08)
        }
    }

    /// Bottom inset that leaves space for pager controls and shadows.
    var bottomPadding: CGFloat {
        switch launcherMode {
        case .floaty:
            return 32
        case .fullscreen:
            return 56
        }
    }

    /// Space between individual icons.
    var iconSpacing: CGFloat {
        switch launcherMode {
        case .floaty:
            return 18
        case .fullscreen:
            let base = min(containerSize.width, containerSize.height) / 40
            return max(20, min(base, 60))
        }
    }

    /// Gap between the search bar and the grid.
    var searchToGridSpacing: CGFloat {
        switch launcherMode {
        case .floaty:
            return 30
        case .fullscreen:
            return 44
        }
    }

    /// Gap between grid and pager controls.
    var gridToPagerSpacing: CGFloat {
        switch launcherMode {
        case .floaty:
            return 16
        case .fullscreen:
            return 16
        }
    }

    /// Vertical offset applied to fine-tune balance of the grid in each mode.
    var gridVerticalOffset: CGFloat {
        switch launcherMode {
        case .floaty:
            return -2
        case .fullscreen:
            return -8
        }
    }

    /// Max width of the search bar given surrounding padding.
    var searchBarWidth: CGFloat {
        let cap: CGFloat = launcherMode == .floaty ? 320 : 440
        let available = max(containerSize.width - horizontalPadding * 2, 320)
        return min(cap, available)
    }

    /// Height of the search bar container.
    var searchBarHeight: CGFloat {
        launcherMode == .floaty ? 50 : 52
    }

    /// Rounded corners for the search bar background.
    var searchBarCornerRadius: CGFloat {
        launcherMode == .floaty ? 20 : 22
    }

    /// Font size used inside the search field.
    var searchBarFontSize: CGFloat {
        launcherMode == .floaty ? 17 : 18
    }

    /// Corner radius of the outer floaty container.
    var floatyCornerRadius: CGFloat {
        launcherMode == .floaty ? 32 : 0
    }

    /// Top padding applied above the search bar in floaty mode.
    var floatySearchBarTopPadding: CGFloat {
        launcherMode == .floaty ? 16 : 0
    }

    /// Grid definition for SwiftUI's LazyVGrid.
    var gridColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: iconSpacing, alignment: .top),
            count: columnsPerPage
        )
    }

    /// Calculated icon dimension based on available space and target rows/columns.
    var iconDimension: CGFloat {
        let widthAllowance = (gridContentWidth - horizontalSpacingTotal) / CGFloat(columnsPerPage)
        let chromeAllowance = cellVerticalChrome * CGFloat(rowsPerPage)
        let heightAllowance = max(
            (availableGridHeight - verticalSpacingTotal - chromeAllowance) / CGFloat(rowsPerPage),
            1
        )
        let base = min(widthAllowance, heightAllowance)
        let desiredMax: CGFloat = launcherMode == .floaty ? 102 : 140
        let desiredMin: CGFloat = launcherMode == .floaty ? 70 : 96

        guard base.isFinite, base > 0 else {
            return desiredMin
        }

        if base < desiredMin {
            return base
        }

        return min(base, desiredMax)
    }

    var gridHeight: CGFloat {
        let rowHeight = iconDimension + cellVerticalChrome
        let height = rowHeight * CGFloat(rowsPerPage) + verticalSpacingTotal
        return max(height, 0)
    }

    /// Width available to the grid after applying horizontal padding.
    private var gridContentWidth: CGFloat {
        max(containerSize.width - horizontalPadding * 2, 0)
    }

    /// Remaining vertical space once chrome/search/pager are accounted for.
    private var availableGridHeight: CGFloat {
        let consumed = topInset + bottomPadding + searchBarHeight + pagerHeightEstimate + searchToGridSpacing + gridToPagerSpacing
        let remaining = containerSize.height - consumed
        return max(remaining, 0)
    }

    /// Total vertical spacing for the configured row count.
    private var verticalSpacingTotal: CGFloat {
        iconSpacing * CGFloat(rowsPerPage - 1)
    }

    /// Total horizontal spacing for the configured column count.
    private var horizontalSpacingTotal: CGFloat {
        iconSpacing * CGFloat(columnsPerPage - 1)
    }

    /// Rough estimate of pager height for layout calculations.
    private var pagerHeightEstimate: CGFloat {
        40
    }

    /// Extra vertical chrome per cell (labels, padding, spacing).
    private var cellVerticalChrome: CGFloat {
        let labelHeight = labelLineHeight * 2 // up to two lines of text
        let padding: CGFloat = 8 // .padding(.vertical, 4)
        let spacing: CGFloat = 10 // VStack spacing between icon and label
        return labelHeight + padding + spacing
    }

    /// Calculated single-line height of the icon label font.
    private var labelLineHeight: CGFloat {
        labelFont.ascender - labelFont.descender + labelFont.leading
    }

    /// Font for icon labels; kept here for reuse in sizing.
    private var labelFont: NSFont {
        .systemFont(ofSize: 13, weight: .medium)
    }
}
