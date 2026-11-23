import CoreGraphics
import Testing

@testable import FeaturesPhone

/// The swipe from the left edge — **the thresholds are checked, not felt.**
///
/// Requested on 2026-09-08: when swiping right (that is, left
/// of Home), the Downloads area should be reachable in addition to the button.
/// The gesture lies on a page that itself knows two horizontal movements — scrolling
/// shelves and a paging header box. What tells them apart are these three numbers.
@Suite("Edge swipe")
struct EdgeSwipeTests {

    private func drag(
        from x: CGFloat, span: CGFloat, height: CGFloat = 0
    ) -> Bool {
        EdgeSwipe.opens(
            start: CGPoint(x: x, y: 300), drag: CGSize(width: span, height: height))
    }

    @Test("From the edge to the right opens")
    func fromEdge() {
        #expect(drag(from: 4, span: 120))
        #expect(drag(from: EdgeSwipe.edgeWidth, span: EdgeSwipe.span))
    }

    /// **The most important case:** A shelf that is already at the start cannot be
    /// scrolled further right — the thumb pulls anyway. Without the boundary condition
    /// every such attempt would open the Downloads.
    @Test("Nothing opens in the middle of the screen")
    func inTheArea() {
        #expect(!drag(from: 60, span: 300))
        #expect(!drag(from: 200, span: 300))
    }

    @Test("Nothing opens to the left")
    func toTheLeft() {
        #expect(!drag(from: 4, span: -300))
    }

    /// **Scrolling is vertical.** A diagonal pull at the edge belongs to the scroll area.
    @Test("Too diagonal does not count")
    func tooDiagonal() {
        #expect(!drag(from: 4, span: 100, height: 90))
        #expect(drag(from: 4, span: 100, height: 20))
    }

    @Test("A short distance does not count")
    func tooShort() {
        #expect(!drag(from: 4, span: EdgeSwipe.span - 1))
    }

    // MARK: - Pushing back

    private func back(from x: CGFloat, span: CGFloat, height: CGFloat = 0) -> Bool {
        EdgeSwipe.closes(
            start: CGPoint(x: x, y: 300), drag: CGSize(width: span, height: height))
    }

    @Test("A swipe to the left closes")
    func close() {
        #expect(back(from: 4, span: -120))
        #expect(back(from: EdgeSwipe.edgeWidth, span: -EdgeSwipe.span, height: 10))
    }

    /// **The most important case here, and it turned around on 2026-09-09**
    ///
    /// Until then there stood `!back(from: 120, …)` — in the middle of a row nothing was supposed to
    /// close, so that the delete swipe of the download row would not also
    /// shut the screen. Reported on the device: swiping from Home I can open downloads,
    /// but I cannot close them again by swiping the opposite way. The reason was exactly
    /// this condition: The download rows cover the 24-point strip completely and
    /// take the pull with `highPriorityGesture` before the drawer sees it.
    ///
    /// **Product decision (2026-09-09), explicit and after weighing: close by swiping from
    /// anywhere.** The price is paid deliberately — the download row has given up
    /// its delete swipe (``SwipeCommands`` with `movesAccount: false`); deleting is done by
    /// long press and by "Select". One movement, one meaning.
    @Test("It also closes in the middle of the screen")
    func inTheRow() {
        #expect(back(from: 120, span: -200))
        #expect(back(from: 380, span: -200))
    }

    @Test("Nothing closes to the right, and too short does not close either")
    func doesNotClose() {
        #expect(!back(from: 4, span: 300))
        #expect(!back(from: 4, span: -EdgeSwipe.span + 1))
        #expect(!back(from: 4, span: -100, height: -90))
    }
}
