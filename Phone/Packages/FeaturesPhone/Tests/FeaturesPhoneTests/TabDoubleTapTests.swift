import Testing

@testable import FeaturesPhone

/// The second press on the already selected tab.
///
/// **The native bar does not report it as an event** (AP7): It calls the selection's setter
/// once more with the same value. Whoever does not look hears nothing — and exactly
/// that is why the gesture was missing in the whole project, although it costs nothing.
@Suite("Second tap on the own tab")
@MainActor
struct TabDoubleTapTests {

    /// **First out, then to the top.** Whoever is three levels deep wants to get out first;
    /// scrolling to the top while still inside would answer a question that
    /// nobody asked.
    @Test("If a stack exists, the second tap leads to the root")
    func stackFirst() {
        let model = ShellModel(catalogs: .fromAccesses(jellyfin: true))
        model.select(.start)
        model.navigator[.start] = [ViewPath(.detail, slot: 1)]
        let previous = model.scrollToTopRequest

        model.select(.start)

        #expect(model.navigator[.start].isEmpty, "the stack must be cleared")
        #expect(model.scrollToTopRequest == previous, "and nothing is scrolled yet")
    }

    @Test("If the root is already shown, the second tap scrolls to the top")
    func thenToTop() {
        let model = ShellModel(catalogs: .fromAccesses(jellyfin: true))
        model.select(.start)
        model.navigator[.start] = []
        let previous = model.scrollToTopRequest

        model.select(.start)

        #expect(model.scrollToTopRequest == previous + 1)
    }

    /// **A counter and no `Bool`.** Double-tapping twice in a row would otherwise yield
    /// the same value the second time as the first, and nothing would happen.
    @Test("Every further tap keeps counting")
    func keepsCounting() {
        let model = ShellModel(catalogs: .fromAccesses(jellyfin: true))
        model.select(.start)
        let previous = model.scrollToTopRequest

        model.select(.start)
        model.select(.start)
        model.select(.start)

        #expect(model.scrollToTopRequest == previous + 3)
    }

    /// **A tab switch is not a second press.** Otherwise every switch would scroll the new
    /// view to the top — and the place where one was last would be lost on every
    /// back and forth.
    @Test("Switching to another tab scrolls nothing")
    func switchDoesNotScroll() {
        let model = ShellModel(catalogs: .fromAccesses(jellyfin: true))
        model.select(.start)
        let previous = model.scrollToTopRequest

        model.select(.library)

        #expect(model.scrollToTopRequest == previous)
    }
}
