import Core
import Diagnose
import Flows
import Foundation

/// What comes from outside — as a shelf on Home.
///
/// **Below one's own, and that is a ranking, not a sequence.** The same rule as on the
/// TV: what is in the household stands above what a third-party service happens to offer.
/// Anyone who has to look for their own shelf below third-party ones has already been
/// given a half-wrong answer to the question "what can I watch right now".
///
/// **A shelf without images, and it stays that way.** The bridge delivers titles,
/// languages and state; images belong to the host. ``EmptyTile`` carries the title as
/// its motif — that is not a stopgap but the form this catalog has.
///
/// **One shelf per chosen folder, and without a choice exactly one** (product owner's
/// decision of 2026-09-07). Until then there was only ever one shelf from **one** portal here,
/// and the reason for it was the line: "Querying all of them would mean bothering three
/// third-party services at every start, two of which nobody cares about." That sentence is
/// right for an automatic shelf and no longer for a chosen one — anyone who has explicitly
/// chosen "Serieshub › Beliebte Serien" and "Animehub › Neue Folgen" has said that both
/// interest them. Hence now:
///
/// * **Nothing chosen** → **one** shelf "From the Portals", filled automatically, in the
///   three steps from below. This is the state of a freshly set-up device, and without it
///   nothing would be there at all.
/// * **Something chosen** → **one shelf per choice**, named after portal and folder, and
///   **none** for portals without a choice. This is the condition the product owner gave:
///   "provided that something is actually chosen for the others."
///
/// **Without a choice, two steps decide which portal it is**, exactly as with
/// ``TodayLive``: the one used last (``PortalMemory``) and otherwise the first ready
/// one. The third, the choice, has moved into the upper branch.
///
/// **And it contains titles, not categories** — see ``titleLevel(under:)``.
public struct FromPortals: StartSource {

    private let source: any PortalContentSource
    private let memory: PortalMemory
    private let preferences: @Sendable () -> StartPreferences

    public init(
        source: any PortalContentSource, memory: PortalMemory = .init(),
        preferences: (@Sendable () -> StartPreferences)? = nil
    ) {
        self.source = source
        self.memory = memory
        self.preferences = preferences ?? { .preset }
    }

    /// At most this many portal shelves are created.
    ///
    /// **Three, and the number is here and not with the catalog shelves.**
    /// ``ShelvesPerCatalog/atMost`` caps four per origin, and that cap takes effect in
    /// ``StartModel/visibleShelves`` — but only for shelves with a target, that is for those
    /// that open a library. A portal shelf has none (see ``ShelvesPerPortalFolder``), and the
    /// number would be the wrong one anyway: four catalog shelves are four queries to **one**
    /// service that responds anyway; three portal shelves are three requests to three
    /// third-party services. The product owner said three, and the bridge currently has
    /// exactly three portals.
    ///
    /// **The same split as with the channels**: the number is with whoever builds the shelf
    /// (``TodayLive/atMost``), and Settings aligns its choice with it.
    public static let atMost = HomeLayout.maxPortalFolders

    /// At most this many levels are fetched by this shelf.
    ///
    /// **Four, and the number is a question of the line and not of taste.** Each level is a
    /// request over the bridge to a third-party portal; Home is the first screen, and what
    /// holds it up holds up the whole app. Four suffice for the case that really exists —
    /// root, "Popular Series", the menu behind it, the list — and additionally cover one
    /// wrong turn.
    static let maxFetches = 4

    /// At most this many doors per level are considered at all.
    ///
    /// A root level of Serieshub has eight entry points. Trying all of them would be the
    /// same mistake as "ask all portals", only one level deeper.
    static let maxWidth = 3

