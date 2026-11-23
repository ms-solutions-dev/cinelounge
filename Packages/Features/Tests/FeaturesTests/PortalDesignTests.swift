import Core
import DesignSystem
import Foundation
import Testing

@testable import Features

/// The design rules of the portal area — those that can be calculated.
///
/// What is to be seen on the TV no machine checks. What can be checked is
/// what it arises from: row height, width, count and the rule by which a
/// level chooses its image format. Exactly at these four places the finding of
/// 2026-08-27 arose.
@Suite("Portals: design")
/// On the main actor, because the rules being checked live there (AP15,
/// 2026-09-02): the warning gate turns "nonisolated calls MainActor" into a
/// failure — and in substance it always was one.
@MainActor
struct PortalDesignTests {

    private func entry(
        _ id: String,
        kind: MediaItem.Kind = .series,
        wide: Bool? = nil
    ) -> MediaItem {
        MediaItem(
            id: id, kind: kind, title: id,
            artwork: Artwork(posterID: "https://beispiel.invalid/\(id).jpg", isWide: wide))
    }

    // MARK: - The row

    /// The row always reserves both text lines. Otherwise it measured 112
    /// points with a subtitle and 70 without — and the focus bar jumped in
    /// height while going through, because both forms occur in one level.
    @Test("A portal row carries title and subtitle without clipping them")
    func rowCarriesBothTextLines() {
        let text =
            TypeLevel.lineHeight(zu: TypeLevel.text.points)
            + PortalList.textSpacing
            + TypeLevel.lineHeight(zu: TypeLevel.lowercased.points)

        // A value without input: the height cannot depend on the content of a row at all
        // — the same number for every row of the list.
        #expect(PortalList.height >= text + 2 * PortalList.verticalInset)
    }

    /// **The 900 points were the specification of the settings.** Those carry a
    /// section column on the left; a portal area does not have one, and in the 1724
    /// points wide surface 824 points stayed empty on the right.
    @Test("A portal row takes the whole area, not 900 points")
    func rowTakesTheWholeArea() {
        #expect(PortalList.maxWidth == .infinity)

        // For comparison the old number in the measured surface: that much stayed empty.
        let surface: CGFloat = 1724
        #expect(surface - 900 == 824)
    }

    /// Running text keeps its reading width: a line across the whole picture width
    /// loses its beginning at three meters' distance.
    @Test("The reason in an error message stays readably narrow")
    func hintKeepsReadingWidth() {
        #expect(PortalList.readingWidth < 1724)
        #expect(PortalList.readingWidth.isFinite)
    }

    // MARK: - The header

    /// The header promises as many entries as the list holds.
    /// Subheadings are not entries.
    @Test("Subheadings do not count as entries")
    func countWithoutSeparator() {
        let items = [
            entry("a"),
            entry("geheimtipps", kind: .separator),
            entry("b"),
            entry("c", kind: .folder),
        ]
        #expect(PortalList.count(items) == 3)
        #expect(PortalList.count([]) == 0)
    }

    // MARK: - The aspect ratio

    /// The level decides, not the tile — and when in doubt, portrait.
    @Test("A level is wide if all entries report wide")
    func levelIsWide() {
        #expect(MediaItem.prefersWideArtwork(in: [entry("a", wide: true)]))
        #expect(
            MediaItem.prefersWideArtwork(in: [
                entry("a", wide: true), entry("b", wide: true),
            ]))
    }

    /// A single entry in portrait format tips the whole level: a poster in a
    /// landscape frame would be cropped by two thirds.
    @Test("A reported portrait format outvotes every wide format")
    func portraitOverrides() {
        #expect(
            !MediaItem.prefersWideArtwork(in: [
                entry("a", wide: true), entry("b", wide: false),
            ]))
    }

    /// "Not checked" is not a statement: without a declaration it stays portrait, and
    /// a declaration next to it is not devalued by that.
    @Test("Without a hint the level stays portrait", arguments: [true, false])
    func portraitWithoutSpecification(mixed: Bool) {
        let withoutValue = [entry("a"), entry("b")]
        #expect(!MediaItem.prefersWideArtwork(in: withoutValue))
        #expect(!MediaItem.prefersWideArtwork(in: []))

        // An entry without a declaration does not vote — it does not prevent
        // landscape format if another one reports it.
        if mixed {
            #expect(MediaItem.prefersWideArtwork(in: [entry("a"), entry("b", wide: true)]))
        }
    }

    /// The grid knows two column counts, and the wide one must fit next to the
    /// information column — the same calculation as in `LayoutBudgetTests`.
    @Test("Two wide tiles fit next to the information column")
    func wideGridFitsBesideColumn() {
        let tiles =
            CGFloat(LibraryView.wideGridColumns) * MetricsBoard.tv.episode.width
            + CGFloat(LibraryView.wideGridColumns - 1) * LibraryView.gridSpacing
            + 2 * MetricsBoard.tv.margin
        let column = DetailColumn.width + LibraryView.columnGap + MetricsBoard.tv.margin
        let available: CGFloat = 1920 - AppSidebar.collapsedWidth

        #expect(tiles + column <= available)
        // And three did not fit — that pins down the number 2 as a decision.
        let third = MetricsBoard.tv.episode.width + LibraryView.gridSpacing
        #expect(tiles + third + column > available)
    }
}
