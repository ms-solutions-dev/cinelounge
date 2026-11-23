/// "What this source can do on the go" — one sentence of its own per source.
///
/// **Never a shared sentence for all.** Exactly one of the three sources hangs on the
/// tunnel, and that one is the only one that can lower the resolution. A shared message
/// "slow connection" would be simply wrong for two of three sources — and too vague for
/// the third to do anything with.
///
/// The sentences are in the string catalog and come verbatim from `entwuerfe/prototyp.html`.
public enum LocationStatement {

    /// Where the line stands.
    public enum Place: String, CaseIterable, Sendable {
        case library = "bibliothek"
        case live
        case portals = "portale"
        case search = "suche"
        /// In the sources sheet, where "Automatic" has to be explained.
        case sourceSheet = "quellblatt"
    }

    /// Which catalog is currently shown.
    public enum Source: String, CaseIterable, Sendable {
        case jellyfin
        case xtream
        case portals = "portale"
    }

    /// Whether the home network is directly reachable.
    ///
    /// **Not derivable from the network path.** Whether one is "at home" is decided not by
    /// whether Wi-Fi is present but by whether the media server answers without a tunnel — a
    /// foreign Wi-Fi is also Wi-Fi. This information therefore comes from where the server is
    /// checked, and not from the ``NetworkWatch``.
    public enum Location: String, Sendable {
        case home = "daheim"
        case inFlight = "unterwegs"

        /// **Not yet decided — and then the line is silent.**
        ///
        /// Until 2026-09-10 this case did not exist, and so `location: .home` stood hard-coded at
        /// three places: Live, portals, search claimed "at home" without anything having checked
        /// it. Whoever was on the go read a statement about their network that came from a line of
        /// code.
        ///
        /// **A missing line is better than a wrong one.** The viewer notices that nothing is
        /// there; a wrong location line is only noticed after it has been believed.
        case unknown = "unbekannt"
    }

    /// A sentence and whether it is shown as a warning.
    public struct Statement: Sendable, Equatable {
        public let key: String
        /// Framed and with a golden symbol — for the two places where something really is
        /// different on the go.
        public let warning: Bool

        init(_ key: String, warning: Bool = false) {
            self.key = key
            self.warning = warning
        }
    }

    /// The sentence for this place.
    ///
    /// - Parameters:
    ///   - place: where the line stands
    ///   - location: whether the home network is directly reachable
    ///   - source: which catalog is shown (relevant only in the library)
    ///   - tvOccupied: whether the Apple TV holds the one permitted connection
    ///   - childAccount: for search — listing the three catalogs that a child may not
    ///     see would be exactly the contradiction that the search below avoids
    public static func forItem(
        _ place: Place,
        location: Location,
        source: Source = .jellyfin,
        tvOccupied: Bool = false,
        childAccount: Bool = false
    ) -> Statement? {
        // **Without a location no location line.** Every statement in this file starts with "at
        // home or on the go"; without the answer there would only be the choice between two
        // claims. The caller then draws nothing — see ``Location/unknown``.
        guard location != .unknown else { return nil }
        let route = location == .inFlight

        switch place {
        case .library:
            switch (source, route) {
            case (.jellyfin, false): return Statement("place.library.jellyfin.home")
            case (.jellyfin, true): return Statement("place.library.jellyfin.away", warning: true)
            case (.xtream, false), (.portals, false): return Statement("place.library.xtream.home")
            case (.xtream, true), (.portals, true): return Statement("place.library.xtream.away")
            }

        case .live:
            switch (route, tvOccupied) {
            case (false, false): return Statement("place.live.home")
            case (false, true): return Statement("place.live.home.busy")
            case (true, false): return Statement("place.live.away")
            case (true, true): return Statement("place.live.away.busy")
            }

        case .portals:
            return Statement(route ? "place.portals.away" : "place.portals.home")

        case .search:
            if childAccount { return Statement("place.search.child") }
            return Statement(route ? "place.search.away" : "place.search.home")

        case .sourceSheet:
            return route
                ? Statement("place.sources.away", warning: true)
                : Statement("place.sources.home")
        }
    }
}