    public func home(perShelf: Int) async throws -> StartContent {
        let readyPortals = try await source.portals().filter { $0.state.isReady }
        // **Whoever has responded is reported** (2026-09-07). This set costs nothing — it arises
        // during the query anyway — and without it "Continue Watching" cannot tell the entries of
        // a switched-off portal from those of a running one. See ``StartContent/portals``.
        let reported = Set(readyPortals.map(\.id))
        let chosen = Array(preferences().portalFolders.prefix(Self.atMost))

        // **A choice that does not respond today does not take the shelf with it.** Anyone who
        // chose Animehub and whose login has expired gets not an empty Home but the automatic
        // shelf — the same rule that applied to the single choice before 2026-09-07.
        let built: StartContent
        if let selected = await shelves(for: chosen, from: readyPortals, perShelf: perShelf) {
            built = selected
        } else {
            do {
                built = try await buildAutomatically(from: readyPortals, perShelf: perShelf)
            } catch {
                // **A failing shelf does not take "Continue Watching" with it** (2026-09-29).
                Diagnose.hint(.network, "Home: CL-Server shelf without a choice", error)
                built = Self.empty
            }
        }
        return await withContinueWatching(built, perShelf: perShelf).using(portals: reported)
    }

    /// "Continue Watching" from the CL-Server — **always, independent of the shelves.**
    ///
    /// **The finding (iPhone, 2026-09-29):** Woujeinspes Grioworn was in Continue Watching on the TV,
    /// but not on the iPhone. The state was only fetched if a chosen folder delivered
    /// something; without a choice, with failing folders or with an error at the root it was
    /// missing — the TV fetches it independently of that. And as there, the choice "own area"
    /// applies (``Core/PortalPreferences``).
    private func withContinueWatching(_ content: StartContent, perShelf: Int) async -> StartContent {
        let preferences = PortalPreferences.load(from: SecureStore())
        let started = await source.continueWatching(atMost: perShelf)
            .filter { preferences.accepts(identifier: $0.id) }
        guard !started.isEmpty else { return content }
        var tiles = content.tiles
        tiles[.fixed(ShelfIdentifier.continueWatching)] = started
        return StartContent(
            state: content.state, heroes: content.heroes, tiles: tiles,
            disruptions: content.disruptions, portals: content.portals)
    }

    // MARK: - The chosen folders

    /// One shelf per chosen folder — `nil` if no choice yields anything.
    ///
    /// **Fetched side by side and assembled in the chosen order.** Three requests one after
    /// another are three waiting times in a row; measured at the bridge on 2026-09-07, the
    /// simultaneous set costs 0.26 s instead of 0.49 s, and six passes with three
    /// simultaneous requests each brought not a single failure. The connection limit that
    /// forces the provider catalog into a sequence
    /// (``XtreamStartSource/heroes(atMost:)``) belongs to a different service and does not
    /// apply here.
    ///
    /// **Whoever answers first still decides nothing.** The order of the shelves is that of
    /// the choice; otherwise Home would look different on every opening — the same
    /// consideration as in ``CompositeStartSource``.
    private func shelves(
        for choices: [StartPreferences.PortalChoice], from readyPortals: [PortalInfo],
        perShelf: Int
    ) async -> StartContent? {
        let jobs = choices.compactMap { choice in
            portal(for: choice.identifier, from: readyPortals).map { (choice, $0) }
        }
        guard !jobs.isEmpty else { return nil }

        let found = await withTaskGroup(of: (Int, Catalog, [TileContent])?.self) { group in
            for (slot, job) in jobs.enumerated() {
                group.addTask {
                    await self.shelf(
                        for: job.0, from: job.1, slot: slot, perShelf: perShelf)
                }
            }
            var collected: [(Int, Catalog, [TileContent])] = []
            for await part in group {
                if let part { collected.append(part) }
            }
            return collected.sorted { $0.0 < $1.0 }
        }
        guard !found.isEmpty else { return nil }

        var tiles: [Shelf.Identifier: [TileContent]] = [:]
        for (_, catalog, content) in found { tiles[.zu(catalog.id)] = content }
        return StartContent(
            state: CatalogState(found.map { $0.1 }), heroes: [], tiles: tiles)
    }

