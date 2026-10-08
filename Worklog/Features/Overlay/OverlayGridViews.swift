import SwiftUI

// Grid rendering helpers for the overlay (`OverlayContent`) and its layout editor (`OverlayLayoutEditor`).
//
// The model is `OverlayGridLayout` (Services/OverlayLayout.swift): 6 columns, rows of intrinsic height, row 0
// is the header row. Each rendered row is an `OverlayGridRowLayout` whose subviews carry their cell
// (`overlayGridCell(column:span:)`). In edit mode only, rows report their frames in the "overlayGrid"
// coordinate space (`OverlayGridRowFramesKey`) so the editor can snap drags to cells. The live overlay never
// adds geometry readers or preferences.

/// The named coordinate space shared by the editor's drag gesture, the row frames and the drag overlay.
enum OverlayGridSpace {
    static let name = "overlayGrid"
    static let coordinateSpace = CoordinateSpace.named(name)
}

// MARK: - Row layout

/// An element's cell in its row: first column and number of columns.
struct OverlayGridCellKey: LayoutValueKey {
    static let defaultValue: (column: Int, span: Int) = (column: 0, span: OverlayGridLayout.columns)
}

extension View {
    /// Places this view in `OverlayGridRowLayout` at `column` spanning `span` columns.
    func overlayGridCell(column: Int, span: Int) -> some View {
        layoutValue(key: OverlayGridCellKey.self, value: (column: column, span: span))
    }
}

/// One grid row: `columns` equal columns separated by `gutter`. With a finite proposed width W the column step
/// is (W + gutter) / columns; each subview is proposed (span·step − gutter, nil), placed at x = column·step and
/// centred vertically. The row is as tall as its tallest subview. With a nil or infinite width (an HStack
/// probing ideal sizes) it reports the sum of the subviews' ideal widths.
struct OverlayGridRowLayout: Layout {
    var columns: Int
    var gutter: CGFloat

    init(columns: Int = OverlayGridLayout.columns, gutter: CGFloat) {
        self.columns = max(1, columns)
        self.gutter = gutter
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let width = proposal.width, width.isFinite else {
            var total: CGFloat = 0
            var height: CGFloat = 0
            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)
                total += size.width
                height = max(height, size.height)
            }
            total += gutter * CGFloat(max(0, subviews.count - 1))
            return CGSize(width: total, height: height)
        }
        let step = columnStep(width: width)
        var height: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: cellWidth(subview, step: step), height: nil))
            height = max(height, size.height)
        }
        return CGSize(width: max(0, width), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let step = columnStep(width: bounds.width)
        for subview in subviews {
            let cell = clampedCell(subview)
            let width = cellWidth(subview, step: step)
            subview.place(at: CGPoint(x: bounds.minX + CGFloat(cell.column) * step, y: bounds.midY),
                          anchor: .leading,
                          proposal: ProposedViewSize(width: width, height: nil))
        }
    }

    private func columnStep(width: CGFloat) -> CGFloat {
        max(0, (width + gutter) / CGFloat(columns))
    }

    private func clampedCell(_ subview: LayoutSubview) -> (column: Int, span: Int) {
        let cell = subview[OverlayGridCellKey.self]
        let span = min(max(1, cell.span), columns)
        let column = min(max(0, cell.column), columns - span)
        return (column, span)
    }

    private func cellWidth(_ subview: LayoutSubview, step: CGFloat) -> CGFloat {
        max(0, CGFloat(clampedCell(subview).span) * step - gutter)
    }
}

// MARK: - Edit-mode preferences

/// Row frames in the "overlayGrid" space, keyed by grid row (0 = the header region; the trailing drop row while
/// dragging). Editing only.
struct OverlayGridRowFramesKey: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]

    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// Reports this view's frame as grid row `row` (in the "overlayGrid" space) when `isActive`. Inactive, it adds
    /// nothing (no GeometryReader, no preference), so the live overlay stays plain.
    func overlayGridRowFrame(_ row: Int, isActive: Bool) -> some View {
        background {
            if isActive {
                GeometryReader { proxy in
                    Color.clear.preference(key: OverlayGridRowFramesKey.self,
                                           value: [row: proxy.frame(in: OverlayGridSpace.coordinateSpace)])
                }
            }
        }
    }
}

// MARK: - Cell alignment

extension OverlayElement {
    /// "Fill" elements take the cell width (timer, segment focus, note, takeaway, and the idle controls); the
    /// others ("hug": label, active controls, split, today's total) keep their size inside the cell.
    func fillsOverlayCell(isActive: Bool) -> Bool {
        switch self {
        case .timer, .segmentFocus, .note, .takeaway: return true
        case .controls: return !isActive
        case .label, .split, .todayTotal: return false
        }
    }

    /// Where the element sits in `placement`'s cell: hug elements align trailing when they end at the last column
    /// and don't start at the first; everything else is leading.
    func overlayCellAlignment(column: Int, span: Int, isActive: Bool) -> Alignment {
        guard !fillsOverlayCell(isActive: isActive) else { return .leading }
        let endsAtLastColumn = column + span >= OverlayGridLayout.columns
        return endsAtLastColumn && column > 0 ? .trailing : .leading
    }
}

// MARK: - Accessibility copy

enum OverlayGridCopy {
    /// "Row 1, columns 1–4", or "Row 3, column 3" for a single column (1-based; the header row is row 1).
    static func position(_ placement: OverlayPlacement) -> String {
        let row = placement.row + 1
        let first = placement.column + 1
        if placement.span <= 1 {
            return "Row \(row), column \(first)"
        }
        return "Row \(row), columns \(first)\u{2013}\(placement.endColumn)"
    }
}
