import Core
import Foundation
import Testing

@testable import FeaturesPhone

/// When a portal's folders are shown.
///
/// **The finding of 2026-09-12, from review:** Can the portals themselves be made
/// collapsible here? Then one does not have to scroll so endlessly. Ten portals with eight
/// to twelve folders each are about a hundred rows in which one looks for a single folder.
///
/// Three rules, and the two exceptions are the actual work: A flap that
/// hides search hits is broken — and a list of ten closed rows in
/// which one's own choice does not appear does not answer the question it exists for.
@Suite("The flap per portal")
@MainActor
struct PortalFlapTests {

    private func folder(_ portal: String, _ howMany: Int) -> [HomeViewModel.PortalFolderContent] {
        (0..<howMany).map { slot in
            HomeViewModel.PortalFolderContent(
                identifier: "\(portal)|ordner\(slot)|", name: "Folder \(slot)",
                portal: portal, root: "\(portal)||")
        }
    }

    private func group(
        _ portal: String?, choice: String? = nil, folder howMany: Int = 3
    )
        -> HomeViewModel.PortalGroup
    {
        HomeViewModel.PortalGroup(
            portal: portal, folder: folder(portal ?? "x", howMany), choice: choice)
    }

    private func model() -> HomeViewModel {
        HomeViewModel(state: CatalogState([]), store: InMemoryStore())
    }

    /// **Closed is the default** — that was the point of the finding.
    @Test("Without any action the portals are closed")
    func defaultClosed() {
        let viewModel = model()
        #expect(viewModel.portalToggles.isEmpty)
        #expect(viewModel.isPortalGroupOpen(group("serieshub")) == false)
    }

    @Test("One press opens, a second closes")
    func toggle() {
        let viewModel = model()
        viewModel.togglePortal(group("serieshub"))
        #expect(viewModel.isPortalGroupOpen(group("serieshub")))
        // And only this one.
        #expect(viewModel.isPortalGroupOpen(group("animehub")) == false)
        viewModel.togglePortal(group("serieshub"))
        #expect(viewModel.isPortalGroupOpen(group("serieshub")) == false)
    }

    /// **A search that hides its hits is broken** — the same case as on
    /// 2026-09-07, when "Most watched" found nothing from the root.
    @Test("While searching everything is open")
    func openWhileSearching() {
        let viewModel = model()
        viewModel.portalSearchTerm = "meist"
        #expect(viewModel.portalSearching)
        #expect(viewModel.isPortalGroupOpen(group("serieshub")))
    }

    /// **The portal with the own choice stands open.** Otherwise the information for which
    /// ``HomeViewModel/PortalGroup/choice`` was built would fall behind the flap.
    @Test("Whoever has a choice is open")
    func choiceStaysOpen() {
        #expect(model().isPortalGroupOpen(group("serieshub", choice: "Beliebte Serien")))
    }

    /// **The finding of 2026-09-12 evening, from the device:** once expanded they cannot
    /// be collapsed again.
    ///
    /// The cause was this check itself: It had written "stands open" as a **latch**,
    /// not as a default. Anyone who chose a shelf in a portal got
    /// a portal with a choice — and thus one without a button. The default stays, the
    /// collapsing wins.
    @Test("A portal with a choice can be closed too")
    func choiceCanBeCollapsed() {
        let viewModel = model()
        let withSelection = group("serieshub", choice: "Beliebte Serien")
        viewModel.togglePortal(withSelection)
        #expect(viewModel.isPortalGroupOpen(withSelection) == false)
        // And open again.
        viewModel.togglePortal(withSelection)
        #expect(viewModel.isPortalGroupOpen(withSelection))
    }

    /// **The choice only decides where the toggling starts.** Without a choice it starts at
    /// expanding, with a choice at collapsing — the button is the same.
    @Test("Without a choice the first press starts by opening")
    func firstPressDependsOnDefault() {
        let viewModel = model()
        viewModel.togglePortal(group("animehub"))
        #expect(viewModel.isPortalGroupOpen(group("animehub")))
    }

    /// One level deeper there are no groups — there the group carries no portal name.
    @Test("Without portal names there is no flap")
    func withoutPortalNames() {
        #expect(model().isPortalGroupOpen(group(nil)))
    }
}
