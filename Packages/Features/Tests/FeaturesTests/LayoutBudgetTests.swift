import CoreGraphics
import DesignSystem
import Testing

@testable import Features

/// Verifies by calculation that the views fit on the screen.
///
/// This test suite exists because of an error that cost half an hour and was misread three
/// times: The grid stood with four posters next to the information column, and together they
/// needed 88 points more than there was room for next to the sidebar.
///
/// **SwiftUI does not warn about this.** Content that is too wide is centered and overflows
/// on *both* sides. All that was visible was that something slid under the sidebar and that
/// the "A" was missing from "Siege on Corvane" — that looked like an edge error and was a
/// space error. Exactly this confusion is caught by a calculation, not by a look at the
/// screen.
@Suite("Screen space")
@MainActor
struct LayoutBudgetTests {

    /// Width of an Apple TV screen in points. Applies to 1080p and 4K alike — tvOS computes in
    /// points, not in pixels.
    static let screen: CGFloat = 1920

    /// Height of the same screen — for the vertical calculations.
    static let screenHeight: CGFloat = 1080

    /// What is left next to the collapsed sidebar.
    static var available: CGFloat { screen - AppSidebar.collapsedWidth }

    /// What is permanently occupied above the content in the grid views: the pill at its Home
    /// screen height including the gap below — since 2026-08-07 the same calculation for all
    /// sections, see ``MainView/mediaShell``.
    static var chromeAbove: CGFloat {
        MediaTabBar.reservedTop
    }

    /// The lowest line on which content can still be seen safely: The lower overscan margin
    /// stays free.
    static var bottomLimit: CGFloat { screenHeight - TVMetrics.topMargin }

    /// What the grid occupies in width: posters, gaps between them, and the safety margin on
    /// both sides.
    static var gridWidth: CGFloat {
        let posters = CGFloat(LibraryView.gridColumns) * MetricsBoard.tv.poster.width
        let gaps = CGFloat(LibraryView.gridColumns - 1) * LibraryView.gridSpacing
        return posters + gaps + 2 * MetricsBoard.tv.margin
    }

    /// What the information column occupies, with its gap to the grid and to the edge.
    static var columnWidth: CGFloat {
        DetailColumn.width + LibraryView.columnGap + MetricsBoard.tv.margin
    }

