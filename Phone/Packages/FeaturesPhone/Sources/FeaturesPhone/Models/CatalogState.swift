import Foundation
import ParentalControls

/// What is set up — **a list of catalogs, not three questions.**
///
/// **The successor of `Aufenthalt`.** Three yes-or-no questions were progress compared
/// with four fixed cases and compared with reality still an enumeration: They can represent
/// eight states, but not six libraries. A list can do both — the bits can be read off it
/// (``hasKey(_:)``), not the other way round.
///
/// **"Set up" now means "there is content", not "there is an access".** A media server
/// with zero released libraries is set up and still empty; before, it would have produced
/// a library tab over nothing — exactly the error that finished the first version.
public struct CatalogState: Sendable, Equatable {

    /// **In the order in which the service names them** — and explicitly not sorted by
    /// identifier.
    ///
    /// **The finding of 2026-09-05, seen on the screen.** A first version sorted by the composed
    /// identifier, because that looked deterministic. That tied the order to the genre name and
    /// to a GUID: "Collections" and "Folders" both carry the genre `unknown` (the shared
    /// `Library.Kind` knows neither `boxsets` nor `folders`), and which of the two slipped into
    /// the four shelves was decided by a random string. On this server it was "Folders" with
    /// zero titles — the shelf stayed empty, dropped out under the rule "an empty shelf does
    /// not appear", and the sixteen collections were **nowhere to be seen**.
    ///
    /// The server's order, by contrast, is not randomness but information: In Jellyfin the user
    /// orders their libraries themselves. Whoever reorders them says what matters to them —
    /// and exactly that decides which four get a shelf.
    ///
    /// **What must be deterministic stays deterministic anyway:** Which *tabs* appear depends
    /// only on the origins and thus on a set. The bar therefore cannot change because one
    /// service answered faster.
    public let catalogs: [Catalog]

    public init(_ catalogs: [Catalog]) {
        self.catalogs = catalogs.filter(\.hasContent)
    }

    public static let empty = CatalogState([])

    public var origins: Set<Catalog.Origin> { Set(catalogs.map(\.origin)) }

    /// Whether this state carries an origin.
    ///
    /// **The build type is asked first** (2026-09-07, ROADMAP A1): An origin that does not exist
    /// in this build at all should not get a tab even when a catalog from earlier still lies in
    /// the Keychain. See ``SourceSwitch``.
    public func hasKey(_ origin: Catalog.Origin) -> Bool {
        SourceSwitch.hasKey(origin) && origins.contains(origin)
    }

    public var isSetUp: Bool { !catalogs.isEmpty }

    /// The catalogs of an origin, in their order.
    public func catalogs(from origin: Catalog.Origin) -> [Catalog] {
        catalogs.filter { $0.origin == origin }
    }

    /// Which tabs this state shows.
    ///
    /// **Not dimmed, but gone:** A dimmed tab is an invitation, and the answer to it would be
    /// the same every time.
    ///
    /// **The library stays one tab**, whether a media server, a channel list or only the
    /// downloads stand behind it. Splitting it into "Films" and "Series" as soon as there is
    /// room was the rejected way: The same place would then be named differently for two
    /// viewers — and it would **lose** what it does not name. With six libraries that would be
    /// four.
    public var tabs: [Tab] { tabs(isInChildMode: false) }

    /// The same question, **offset against parental controls.**
    ///
    /// **In kids mode Live and portals disappear — not dimmed, but gone.** A dimmed tab is an
    /// invitation: It says "there is something here that you may not". The reason is not
    /// strictness but the absence of any basis — 7.746 channels without an age rating, and a
    /// portal catalog is read off, not licensed. There is nothing at which a limit could sit.
    ///
    /// **The rule stands in the package and not here** (``TabScope``): Search and the
    /// catalog selection ask the same question, and three places with the same rule would be
    /// three opportunities to answer it differently.
    ///
    /// **The scope comes last and not first.** Whether the favorites stand at the bottom
    /// depends on how many services are set up — not on how many of them a child may see.
    /// Otherwise the heart would move from the header to the bottom when a switch is flipped,
    /// and the screen would look different twice for the same device.
    public func tabs(
        isInChildMode childMode: Bool, deselected: Set<String> = []
    )
        -> [Tab]
    {
        tabs(isInChildMode: childMode, deselected: deselected, channelApproval: ChannelApproval())
    }