    /// A single shelf for one choice — `nil` if there are no titles behind it.
    ///
    /// **A deeply chosen level is fetched and not searched for.** Since 2026-09-07 you can choose
    /// arbitrarily deep in "Arrange shelves" — "Serieshub › Beliebte Serien › Meistgesehen
    /// gerade" is the case the product owner asked it for. An identifier three levels below
    /// the root is in no root row; finding it again via the entry points would not work, and
    /// the choice would be ineffective without anyone noticing.
    ///
    /// **If the chosen level leads to categories again, it descends from there** and not from
    /// the root. Anyone who chooses "Beliebte Serien" and has a menu behind it has still said
    /// where to search — and the way from here is shorter than the one via the root.
    ///
    /// **The shelf is named after portal and folder.** "Beliebte Serien" exists at two of the
    /// three portals; without the name in front there would be two identically labelled
    /// shelves one below the other. The same consideration as with the provider shelf that is
    /// named after its section (``XtreamStartSource``) — only that a word suffices there.
    private func shelf(
        for choice: StartPreferences.PortalChoice, from portal: PortalInfo, slot: Int,
        perShelf: Int
    ) async -> (Int, Catalog, [TileContent])? {
        let name = choice.name.isEmpty ? portal.name : choice.name
        guard let fetched = try? await source.level(zu: choice.identifier, title: name) else {
            Diagnose.hint(.network, "Home: CL-Server folder \(portal.name) · \(name) is not responding")
            return nil
        }
        let level =
            fetched.areFolders
            ? await titleLevel(under: Self.entries(from: fetched.entries)) : fetched
        guard let level, !level.tiles.isEmpty else {
            Diagnose.step(.network, "Home: \(portal.name) · \(name) has no titles")
            return nil
        }

        // **Sorted as in the portal area if an order is chosen there** (check finding A-S9,
        // 2026-09-27) — as on the TV (`HomeModel.portalFolderShelves`). The same shared store
        // (``Core/SortStore``), order first, then cap.
        let identifier = Catalog.Identifier(.portals, .portalLevel, choice.identifier)
        let ordered =
            SortMemory().last(zu: identifier).map {
                XtreamStartSource.ordered(level.tiles, choice: $0)
            } ?? level.tiles
        let tiles = Array(ordered.prefix(perShelf))
        let label =
            choice.name.isEmpty
            ? portal.name : portal.name + DelimiterChars.point + choice.name
        Diagnose.step(
            .network, "Home: portal shelf \(label) with \(tiles.count) titles")
        let catalog = Catalog(
            id: identifier, origin: .portals,
            label: .wording(label), kind: .portalLevel,
            sourceIdentifier: choice.identifier, extent: tiles.count)
        return (slot, catalog, tiles)
    }

    /// Which portal a chosen folder belongs to.
    ///
    /// **Recognised at the start of the identifier, and that is not a guess.** A portal level
    /// is called `portal|Suchbegriff|EntryPoint`; the root of the same portal is the same
    /// identifier with an empty entry. Every identifier of a portal therefore begins with its
    /// root identifier — and the contract supplies that (``PortalContentSource/root(zu:)``), without
    /// this file having to reconstruct the form of the identifier.
    ///
    /// `nil` if the chosen portal is not ready right now.
    private func portal(for folder: String, from portals: [PortalInfo]) -> PortalInfo? {
        guard !folder.isEmpty else { return nil }
        return portals.first { folder.hasPrefix(source.root(zu: $0.id)) }
    }

    // MARK: - Ohne Wahl