    @Test("Grid and info column fit next to the sidebar")
    func gridAndColumnFit() {
        let needed = Self.gridWidth + Self.columnWidth

        #expect(
            needed <= Self.available,
            """
            Zu breit: \(Int(needed)) Punkte gebraucht, \(Int(Self.available)) vorhanden.
            Entweder eine Rasterspalte weniger, oder die Informationsspalte schmaler.
            """
        )
    }

    @Test("There is room to spare, not just millimetres")
    func hasHeadroom() {
        // Fitting to the exact point is too tight: A slightly wider poster or a larger gap tips it
        // immediately, and the error then looks like an edge problem again.
        let slack = Self.available - (Self.gridWidth + Self.columnWidth)

        #expect(slack >= 80, "only \(Int(slack)) points to spare — too little for changes")
    }

    @Test("One more column demonstrably does not fit")
    func oneMoreColumnWouldNotFit() {
        // Records the decision. Without this test `gridColumns = 3` looks like an arbitrary choice,
        // and the next person sets it back to 4.
        let extra = MetricsBoard.tv.poster.width + LibraryView.gridSpacing
        let needed = Self.gridWidth + extra + Self.columnWidth

        #expect(needed > Self.available, "four columns would fit after all — check the calculation")
    }

    @Test("The expanded sidebar does not fully cover the content")
    func expandedSidebarLeavesRoom() {
        // It lays itself over the content when it expands. That is intended but must not go so far
        // that nothing can be seen any more.
        #expect(AppSidebar.expandedWidth < Self.screen / 3)
        #expect(AppSidebar.expandedWidth > AppSidebar.collapsedWidth)
    }

    @Test("The sidebar is wide enough for an icon with spacing")
    func collapsedSidebarFitsSymbols() {
        // Collapsed it shows only symbols. If it becomes too narrow, they overlap with the edge
        // instead of sitting in the middle.
        #expect(AppSidebar.collapsedWidth >= 100)
        #expect(AppSidebar.collapsedWidth <= 140, "otherwise it takes up space needlessly")
    }

    @Test("The longest sidebar entry is not truncated")
    func sidebarLabelsFit() {
        // **The error this check prevents cannot be seen.** The entries are set with
        // `lineLimit(1)`; too little space therefore does not mean wrapping but ellipsis — and
        // that looks like a long group name.
        //
        // Re-measured with CoreText at 29 pt semibold, the weight of the selected entry: "Movies &
        // Series" needs 209 points, "Filmler & Diziler" 203, "Filme & Serien" only 188. **German is
        // not the worst case** — whoever looks only at their own language considers 190 points
        // enough and cuts off the English entry.
        //
        // 214 instead of 209: a little room for one more letter when a translation is sharpened.
        // Whoever needs more must raise ``AppSidebar/expandedWidth`` — and then runs into the Live
        // section, see `expandedSidebarLeavesThePanel` in `LiveModelTests`.
        let room = Int(AppSidebar.labelWidth)
        #expect(
            AppSidebar.labelWidth >= 214,
            "only \(room) points for the label, the longest entry needs 209"
        )
    }

    @Test("The header pulls the artwork down without losing the sides")
    func heroZoomLowersTheSubject() {
        // Two observations on the TV, and both hang on one number.
        //
        // The first: Anchored at the top, the subject still sits too high. The anchor is at its
        // limit there — a 16:9 image at 1920 points wide is 1080 high, its center is at 540, and a
        // taller surface changes nothing about that. Lower is possible only by zooming into the
        // image.
        let imageHeight = Self.screen * 9 / 16
        let drop = imageHeight / 2 * (HomeView.heroZoom - 1)
        #expect(drop >= 40, "only \(Int(drop)) points lower — not visible from three metres")

        // The second: It is paid for with the margins. From about 140 points per side something is
        // visibly missing in a background image — exactly the limit that nobody will remember the
        // next time ``HomeView/heroZoom`` is turned.
        let sideLoss = HomeView.heroSize.width * (HomeView.heroZoom - 1) / 2
        #expect(sideLoss <= 140, "\(Int(sideLoss)) points per side are lost — too much")
    }

    @Test("The expanded category list stays on screen")
    func categoryPanelFits() {
        // The list hangs at a fixed place below the button and carries a maximum height. Both
        // together must fit on the screen — if it runs out at the bottom, the last entry is
        // unreachable, and **that does not look like a space error but like a category that does
        // not exist.**
        //
        // The calculation is done from the screen down, not from the view's edge: Above the library
        // lie the pill and the overscan margin, and below the overscan zone stays free. The earlier
        // version of this calculation left out both and therefore waved through 620 points of list
        // height, of which the last ones ran out at the bottom.
        let panel =
            Self.chromeAbove
            + LibraryView.categoryPanelTop
            + LibraryView.categoryPanelHeight
            // Inner padding top and bottom, the button for closing and its gap.
            + 2 * 22 + 68 + 18

        #expect(
            panel <= Self.bottomLimit,
            "the list reaches \(Int(panel - Self.bottomLimit)) points too far down"
        )

        // And it must not slide under the sidebar.
        #expect(MetricsBoard.tv.margin >= AppSidebar.collapsedWidth / 2)
        #expect(
            LibraryView.categoryPanelWidth + MetricsBoard.tv.margin <= Self.available,
            "the list is wider than the room next to the sidebar"
        )
    }

    /// **The library list at the title (AP89)** hangs higher than the category list — below the
    /// title instead of below the filter row — and is wider, because its rows carry a number.
    @Test("The expanded library list stays on screen")
    func libraryPanelFits() {
        let panel =
            Self.chromeAbove
            + LibraryView.libraryPanelTop
            + LibraryView.categoryPanelHeight
            + 2 * 22 + 68 + 18

        #expect(
            panel <= Self.bottomLimit,
            "the list reaches \(Int(panel - Self.bottomLimit)) points too far down"
        )
        #expect(
            LibraryView.libraryPanelWidth + MetricsBoard.tv.margin <= Self.available,
            "the list is wider than the room next to the sidebar"
        )
        // It opens below its own title and not over it.
        #expect(LibraryView.libraryPanelTop > LibraryView.headerHeight)
    }

    @Test("The library list counts its heading")
    func libraryListCountsHeading() {
        #expect(
            LibraryView.libraryListHeight(entries: 2)
                == LibraryView.libraryHeadingHeight + LibraryView.categoryListHeight(entries: 2)
        )
        // Two libraries need no scroll view; the board ends at its content.
        #expect(LibraryView.libraryListHeight(entries: 2) < LibraryView.categoryPanelHeight)
    }

    @Test("The category board grows with its content instead of up front")
    func categoryPanelHugsItsContent() {
        // A `ScrollView` takes the offered height regardless of content: With four categories an
        // empty area of around 350 points remained in the board under the last entry — and it looks
        // like an aborted load. The board therefore decides on the calculated content size whether
        // it shows the stack bare or lays it into the scroll view.
        //
        // The calculation itself: n rows, n−1 gaps — from the named values, not copied.
        #expect(
            LibraryView.categoryListHeight(entries: 5)
                == 5 * LibraryView.categoryEntryHeight + 4 * LibraryView.categoryEntrySpacing
        )

        // The review's catalog — four categories plus "Alle" — stays under the upper bound: The
        // board ends at the content, not 350 points lower.
        #expect(
            LibraryView.categoryListHeight(entries: 5) < LibraryView.categoryPanelHeight,
            "five entries already triggered scrolling — the board would be full height again"
        )

        // And the upper bound remains an upper bound: A long list runs into the scroll view instead
        // of driving the board beyond the calculated edge.
        #expect(
            LibraryView.categoryListHeight(entries: 20) > LibraryView.categoryPanelHeight,
            "twenty entries supposedly fit without scrolling — check the calculation"
        )
    }

    // MARK: - The vertical axis
    //
    // These calculations exist because of this view's second space error — the same error as
    // above, only turned by ninety degrees. The information column wanted around 1050 points of
    // height, the screen gave only about 700 after pill, header and filter row. SwiftUI does not
    // clip: The stack became taller than the image, the grid's scroll view got a visible area
    // larger than the screen and took itself for not scrollable — the second row of posters was
    // below the screen's edge and unreachable with the remote. All that was visible was "I
    // can't get down", and that looks like a focus error, not a space error. Exactly this
    // confusion is caught by a calculation.

    @Test("A full row of posters fits below the header and filter row")
    func firstPosterRowIsFullyVisible() {
        // The first row must be fully visible without scrolling — including the two-line caption
        // that has been permanently reserved since the truncated titles.
        let firstRowBottom =
            Self.chromeAbove
            + LibraryView.headerHeight
            + LibraryView.controlsHeight
            + LibraryView.gridVerticalPadding
            + PosterCard.titledHeight

        #expect(
            firstRowBottom <= Self.bottomLimit,
            """
            Die erste Reihe endet \(Int(firstRowBottom - Self.bottomLimit)) Punkte
            unter der sichtbaren Kante — Kopf oder Filterzeile sind zu hoch geworden.
            """
        )
    }

    @Test("The info column stays below its upper limit")
    func detailColumnStaysWithinItsBudget() {
        // Two statements, and both must hold. First: The column's upper bound is derived from the
        // screen — it ends at the visible lower edge and not one point lower.
        let columnBottom =
            Self.chromeAbove + LibraryView.columnTopPadding + DetailColumn.maxHeight
        #expect(
            columnBottom <= Self.bottomLimit,
            "the column's upper limit is \(Int(columnBottom - Self.bottomLimit)) points too low"
        )

        // Second: The worst content fits under the upper bound. Otherwise truncation at the
        // column's frame would be the normal case instead of the emergency — and half a
        // description paragraph would look like an error, not like intent.
        #expect(
            DetailColumn.estimatedContentHeight <= DetailColumn.maxHeight,
            """
            The column's content wants \(Int(DetailColumn.estimatedContentHeight)) points,
            the upper limit allows \(Int(DetailColumn.maxHeight)) — poster, row counts
            or spacing must shrink.
            """
        )
    }

    @Test("The merged filter row fits next to the info column")
    func mergedControlsFitBesideTheColumn() {
        // The category button moved from its own row into the filter row — that saves one row of
        // height and one focus step on the way to the pill. The price is width, and that is finite:
        // The row now sits to the left of the information column, no longer across the full image
        // width.
        //
        // It is measured as with the longest sidebar entry: 13 points per character. The CoreText
        // measurement there gave just under 14 per character at 29 points semibold; the filter
        // buttons are set in 27 points regular and are below that — 13 is the cautious side. Per
        // language the longest label counts, and the checkmark (27 points symbol plus 8 gap) sits
        // where it sits in the worst case: at the widest selectable label.
        let perCharacter: CGFloat = 13
        let check: CGFloat = 27 + 8
        let chrome = 2 * LibraryView.chipHorizontalPadding

        func chip(_ characters: Int, active: Bool = false) -> CGFloat {
            CGFloat(characters) * perCharacter + (active ? check : 0) + chrome
        }

        let chips: [CGFloat] = [
            chip(3),  // „A–Z"
            chip(15, active: true),  // "Neu hinzugefügt" — the longest sort order
            chip(9),  // „Bewertung"
            1 + 2 * 4,  // the separator including padding
            chip(10, active: true),  // "İzlenmemiş" — the longest translation
            chip(LibraryView.categoryLabelMaxCharacters, active: true),
        ]
        let row = chips.reduce(0, +) + CGFloat(chips.count - 1) * LibraryView.chipSpacing

        // What is left for the row: image width without sidebar, left margin, column gap, column
        // and its right margin.
        let room =
            Self.available - MetricsBoard.tv.margin - LibraryView.columnGap
            - DetailColumn.width - MetricsBoard.tv.margin

        #expect(
            row <= room,
            """
            The filter row needs \(Int(row)) points, next to the column
            \(Int(room)) are free. Either shorten the labels or padding — or the
            category button gets a row of its own again, and the focus path becomes
            longer again.
            """
        )
    }

    @Test("Collapsed, the icon stays on screen")
    func collapsedSidebarFitsTheIcon() {
        // The symbols grew from 24 to 28 points for the 55-inch TV, the width of the collapsed
        // sidebar stayed. This calculation records that this works out — otherwise the symbol sits
        // on the edge.
        let needed =
            2 * AppSidebar.horizontalPadding + AppSidebar.rowLeadingInset
            + AppSidebar.iconWidth
        #expect(AppSidebar.collapsedWidth >= needed)
    }

    // MARK: - The search and the two keyboards

    /// **The search must not assume a keyboard height** — which one appears is decided by the
    /// viewer in the system settings.
    ///
    /// The linear keyboard is one row high, the square one a block. As long as the grid was
    /// allowed to draw beyond its box (`scrollClipDisabled`), the difference mattered: With the
    /// flat one enough room remained that the overhang went unnoticed, with the tall one it
    /// landed in the middle of the keyboard.
    ///
    /// **This calculation checks that the overhang is no longer needed:** The room for the
    /// highlight is inside, so it suffices even if only a remainder of the screen is left.
    @Test("The room for the highlight lies inside the scroll area")
    func searchGridReservesItsOwnHighlightRoom() {
        // How far a poster in focus grows beyond its row.
        let growth = MetricsBoard.tv.poster.height * (Tokens.Focus.cardScale - 1) / 2
        #expect(SearchView.focusHeadroom >= growth)
    }

    /// **The search grid fills the width it gets — no more, no less.** Six fixed columns need
    /// 1660 points; they do not fit into the width tvOS leaves with the keyboard open, and
    /// `LazyVGrid` then centers what does not fit: on the left under the keyboard, on the right
    /// out of the picture. This calculation catches both edges.
    @Test("The search grid fills the width it gets", arguments: [1920.0, 1455.0, 1000.0])
    func searchGridFitsItsWidth(width: CGFloat) {
        let poster = MetricsBoard.tv.poster.width
        let gap: CGFloat = 44
        let available = width - MetricsBoard.tv.margin
        let columns = SearchView.columns(fitting: width)

        #expect(columns >= 1)
        let needed = CGFloat(columns) * poster + CGFloat(columns - 1) * gap
        #expect(needed <= available, "\(needed) does not fit in \(available)")

        // **And one more does not fit.** Without this counter-check it would go unnoticed if the
        // calculation became too cautious and left a hand's breadth of air on the right.
        let oneMore = CGFloat(columns + 1) * poster + CGFloat(columns) * gap
        #expect(oneMore > available)
    }

    /// And the counter-check on the order of magnitude: The room is air, not a second row.
    /// Whoever sets it too generously pushes the grid under the keyboard — then the error would
    /// be the same, only with the opposite sign.
    @Test("The spare room stays spare room and does not become half a row")
    func headroomStaysSmall() {
        #expect(SearchView.focusHeadroom < MetricsBoard.tv.poster.height / 4)
    }
}
