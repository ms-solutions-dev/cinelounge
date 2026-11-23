import DesignSystemPhone
import SwiftUI

/// A wrapping field of chips — **a set, not a list.**
///
/// **Why not twenty-three switches:** on iOS the system switch is the component for a
/// **capability** ("Show previews"), not for membership in a set. Twenty-three of them one
/// beneath the other would be over a thousand points of list for a selection that one surveys
/// at a glance — and they would look like twenty-three independent decisions instead of one.
///
/// **And it wraps instead of scrolling.** A ``ChipRow`` is right where a choice is made
/// (one level of six); here a **set** is surveyed, and what lies behind the edge is forgotten
/// while surveying. The price is a growing height, and that is right here: the screen scrolls
/// anyway.
struct ChipField: View {
    /// How far the row indents — ``Styling/MetricsBoard/margin`` on the background,
    /// ``Metrics/cardInset`` in an ``SettingsCard``.
    @Environment(\.rowInset) private var inset

    struct ContentEntryRecord: Identifiable, Equatable {
        let id: String
        let caption: String
        let on: Bool
    }

    let entries: [ContentEntryRecord]
    let setEnabled: (String) -> Void

    var body: some View {
        FlowField(spacing: Metrics.targetSpacing) {
            ForEach(entries) { entry in
                Chip(wording: entry.caption, on: entry.on) {
                    withAnimation(Motion.stateChange) { setEnabled(entry.id) }
                }
            }
        }
        .padding(.horizontal, inset)
    }
}

/// Lays out its children side by side and wraps when the row is full.
///
/// **A `Layout` and not a rebuilt `HStack` grid.** The common workaround measures the texts
/// itself beforehand and splits them into rows — that is the same calculation twice, once
/// estimated and once real, and at Dynamic Type XXL the two diverge. `Layout` gets the real
/// sizes.
struct FlowField: Layout {

    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = wrapLines(subviews, width: width)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width == .infinity ? rows.map(\.width).max() ?? 0 : width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var y = bounds.minY
        for row in wrapLines(subviews, width: bounds.width) {
            var x = bounds.minX
            for slot in row.slots {
                let size = subviews[slot].sizeThatFits(.unspecified)
                subviews[slot].place(
                    at: CGPoint(x: x, y: y), anchor: .topLeading,
                    proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var slots: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func wrapLines(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var running = Row()
        for slot in subviews.indices {
            let size = subviews[slot].sizeThatFits(.unspecified)
            let added = running.slots.isEmpty ? size.width : running.width + spacing + size.width
            if !running.slots.isEmpty && added > width {
                rows.append(running)
                running = Row()
                running.slots = [slot]
                running.width = size.width
                running.height = size.height
            } else {
                running.slots.append(slot)
                running.width = added
                running.height = max(running.height, size.height)
            }
        }
        if !running.slots.isEmpty { rows.append(running) }
        return rows
    }
}
