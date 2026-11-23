import Flows
import Foundation

/// Where Home gets its content from.
///
/// **One call, not five.** A first attempt fetched the heroes separately — forty
/// titles per library in addition to the shelves, and Home spent six seconds
/// in the loading state. The header area is chosen from what **was loaded anyway**;
/// the TV programme does the same.
///
/// **Narrowly cut, and on purpose.** `Core.ContentSource` can do forty things;
/// Home needs one. A protocol that only demands what is needed
/// can be rebuilt in a test with ten lines — one that demands everything
/// cannot.
public protocol StartSource: Sendable {
    func home(perShelf: Int) async throws -> StartContent

    /// Heroes **on request** — the third step of the ladder.
    ///
    /// **Separate from the rest of the content because they are expensive.** The provider catalog carries
    /// the background image and plot only in `get_vod_info`, i.e. one request **per
    /// title**. Fetching them at every start would mean paying eight requests for a box
    /// that is only seen when there is no Jellyfin.
    /// See ``HeroLadder``.
    func heroes(atMost: Int) async throws -> [HeroContent]
}

extension StartSource {

    /// Without its own answer there is no lookup — that is the normal case.
    public func heroes(atMost: Int) async throws -> [HeroContent] { [] }
}

/// What is on Home.
public struct StartContent: Sendable, Equatable {

    /// The catalogs the service carries — the basis for shelves **and** tabs.
    public let state: CatalogState

    /// Who appears large at the top — up to eight, by the rules of ``HeroSelection``.
    public let heroes: [HeroContent]

    /// The tiles per shelf. **By ID and not by case**, because which shelves
    /// exist is only known once the catalogs are there.
    public let tiles: [Shelf.Identifier: [TileContent]]

    /// Shelves that are not empty but **disturbed** — one reason per ID.
    ///
    /// Empty is the normal case: a shelf without tiles disappears, and that is correct.
    /// See ``ShelfDisruption``.
    public let disruptions: [Shelf.Identifier: ShelfDisruption]

    /// Which portals were **ready** when loading — `nil` means: nobody asked.
    ///
    /// **It travels along because it arises here anyway.** ``FromPortals`` asks the
    /// bridge for its portals on every load of Home and keeps only the ready ones until then;
    /// whoever fetched the same information again later paid for a second
    /// request to a third-party service for something that was already there.
    ///
    /// **What for:** ``History/validOnes(at:portals:now:)`` throws out the entries of a
    /// switched-off portal. Without this set Home would only know that there are
    /// *portals*, and a switched-off flatone would stay in
    /// "Continue Watching" with its titles — the finding of 2026-09-07.
    ///
    /// **The difference between `nil` and empty is the point.** Without a portal source
    /// nobody is asked at all (`nil`, nothing is filtered); with a portal source and no
    /// ready portal the empty set is here, and then every portal entry falls.
    public let portals: Set<String>?

    public init(
        state: CatalogState, heroes: [HeroContent],
        tiles: [Shelf.Identifier: [TileContent]],
        disruptions: [Shelf.Identifier: ShelfDisruption] = [:],
        portals: Set<String>? = nil
    ) {
        self.state = state
        self.heroes = heroes
        self.tiles = tiles
        self.disruptions = disruptions
        self.portals = portals
    }

    /// The same content, this time with the portal information.
    ///
    /// **So that the information is attached in one place and not in four.**
    /// ``FromPortals`` has four return paths — two branches and two empty cases — and
    /// the set is the same in all of them. Added to each one individually, it would be missing
    /// from the fifth.
    public func using(portals reported: Set<String>?) -> StartContent {
        StartContent(
            state: state, heroes: heroes, tiles: tiles, disruptions: disruptions,
            portals: reported)
    }
}

/// Why a shelf shows nothing — **and why it is there anyway.**
///
/// **An empty shelf disappears, a disturbed one does not.** The rule "an empty shelf
/// does not appear" is right for "nothing is here yet" and wrong for "nobody here
/// answered": the second case **is** the information, and it disappears with the shelf.
/// That was exactly the finding of 2026-09-07 — "Live today" dropped out silently,
/// although the app knew which channel list had stayed silent.
///
/// **The state is the same as in the tab** (``LiveModel/load()``), so that one cause
/// does not get two names in two places. What it cannot carry are the names: a
/// language key has no room for them, and ``names`` exists for that.
public struct ShelfDisruption: Sendable, Equatable {

    public let state: PlaybackPhase

    /// Who stayed silent — **literally, as the list is called.** Its name comes from the
    /// viewer and is not translated.
    public let names: [String]

    public init(state: PlaybackPhase, names: [String] = []) {
        self.state = state
        self.names = names
    }
}
