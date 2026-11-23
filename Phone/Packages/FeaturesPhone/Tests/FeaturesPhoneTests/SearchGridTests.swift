import DesignSystemPhone
import Foundation
import SourceProbe
import SwiftUI
import Testing

@testable import FeaturesPhone

/// **Whoever caps also centers — and on the iPad the search becomes a grid**
/// (AP7, 2026-09-23).
///
/// **Partly the source text is checked and not the picture**, as with the other
/// construction checks here (``cappedStatesCenterThemselves()``,
/// ``jumpBarAndButtonShareNoCorner()``): A position in the view tree cannot be queried without a
/// running app, the **rule** behind it can.
@MainActor
@Suite("The iPad gets a layout: cap, center, grid")
struct SearchGridTests {

    /// Files that name the numbers of the ``MetricClass`` without drawing with them.
    private static let withoutDrawing: Set<String> = [
        "MetricClass.swift", "SizeClassProbe.swift",
    ]

    /// All Swift files of the views, per file its lines.
    private static func views() throws -> [(name: String, rows: [String])] {
        var found: [(name: String, rows: [String])] = []
        for file in try SourceText.files(in: .featuresPhone) {
            // The number table itself does not count — there the number is stated, not its
            // use. The same goes for the size-class probe (AP7, 2026-09-24): It
            // **names** every number of the table in the recording and draws with none.
            // Without this line it would be a red that reports nothing — and the answer
            // to it would be a `maxWidth: .infinity` in a modifier that draws
            // nothing, that is, a check that forces nonsense.
            guard !Self.withoutDrawing.contains(file.name) else { continue }
            let rows = file.content
                .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            found.append((name: file.name, rows: rows))
        }
        return found
    }

    /// **The check that this is really about.**
    ///
    /// **The error has already happened twice in this app.** A
    /// `.frame(maxWidth: …)` only says how wide a block gets **at most** — where it then
    /// sits is decided by the parent, and that pins to the left. On an iPad Pro 13″
    /// the capped column thus stands at the left edge, with 332 points of nothing next to it,
    /// and looks worse than the too-wide content before. On the phone it is never
    /// noticed: There the available width is smaller than the cap.
    ///
    /// **Only ``MetricClass/contentCap(_:)`` is checked** and not every cap
    /// at all. It caps a **column** — a list, a sheet, an input —, and
    /// a column that does not stand in the middle is an oversight. A reading width over
    /// running text, by contrast, may stay attached to its heading; it has a reference
    /// to align to, and would be a false red here.
    ///
    /// **Comment lines do not count.** The justification *above* the place names both
    /// names, and a check that triggers on its own justification checks nothing.
    @Test("Every content cap centers itself in the available width")
    func whoeverCapsAlsoCenters() throws {
        var withoutCenter: [String] = []
        for (name, rows) in try Self.views() {
            for (n, row) in rows.enumerated() {
                let blank = row.trimmingCharacters(in: .whitespaces)
                guard !blank.hasPrefix("//"), blank.contains("contentCap(") else { continue }
                let from = max(0, n - 4)
                let upTo = min(n + 5, rows.count)
                let window = rows[from..<upTo].joined(separator: "\n")
                if !window.contains("maxWidth: .infinity") { withoutCenter.append("\(name):\(n + 1)") }
            }
        }

        #expect(
            withoutCenter.isEmpty,
            """
            `MetricClass.contentCap` is applied here without centering the block in the \
            available width: \(withoutCenter.joined(separator: ", ")) — on the \
            iPad the column then sits at the left edge.
            """)
    }

    // **There used to be a check here, "The settings list is capped on the iPad".**
    //
    // It searched for `MetricClass.contentCap(` in ``SettingsScreen`` — and went red when
    // the cap moved to where it belongs: into the building block ``ContentColumn``, which
    // since 2026-09-23 **all thirteen** settings pages use. Its intent
    // was still right, its mechanism no longer.
    //
    // Replaced by ``settingsPagesUseContentColumn()``: That checks not one
    // page but every one under `Einstellungen/` with its own scroll area — also the
    // fourteenth, which is added later.

    /// **The search hits become a grid on the iPad.**
    ///
    /// A hit row there is 1032 points wide and about 90 percent empty. The
    /// reason why it nevertheless stays a list on the phone is at ``SearchGrid``.
    @Test("On the iPad the search lays its results out in the grid")
    func searchLaysOutGrid() throws {
        let content = try SourceText.read("SearchScreen.swift", in: .featuresPhone)

        #expect(
            content.contains("SearchGrid.forItem("),
            """
            SearchScreen no longer asks for grid metrics — the results would then also sit \
            on the iPad as a single-column list across 1032 points.
            """)
    }

    /// On the iPad six tiles per row, and the cell lands where ``MetricClass`` expects it.
    @Test("On the iPad eleven rows become twenty-four tiles")
    func onPadSixColumns() throws {
        let raster = try #require(SearchGrid.forItem(width: 1032, sizeClass: .regular))

        #expect(raster.columns == MetricClass.columns(.regular))
        #expect(raster.columns == 6)
        #expect(
            raster.cellWidth > 150 && raster.cellWidth < 160,
            "The cell would be \(raster.cellWidth) points wide")
        #expect(raster.grid.count == 6)
    }

    /// **On the phone literally nothing may change** — and an iPad at half width
    /// is a phone.
    ///
    /// Split View and Stage Manager give the iPad the compact class with an unchanged
    /// device identifier. That is why the **class** and not the width comes first here: Even
    /// at 1032 points it stays a list in the compact class — and `nil`, that is "not
    /// known yet", counts as compact.
    @Test("In the compact class it stays a list")
    func onPhoneTheListStays() {
        #expect(SearchGrid.forItem(width: 393, sizeClass: .compact) == nil)
        #expect(SearchGrid.forItem(width: 393, sizeClass: nil) == nil)
        #expect(SearchGrid.forItem(width: 1032, sizeClass: .compact) == nil)
    }

    /// **The search tile falls on the same cache tier as the shelf poster.**
    ///
    /// The same discipline as in ``posterCountsFallOnSameTier()``, now for the
    /// third place that draws posters: The ``ImageLoader`` keeps address **and** size
    /// in the key, ``ImageSizes`` rounds up to multiples of 80 pixels. A
    /// search tile that rounds up differently would hold the same poster in memory a second time
    /// and pull it through the line a second time — at 0,3 Mbit/s through the
    /// tunnel that is no subtle difference.
    @Test("Search tile and shelf poster fall on the same cache tier")
    func searchTileFallsBackToShelfLevel() throws {
        // A poster is 2 : 3 — the longest edge is the height, and ``PosterTile``
        // requests the image by it.
        let aspectRatio = MetricsBoard.phone.poster.height / MetricsBoard.phone.poster.width
        func tier(_ width: CGFloat) -> Int {
            ImageSizes.pixels(forItem: (width * aspectRatio).rounded(), reference: 2)
        }

        let raster = try #require(SearchGrid.forItem(width: 1032, sizeClass: .regular))

        #expect(
            tier(raster.cellWidth) == tier(MetricClass.shelfPosterWidth(.regular)),
            """
            Search tile (\(raster.cellWidth)) and shelf poster \
            (\(MetricClass.shelfPosterWidth(.regular))) round up to different tiers — \
            the same poster would sit in memory twice.
            """)
    }
}
