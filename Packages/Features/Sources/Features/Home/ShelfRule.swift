import Core
import Flows
import Foundation
import PortalKit

/// **Which library gets a shelf — and which does not** (AP29, 2026-09-11).
///
/// Since the Home screen asks all catalogs, libraries come in that previously did
/// not make it this far. **A loop over everything would be wrong:**
/// Serieshub alone reports a dozen entry points, Animehub more — at a shelf
/// height of around 265 points that would be four screen heights from a single origin,
/// and the media server would stand below.
///
/// The rule therefore lives in one place and not as three `if`s in ``HomeModel``.
nonisolated enum ShelfRule {

    /// Kinds that get **no** shelf of their own — each for its own reason.
    ///
    /// * **Music** no: Album covers are square, every shelf carries 2 : 3. A
    ///   square in portrait is a crop, and the app does not play albums anyway.
    /// * **Live** no: A channel list has no latest but a programme. That is what
    ///   the Live section is for.
    /// * **Portal levels** no: They are not a store but the menu items of a
    ///   third-party service — see ``portalShelf(from:)``.
    static let withoutShelf: Set<Core.Library.Kind> = HomeLayout.withoutShelf

    /// This many libraries **per origin** are loaded.
    ///
    /// **Per origin and not counted across all** — the finding of 2026-09-05 on the phone:
    /// Counted across all, with six libraries and two provider sections exactly the
    /// provider sections dropped out, because they stand at the back. One's own comes before the foreign,
    /// but an upper limit that makes the second service invisible does not protect the
    /// connection, it hides the service.
    static let perOrigin = HomeLayout.librariesPerOrigin

    /// The libraries that become shelves — in the order of the origins and
    /// capped per origin.
    /// - Parameter jeAnbieter: This many categories of the **provider catalog** get a
    ///   shelf. Default is ``ShelfPreferences/shelvesPerProvider`` — two.
    ///
    ///   **The media server stays with ``perOrigin``**, and that is the core: Its
    ///   libraries the viewer created and named themselves; the categories of a
    ///   provider are its sorting, and eight of them pushed one's own catalogs
    ///   four screen heights down (finding of 2026-09-12).
    /// The name of the fixed collections shelf — **to avoid showing it twice.**
    ///
    /// **Measured on 2026-09-13:** The media server holds a library
    /// `Sammlungen` with `CollectionType: boxsets`, and ``HomeModel/collectionsID``
    /// shows **the same** entries as a fixed shelf. On the Home screen and in
    /// shelf management "Collections" thus stood twice — two rows with the same
    /// name cannot be told apart from three meters.
    ///
    /// **The name is compared and not the kind, and that is a stopgap with an
    /// expiry date.** ``Core/Library/Kind`` has no case for collections;
    /// `boxsets` falls into `.mixed`, exactly like `folders` ("Directories"), and those
    /// do belong on the shelf. The clean way would be a case of its own — it
    /// affects a shared package and four `switch`es in two programs and does not belong
    /// in a night shift. Listed as an open item in E80.
    ///
    /// **The rule lives since decision 27 (C1) in
    /// ``Flows/HomeLayout/isCollectionLibrary(name:kind:)``** — the phone now shows the
    /// collections shelf too and asks the same place.
    static func isCollectionLibrary(_ library: Core.Library) -> Bool {
        HomeLayout.isCollectionLibrary(name: library.name, kind: library.kind)
    }

    /// - Parameter kategorien: The **chosen** categories of the provider. Empty means
    ///   "the first `perProvider`" — the normal case.
    ///
    ///   **A number alone says only how many** (finding of 2026-09-13): Which ones it
    ///   becomes was decided by the provider's order, and there the
    ///   series sections come first — a tester got two series shelves and no movie shelf.
    ///
    /// **Which categories of the provider is decided since decision 27 (C2) by
    /// ``Flows/HomeLayout/providerCategories(_:identifier:perProvider:chosen:)``** — the same
    /// place the phone asks.
    static func forShelves(
        _ libraries: [Core.Library], perProvider: Int = 2, categories: [String] = []
    ) -> [Core.Library] {
        let provider = Set(
            HomeLayout.providerCategories(
                libraries.filter {
                    Origin.forItem(library: $0.id) == .provider && !withoutShelf.contains($0.kind)
                },
                identifier: \.id, perProvider: perProvider, chosen: categories
            ).map(\.id))
        var counted: [Origin: Int] = [:]
        return libraries.filter { library in
            let origin = Origin.forItem(library: library.id)
            guard origin != .provider else { return provider.contains(library.id) }
            guard !withoutShelf.contains(library.kind), !isCollectionLibrary(library)
            else { return false }
            let previous = counted[origin, default: 0]
            guard previous < perOrigin else { return false }
            counted[origin] = previous + 1
            return true
        }
    }

    /// **One shelf for all portals together**, not one per entry point.
    ///
    /// The difference is not the quantity but the nature of the thing: A library
    /// is a store that one opens; a portal entry point is a menu item of a
    /// third-party service. Showing it as a shelf would promise a store that does not
    /// exist — and the tiles there carry no background image, so are also not suited
    /// for the hero area.
    ///
    /// - Returns: `nil` if no portal level contributed anything. **An empty shelf
    ///   does not appear** — that the bridge is up is not news.
    static func portalShelf(from title: [MediaItem]) -> HomeModel.Shelf? {
        guard !title.isEmpty else { return nil }
        return HomeModel.Shelf(
            id: portalShelfID,
            titleKey: "common.fromPortals",
            items: title,
            usesWideCards: false,
            libraryKind: .portalLevel)
    }

    /// The identifier of the portal shelf — **fixed and not derived from a library.**
    ///
    /// ``ShelfPreferences`` remembers order and visibility per identifier. One that
    /// changed with the first entry point of the first portal would lose both as soon as
    /// someone removes a portal.
    static let portalShelfID = ShelfIdentifier.portals

    /// This many entry points contribute to the portal shelf.
    ///
    /// Each costs a fetch over the bridge to a third-party service. Three suffice for
    /// a full row; whoever wants to see more goes to the portal section.
    static let portalEntryPoints = 3

    /// Whether the **portal** of a chosen folder is reported — not the folder itself.
    ///
    /// **This is where the finding of 2026-09-13 lay** ("2 chosen … currently only one").
    /// ``HomeModel`` and ``ShelfPlan`` both checked whether the chosen identifier is among the
    /// reported levels — and only the **entry points** of a portal are reported,
    /// never their subfolders. Whoever chose "Popular Series · Action" thereby chose something that
    /// can be in no list, and the Home screen skipped it without a word. The
    /// rule behind it was meant correctly — a portal that is silent right now should not delete
    /// the choice — and was checked against the wrong thing: What can be silent is the portal,
    /// not a folder in it.
    ///
    /// **In one place**, because two checks of the same question were exactly what drifted
    /// apart here: ``ShelfPlan`` showed the row, ``HomeModel`` built the shelf, and
    /// both with the same wrong condition.
    static func portalReported(forItem identifier: String, under libraries: [Core.Library]) -> Bool {
        guard let portal = PortalLibraryID(identifier)?.portal else { return false }
        return libraries.contains { PortalLibraryID($0.id)?.portal == portal }
    }
}