    /// The one automatic shelf — **the behavior from before 2026-09-07, unchanged.**
    ///
    /// **Two steps:** the portal used last (``PortalMemory``) and otherwise the first
    /// ready one; in it the recommending entry point, and from there depth-first down to a
    /// title level. Without this branch a freshly set-up device would show nothing from the
    /// portals — nobody has been able to choose anything there yet.
    private func buildAutomatically(
        from readyPortals: [PortalInfo], perShelf: Int
    ) async throws
        -> StartContent
    {
        let remembered = memory.last.flatMap { name in readyPortals.first { $0.id == name } }
        guard let portal = remembered ?? readyPortals.first else {
            // **No shelf instead of an empty one with a message.** That a portal requires a login is
            // information for the Portals tab — on Home it would be a disturbance in an overview that
            // is about something else.
            Diagnose.step(.network, "Home: portals — none ready")
            return Self.empty
        }

        // **The root is a level like any other** (direction K3a, 2026-09-06): what used to be called
        // "entry points" are its entries — each one a door.
        let root = try await source.level(
            zu: source.root(zu: portal.id), title: portal.name)
        let doors = Self.entries(from: root.entries)
        guard !doors.isEmpty else {
            Diagnose.step(.network, "Home: \(portal.name) has no entry points")
            return Self.empty
        }

        guard let found = await titleLevel(under: doors) else {
            Diagnose.step(
                .network, "Home: \(portal.name) — only categories behind the entry points")
            return Self.empty
        }

        let tiles = Array(found.tiles.prefix(perShelf))
        Diagnose.step(
            .network,
            "Home: \(portal.name) · \(found.title) with \(tiles.count) titles")
        return StartContent(
            state: CatalogState.fromAccesses(portals: true), heroes: [],
            tiles: [.fixed("portale"): tiles])
    }

    /// Descends behind the doors until **titles** are there — and not categories again.
    ///
    /// **The finding of 2026-09-07:** until then it went exactly one level deep and took
    /// `fetched.tiles` unchecked. At Serieshub there is a menu again behind "Beliebte
    /// Serien", and so the shelf contained image-less tiles with "NEUE STAFFELN DIESE WOCHE",
    /// "MEISTGESEHEN GERADE" and "ABENTEUER" — category names as titles.
    /// ``PortalLayer/areFolders`` has answered the question for a long time and was never
    /// asked here.
    ///
    /// **First into the depth, then into the breadth.** Anyone who finds a menu behind
    /// "Beliebte Serien" wants to keep searching there — and not first work through the other
    /// categories of the root. The folders found therefore go to the front of the stack.
    ///
    /// **What is capped is the number of requests and not the depth** (``maxFetches``):
    /// what the line pays for is the requests, and a depth limit alone lets a broad level
    /// become arbitrarily expensive.
    private func titleLevel(under doors: [PortalEntry]) async -> PortalLayer? {
        var pending = Array(doors.prefix(Self.maxWidth))
        var fetches = 0
        while !pending.isEmpty, fetches < Self.maxFetches {
            let door = pending.removeFirst()
            guard let identifier = door.leadsDeeper else { continue }
            fetches += 1
            guard let level = try? await source.level(zu: identifier, title: door.title) else {
                continue
            }
            guard level.areFolders else {
                if !level.tiles.isEmpty { return level }
                continue
            }
            pending.insert(
                contentsOf: Self.entries(from: level.entries).prefix(Self.maxWidth),
                at: 0)
        }
        return nil
    }

    /// The doors of a level in the order in which they are tried.
    ///
    /// **Only doors.** A separator among them would be an entry point that cannot be opened.
    ///
    /// **Recommending first, listing afterwards — and none drops out.** A portal's menu is
    /// ordered: what the portal considers worth watching is at the front ("New Episodes",
    /// "Popular Series"). "All Series" is a directory and answers this shelf's question worse,
    /// but it does answer it — placed at the back instead of filtered out, because a
    /// directory full of titles is better than a shelf that does not appear.
    ///
    /// **Recognised by name, because the contract offers nothing else.** `EntryPoint` carries a
    /// group (`catalog` versus `kuratiert`), but it does not get as far as here; until it
    /// does, the name is the best information available.
    ///
    /// **The chosen door is no longer pulled forward here** (2026-09-07): a choice is now fetched
    /// instead of searched for (``shelf(for:from:slot:perShelf:)``), and this path only runs
    /// when nothing at all is chosen.
    static func entries(from entries: [PortalEntry]) -> [PortalEntry] {
        let words = ["neu", "beliebt", "empfehl", "trend", "simulcast", "aktuell"]
        let doors = entries.filter { $0.leadsDeeper != nil }
        func recommends(_ door: PortalEntry) -> Bool {
            let name = door.title.lowercased()
            return words.contains { name.contains($0) }
        }
        return doors.filter(recommends) + doors.filter { !recommends($0) }
    }

    private static let empty = StartContent(state: .empty, heroes: [], tiles: [:])
}
