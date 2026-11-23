import DesignSystemPhone
import Foundation
import SwiftUI
import Testing

@testable import FeaturesPhone

/// **The size-class numbers — and the rule that holds them together** (AP7, 2026-09-23).
@MainActor
@Suite("The numbers per size class")
struct SizeClassTests {

    /// **The check that this is really about.**
    ///
    /// The ``ImageLoader`` keys on address **and** size; ``ImageSizes`` rounds up
    /// to multiples of 80 pixels. Two poster numbers that round up differently
    /// would hold **the same image twice** in memory and pull it twice through the
    /// line — at 0.3 Mbit/s through the tunnel that is no subtlety.
    ///
    /// StoryShelf keeps the same discipline with 140/150/160. Anyone who changes a number here
    /// must recompute this line; otherwise it turns red.
    @Test("Shelf and grid poster fall on the same cache tier")
    func posterCountsFallOnSameTier() {
        // A poster is 2 : 3 — the longest edge is the height.
        let aspectRatio = MetricsBoard.phone.poster.height / MetricsBoard.phone.poster.width
        func tier(_ width: CGFloat) -> Int {
            ImageSizes.pixels(forItem: width * aspectRatio, reference: 2)
        }

        // The grid cell is not a set number but falls out of the column count.
        let unrestricted = 1032.0 - 2 * MetricsBoard.phone.margin
        let columns = CGFloat(MetricClass.columns(.regular))
        let cell = (unrestricted - (columns - 1) * MetricsBoard.phone.gutter) / columns

        #expect(
            tier(MetricClass.shelfPosterWidth(.regular)) == tier(cell),
            """
            Shelf (\(MetricClass.shelfPosterWidth(.regular))) and grid cell (\(cell)) round up \
            to different tiers — the same poster would sit in memory twice.
            """)
    }

    /// **On the phone literally nothing may change.**
    ///
    /// The first draft wanted an `.adaptive` grid and would have failed on it: At
    /// 393 points today's cell is 109.67 — a lower bound of 110 would yield
    /// two columns instead of three there, at 320 points all the more. This line records
    /// that the number stays the same for every phone.
    @Test("On every iPhone it stays three columns")
    func threeColumnsOnEveryPhone() {
        #expect(MetricClass.columns(.compact) == 3)
        #expect(MetricClass.columns(nil) == 3)
    }

    /// On the iPad the **count** is to grow and not the measure.
    @Test("On the iPad it becomes six columns")
    func sixColumnsOnTheTablet() {
        #expect(MetricClass.columns(.regular) == 6)
        // And the cell lands where the design expected it.
        let unrestricted = 1032.0 - 2 * MetricsBoard.phone.margin
        let cell = (unrestricted - 5 * MetricsBoard.phone.gutter) / 6
        #expect(cell > 150 && cell < 160, "The cell would be \(cell) points wide")
    }

    /// **The compact class must not change.** An iPad at half width
    /// (Split View) gets it — there everything must stay as it was on the phone.
    @Test("In the compact class every number stays as it was")
    func compactStays() {
        #expect(MetricClass.shelfPosterWidth(.compact) == MetricsBoard.phone.poster.width)
        #expect(MetricClass.headerBox(.compact) == Metrics.headerBox)
        // `nil` means "not yet known" — the narrow version applies then too.
        #expect(MetricClass.shelfPosterWidth(nil) == MetricsBoard.phone.poster.width)
        #expect(MetricClass.headerBox(nil) == Metrics.headerBox)
    }
}
