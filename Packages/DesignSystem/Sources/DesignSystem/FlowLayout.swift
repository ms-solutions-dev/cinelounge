import SwiftUI

/// Lays out its elements side by side and wraps when the width is not enough.
///
/// **Why a layout of its own and not an `HStack`.** An `HStack` does not wrap. If
/// its content does not fit, SwiftUI squeezes it — and where there is nothing left to squeeze,
/// it is cut off. With the rating badges that was exactly what could be seen: in the narrow
/// information column four badges stood side by side that together are wider
/// than the column, and the last one dropped out. From outside this looks as if the
/// server had not delivered the rating.
///
/// The width of a text depends on the language and the content — "…/…" is shorter than
/// "8.7/10", and "AniList" is longer than "IMDb". A fixed number of badges per row
/// would therefore again only be guessed. Here it is measured and then wrapped.
///
/// Deliberately plain: there is no alignment, no equal-height rows and no
/// stretching. What is put in here are badges and markers — small things in
/// a row. Anything more would be a capability without a caller.
public struct FlowLayout: Layout {

    /// Spacing between two elements of a row.
    public var spacing: CGFloat
    /// Abstand zwischen zwei Zeilen.
    public var lineSpacing: CGFloat

    public init(spacing: CGFloat = 10, lineSpacing: CGFloat = 10) {
        self.spacing = spacing
        self.lineSpacing = lineSpacing
    }

    public func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) -> CGSize {
        // Without a proposed width there is nothing to wrap — it then behaves
        // like a single row. That is the case with a measurement to infinity,
        // and an invented width would be worse there than none.
        let maxWidth = proposal.width ?? .infinity
        let rows = arrange(subviews: subviews, maxWidth: maxWidth)

        var width: CGFloat = 0
        var height: CGFloat = 0

        for row in rows {
            var rowWidth: CGFloat = 0
            var rowHeight: CGFloat = 0
            for size in row {
                rowWidth += size.width
                rowHeight = max(rowHeight, size.height)
            }
            rowWidth += spacing * CGFloat(max(0, row.count - 1))
            width = max(width, rowWidth)
            height += rowHeight
        }
        height += lineSpacing * CGFloat(max(0, rows.count - 1))

        return CGSize(width: min(width, maxWidth), height: height)
    }

    public func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) {
        let rows = arrange(subviews: subviews, maxWidth: bounds.width)
        var index = 0
        var y = bounds.minY

        for row in rows {
            var x = bounds.minX
            let lineHeight = row.map(\.height).max() ?? 0

            for size in row {
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
                index += 1
            }

            y += lineHeight + lineSpacing
        }
    }

    /// Splits the elements into rows without placing them.
    ///
    /// Separate from placing, because both steps need the same split: `sizeThatFits`
    /// must know the height before anything is placed. Two versions of the same
    /// calculation would drift apart at the first change — and then the frame is too small
    /// for what is in it.
    private func arrange(subviews: Subviews, maxWidth: CGFloat) -> [[CGSize]] {
        var rows: [[CGSize]] = []
        var current: [CGSize] = []
        var used: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let needed = current.isEmpty ? size.width : used + spacing + size.width

            // A single element that is too wide by itself still gets its
            // own row. Otherwise an empty row would arise and below it the same
            // problem once more.
            if !current.isEmpty, needed > maxWidth {
                rows.append(current)
                current = [size]
                used = size.width
            } else {
                current.append(size)
                used = needed
            }
        }

        if !current.isEmpty { rows.append(current) }
        return rows
    }
}
