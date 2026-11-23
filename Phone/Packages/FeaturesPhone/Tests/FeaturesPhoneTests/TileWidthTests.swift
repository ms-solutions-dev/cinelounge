import DesignSystemPhone
import Foundation
import SourceProbe
import SwiftUI
import Testing

@testable import FeaturesPhone

/// **All five grids calculate with the same number** — AP7, 2026-09-23.
///
/// **The finding:** on an iPad Pro 13″ a poster tile grew to **323 points** —
/// 2.9 times the design device, in area 8.6 times —, because the width was calculated from
/// the measured screen width ("three per row") instead of being fixed.
///
/// **And five views hang on this, not two.** The roadmap names Library and
/// Home; ``FavoritesScreen``, ``DownloadsView`` and ``PortalsView`` calculate with the same
/// numbers. If only two were switched, the other three would keep fetching the same posters in
/// the old size — **two image versions in memory**, exactly what ``ShelfMetrics``
/// argues against on the spot. That is why this is one step and not five.
///
/// **The check runs over the source**, as with the neighbors: what width a tile
/// ends up occupying arises when drawing. The **rule** can be verified — whoever calculates a
/// tile width names the size class.
@Test("No view computes a tile width without the size class")
func tileWidthsNameTheSizeClass() throws {
    var withoutClass: [String] = []
    for file in try SourceText.files(in: .featuresPhone) {
        // The building blocks themselves do not count — there the calculation stands, not its use.
        guard file.name != "ShelfMetrics.swift",
            file.name != "TitleGrid.swift",
            file.name != "MetricClass.swift"
        else { continue }

        let rows = file.content
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for (n, row) in rows.enumerated() {
            let raw = row.trimmingCharacters(in: .whitespaces)
            guard !raw.hasPrefix("//"), !raw.hasPrefix("///") else { continue }
            guard raw.contains("tileWidth(at:") || raw.contains(".tileWidth(") else { continue }
            // The class may stand in the same or the next line — the
            // formatter wraps long calls.
            let window = rows[n..<min(n + 2, rows.count)].joined(separator: " ")
            if !window.contains("sizeClass:") {
                withoutClass.append("\(file.name):\(n + 1)")
            }
        }
    }

    #expect(
        withoutClass.isEmpty,
        """
        These places compute a tile width without a size class — on the iPad the \
        tile there grows to 323 points: \(withoutClass.joined(separator: ", "))
        """)
}

/// **The column count for wide tiles must grow along**, otherwise on the iPad there are
/// two 16 : 9 tiles of 496 points each.
@Test("Wide tiles get more columns on the iPad")
func wideTilesGrowInCount() {
    #expect(MetricClass.wideColumns(.compact) == 2)
    #expect(MetricClass.wideColumns(nil) == 2)
    #expect(MetricClass.wideColumns(.regular) == 4)
}
