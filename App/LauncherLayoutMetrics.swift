import SwiftUI
import AppKit

/// Describes layout constants for the launcher grid based on the current mode and container size.
struct LauncherLayoutMetrics {
    let containerSize: CGSize
    let launcherMode: LauncherMode
    let topInset: CGFloat
    let columnsPerPage: Int
    let rowsPerPage: Int

    var horizontalPadding: CGFloat {
        switch launcherMode {
        case .floaty:
            return 32
        case .fullscreen:
            return max(60, containerSize.width * 0.08)
        }
    }

    var bottomPadding: CGFloat {
        switch launcherMode {
        case .floaty:
            return 28
        case .fullscreen:
            return 56
        }
    }

    var iconSpacing: CGFloat {
        switch launcherMode {
        case .floaty:
            return 14
        case .fullscreen:
            let base = min(containerSize.width, containerSize.height) / 40
            return max(20, min(base, 60))
        }
    }

    var searchToGridSpacing: CGFloat {
        switch launcherMode {
        case .floaty:
            return 32
        case .fullscreen:
            return 44
        }
    }

    var gridToPagerSpacing: CGFloat {
        switch launcherMode {
        case .floaty:
            return 20
        case .fullscreen:
            return 16
        }
    }

    var gridVerticalOffset: CGFloat {
        switch launcherMode {
        case .floaty:
            return -6
        case .fullscreen:
            return -8
        }
    }

    var searchBarWidth: CGFloat {
        let cap: CGFloat = launcherMode == .floaty ? 520 : 620
        let available = max(containerSize.width - horizontalPadding * 2, 320)
        return min(cap, available)
    }

    var searchBarHeight: CGFloat {
        launcherMode == .floaty ? 46 : 52
    }

    var searchBarCornerRadius: CGFloat {
        launcherMode == .floaty ? 18 : 22
    }

    var searchBarFontSize: CGFloat {
        launcherMode == .floaty ? 17 : 18
    }

    var floatyCornerRadius: CGFloat {
        launcherMode == .floaty ? 32 : 0
    }

    var floatySearchBarTopPadding: CGFloat {
        launcherMode == .floaty ? 20 : 0
    }

    var gridColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: iconSpacing, alignment: .top),
            count: columnsPerPage
        )
    }

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

    private var gridContentWidth: CGFloat {
        max(containerSize.width - horizontalPadding * 2, 0)
    }

    private var availableGridHeight: CGFloat {
        let consumed = topInset + bottomPadding + searchBarHeight + pagerHeightEstimate + searchToGridSpacing + gridToPagerSpacing
        let remaining = containerSize.height - consumed
        return max(remaining, 0)
    }

    private var verticalSpacingTotal: CGFloat {
        iconSpacing * CGFloat(rowsPerPage - 1)
    }

    private var horizontalSpacingTotal: CGFloat {
        iconSpacing * CGFloat(columnsPerPage - 1)
    }

    private var pagerHeightEstimate: CGFloat {
        40
    }

    private var cellVerticalChrome: CGFloat {
        let labelHeight = labelLineHeight * 2 // up to two lines of text
        let padding: CGFloat = 8 // .padding(.vertical, 4)
        let spacing: CGFloat = 10 // VStack spacing between icon and label
        return labelHeight + padding + spacing
    }

    private var labelLineHeight: CGFloat {
        labelFont.ascender - labelFont.descender + labelFont.leading
    }

    private var labelFont: NSFont {
        .systemFont(ofSize: 13, weight: .medium)
    }
}