    /// The same question **with the allow list for channels** (tvOS roadmap AP52, decision 14):
    /// Live stays in kids mode when the list allows something —
    /// ``ParentalControls/TabScope/remains(_:isInChildMode:deselected:channelApproval:)``.
    ///
    /// **Without a default for the list**, unlike the question above: Whoever knows the list
    /// should not be able to forget it. The question without a list stays for the places that
    /// explicitly show the strictest case.
    public func tabs(
        isInChildMode childMode: Bool, deselected: Set<String>, channelApproval: ChannelApproval
    ) -> [Tab] {
        shownTabs.filter {
            TabScope.remains(
                $0.rawValue, isInChildMode: childMode, deselected: deselected,
                channelApproval: channelApproval)
        }
    }

    private var shownTabs: [Tab] {
        guard isSetUp else { return [] }
        var shown: [Tab] = [.start]
        if hasKey(.jellyfin) || hasKey(.provider) || hasKey(.downloads) {
            shown.append(.library)
        }
        if hasKey(.channelList) { shown.append(.live) }
        if hasKey(.portals) { shown.append(.portals) }
        // **The favorites move.** If a place remains free after the services, they stand at the
        // bottom; otherwise as a heart in the header. They are the only place that fits every
        // setup **and** can also be shown at the top without loss — every other would either be
        // tied to a service or be filler.
        if shown.count < Tab.atMost - 1 { shown.append(.favorites) }
        shown.append(.search)
        return shown
    }

    /// Whether the favorites stand at the bottom — otherwise they belong in the header.
    public var favoritesAtBottom: Bool { tabs.contains(.favorites) }

    /// Whether a view is reachable in this state.
    public func reached(
        _ view: ViewID, isInChildMode childMode: Bool = false
    )
        -> Bool
    {
        reached(view, isInChildMode: childMode, channelApproval: ChannelApproval())
    }

    /// The same question with the allow list for channels — see
    /// ``tabs(isInChildMode:deselected:channelApproval:)``.
    public func reached(
        _ view: ViewID, isInChildMode childMode: Bool,
        channelApproval: ChannelApproval
    ) -> Bool {
        guard let tabs = view.tabs else { return true }
        return self.tabs(
            isInChildMode: childMode, deselected: [], channelApproval: channelApproval
        ).contains(tabs)
    }
}

extension CatalogState {

    /// Builds a state from what the environment provides — **until AP21.**
    ///
    /// Collective catalogs instead of real ones: As long as there is no setup, nobody knows
    /// which libraries lie behind an access. The media server brings its own only after it has
    /// answered; until then a placeholder stands so that the bar does not stay empty while
    /// loading.
    public static func fromAccesses(
        jellyfin: Bool = false, channelList: Bool = false, portals: Bool = false,
        downloads: Bool = false, provider: Bool = false
    ) -> CatalogState {
        var collected: [Catalog] = []
        if provider {
            collected.append(
                Catalog(
                    id: .init(.provider, .movies, "alle"), origin: .provider,
                    label: .key("tab.movies"), kind: .movies,
                    sourceIdentifier: ""))
        }
        if jellyfin {
            collected.append(
                Catalog(
                    id: .init(.jellyfin, .unknown, "alle"), origin: .jellyfin,
                    label: .key("stock.mediaServer"), kind: .unknown,
                    sourceIdentifier: ""))
        }
        if channelList {
            collected.append(
                Catalog(
                    id: .init(.channelList, .live, "alle"), origin: .channelList,
                    label: .key("tab.live"), kind: .live,
                    sourceIdentifier: ""))
        }
        if portals {
            collected.append(
                Catalog(
                    id: .init(.portals, .portalLevel, "alle"), origin: .portals,
                    label: .key("tab.portals"), kind: .portalLevel,
                    sourceIdentifier: ""))
        }
        if downloads {
            collected.append(
                Catalog(
                    id: .init(.downloads, .unknown, "alle"), origin: .downloads,
                    label: .key("stock.offline"), kind: .unknown,
                    sourceIdentifier: ""))
        }
        return CatalogState(collected)
    }
}

extension CatalogState {

    /// All sixteen access combinations — for tests and for the rehearsal.
    ///
    /// **Not all possible states**, with n libraries there are infinitely many. This list
    /// covers the question of which tabs appear; for shelves and completeness `Lagenprobe`
    /// additionally checks with real library counts.
    public static var allCases: [CatalogState] {
        [false, true].flatMap { server in
            [false, true].flatMap { list in
                [false, true].flatMap { portal in
                    [false, true].map {
                        .fromAccesses(
                            jellyfin: server, channelList: list, portals: portal,
                            downloads: $0)
                    }
                }
            }
        }
    }
}
