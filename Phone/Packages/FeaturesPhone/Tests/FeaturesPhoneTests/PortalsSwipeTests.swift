import Foundation
import SourceProbe
import Testing

@testable import FeaturesPhone

/// **Back also works by swipe** — AP7, 2026-09-23.
///
/// Reported: backward navigation in portals only works through the
/// back button and not through the swipe gesture.
///
/// **There was no system gesture to heal.** ``PortalsView`` has no
/// `NavigationStack` for its levels — ``PortalsModel`` keeps its own stack, because the
/// `NavigationStack` let its `.task` run again on 2026-09-09 and `load()` threw away the whole
/// level stack. The gesture is therefore built and not restored.
///
/// **What is checked is the wiring and not the calculation.** The thresholds of
/// ``EdgeSwipe`` have their own check; what can go wrong here is the
/// call site.
@Suite("Portals: back by swipe")
struct PortalsSwipeTests {

    private var sourceText: String {
        get throws {
            try SourceText.read("PortalsView.swift", in: .featuresPhone)
        }
    }

    @Test("Portals depend on the edge swipe")
    func dependsOnEdgeSwipe() throws {
        #expect(
            try sourceText.contains(".edgeSwipe("),
            """
            PortalsView has no edge swipe — going back then works only via the arrow \
            at the top left, and that was exactly the reported finding.
            """)
    }

    /// **The real pitfall.** The back button does two things:
    /// `model.back()` **and** `searchTerm = ""`. A gesture that only does the first leaves
    /// the search term of the level that was left standing — the level below then shows
    /// filtered, without anyone having set a filter.
    ///
    /// **That is why this check counts calls and not strings:** `model.back()`
    /// may appear in the view exactly **once**. Two occurrences would mean that button and
    /// swipe have their own bodies — and the second forgets the filter.
    @Test("Button and swipe share one place")
    func onePlace() throws {
        let text = try sourceText
        let calls = text.components(separatedBy: "model.back()").count - 1

        #expect(
            calls == 1,
            """
            `model.back()` appears \(calls) times in PortalsView instead of once. Button and \
            swipe must call the same place, otherwise one of them forgets to reset \
            the search term.
            """)

        #expect(
            text.contains("searchTerm = \"\""),
            "The shared place does not reset the search term.")
    }

    /// **On the root the gesture is switched off**, not merely without effect.
    ///
    /// ``EdgeSwipe`` takes `nil` for that — the same rule as for the downloads button in
    /// the ``HeaderRow``. The reasoning is that of the arrow, which is not shown on the root either:
    /// A way back that leads nowhere claims a place.
    @Test("Without a way back no gesture")
    func withoutWayBackNoGesture() throws {
        #expect(
            try sourceText.contains("hasWayBack"),
            """
            The gesture does not depend on `hasWayBack` — it would then also fire on the \
            portal root, where there is nothing to go back to.
            """)
    }
}
