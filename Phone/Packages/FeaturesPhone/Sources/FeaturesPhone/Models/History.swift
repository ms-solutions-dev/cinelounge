import Core
import Flows
import Foundation

/// What was played last — **one store instead of three.**
///
/// **Today two places remember something, and neither of them is a history.** `LiveMemory`
/// remembers the channel per list, `VODMemory` the category per provider; both are **places**
/// ("where was I"), and neither answers the question the Home screen is about: **what did I
/// watch last.**
///
/// **An entry carries its origin.** Without it there would be no telling which expiry rule
/// applies, or whether the source still exists at all — and both decide whether a tile is a
/// path or a dead end.
public struct HistoryEntry: Sendable, Equatable, Identifiable {

    public let identifier: String
    public let origin: Catalog.Origin
    public let title: String
    public let beside: String?
    public let image: URL?

    /// The background image, 16 : 9 — **so the header area can show it.**
    ///
    /// Without this field the first rung of the ladder (``HeroLadder``) would be a rule with
    /// no effect: the box is ninety percent image, and a landscape-format poster is either
    /// distorted or cropped to a section in which there is usually nothing.
    /// Whoever writes the entry has the title in hand and knows it — fetching it again
    /// would be a request for something we already had.
    public let backdrop: URL?

    /// The synopsis, for the same purpose.
    public let description: String?

    /// How far along one is, 0 to 1. A channel has none.
    public let progress: Double?
    public let timestamp: Date

    /// **Origin and identifier together.** Two services can assign the same number; a
    /// history that mixes them up leads to the wrong title.
    public var id: String { "\(origin.rawValue):\(identifier)" }

    /// Which series the played episode belongs to — see ``PlaybackJob/series``.
    ///
    /// **A latecomer in the stored catalog, and that is fine.** Entries from
    /// earlier do not carry it; as an `Optional` it reads as `nil`, and the
    /// tile leads to the episode as before. Whoever plays the title again once has it.
    public let series: String?

    /// Whether the image is **landscape** — `nil` means: unknown.
    ///
    /// **The second place where the format note got lost** (2026-09-08). "Continue Watching"
    /// builds its tiles from the history and not from the source; the mapping here dropped
    /// the field, and so a landscape poster stood in the portrait frame there too
    /// — even after the portal layer already did it right.
    public let wide: Bool?

    /// What parental controls need to know about this title — `nil` means **unknown.**
    ///
    /// **Since 2026-09-26** (AP58, finding K4). Until then an entry carried no rating,
    /// and the Continue Watching of a child profile showed what an adult had started on the
    /// same phone. Earlier entries carry none and count as locked in child mode
    /// (``ParentalControls/ProtectionRule/shows(history:)``).
    public let approval: HistoryClearance?

    public init(
        identifier: String, origin: Catalog.Origin, title: String, beside: String? = nil,
        image: URL? = nil, backdrop: URL? = nil, description: String? = nil,
        progress: Double? = nil, timestamp: Date = .now, series: String? = nil,
        wide: Bool? = nil, approval: HistoryClearance? = nil
    ) {
        self.approval = approval
        self.identifier = identifier
        self.origin = origin
        self.title = title
        self.beside = beside
        self.image = image
        self.backdrop = backdrop
        self.description = description
        self.progress = progress
        self.timestamp = timestamp
        self.series = series
        self.wide = wide
    }

    public var tile: TileContent {
        var tile = TileContent(
            id: identifier, title: title, beside: beside, image: image, backdrop: backdrop,
            progress: progress, series: series, wide: wide)
        tile.recent = timestamp
        return tile
    }

    /// As a header — **only with a background image.**
    ///
    /// `nil` means: this entry is fine for the shelf, but not for the box. The same
    /// rule as in ``HeroSelection``, and for the same reason: without an image an empty
    /// area would remain, and when paging it would look like a loading error.
    public var held: HeroContent? {
        guard backdrop != nil else { return nil }
        return HeroContent(tile: tile, description: description)
    }
}

/// The rating of a history entry — **the same fields as for a download**
/// (`DownloadDescription`), so the filter can take the same path.
public struct HistoryClearance: Sendable, Equatable, Codable {
    /// Stored keys keep their original (German) names — renaming them would
    /// make data written by earlier versions unreadable (AP85 B4).
    private enum CodingKeys: String, CodingKey {
        case ageRating = "altersfreigabe"
        case series = "serie"
        case seriesClearance = "serienfreigabe"
        case seriesClearanceChecked = "serienfreigabeGeprueft"
    }

    /// The rating of the title itself; for an episode without its own, that of the series.
    public var ageRating: String?
    /// The identifier of the series the title belongs to — `nil` for everything else.
    public var series: String?
    /// The rating of the series, when the episode carries its own.
    public var seriesClearance: String?
    /// Whether the rating of the series was looked up.
    public var seriesClearanceChecked: Bool?

    public init(
        ageRating: String? = nil, series: String? = nil, seriesClearance: String? = nil,
        seriesClearanceChecked: Bool? = nil
    ) {
        self.ageRating = ageRating
        self.series = series
        self.seriesClearance = seriesClearance
        self.seriesClearanceChecked = seriesClearanceChecked
    }

    /// From a title of the source — **the series only if it really belongs to one.**
    public init(_ title: MediaItem) {
        self.init(
            ageRating: title.ageRating,
            series: title.belongsToSeries ? title.seriesID : nil,
            seriesClearance: title.seriesClearance,
            seriesClearanceChecked: title.seriesClearanceChecked)
    }
}

/// The history across **all** sources.
///
/// **Writing happens on playback and nowhere else.** The finding of 2026-09-02 in the
/// TV program stands as a warning for this: the channel memory was written at **four**
/// places, all four lay **before** the player — and whoever switched inside the player
/// passed none of them. The history therefore has exactly one
/// write point, and a test suite enforces that.
///
/// **As long as there is no player (AP14), nobody writes.** That is not a defect
/// but the rule in its strictest form: a history that the library filled on
/// opening would not be a history but a click counter.
public struct History: Sendable, Equatable {

    public private(set) var entries: [HistoryEntry]

    public init(_ entries: [HistoryEntry] = []) {
        self.entries = entries
    }

    /// This many remain.
    ///
    /// Twenty, because the shelf holds twenty tiles. Keeping more would mean storing
    /// something that no view ever shows.
    public static let atMost = 20

    /// Adds an entry — **and replaces the one with the same identifier.**
    ///
    /// **Only the latest one per title and per channel.** Without this rule an evening of zapping fills
    /// the whole shelf, and the series in progress sits at position twelve. The same rule
    /// applies to a film one starts three times.
    public mutating func note(_ new: HistoryEntry) {
        entries.removeAll { $0.id == new.id }
        entries.insert(new, at: 0)
        if entries.count > Self.atMost {
            entries = Array(entries.prefix(Self.atMost))
        }
    }

    /// Removes a title from the history — **locally, without asking anyone.**
    ///
    /// **The finding of 2026-09-07, from the client:** *On the TV, long-pressing an item in
    /// Continue Watching lets me mark it as seen so it no longer shows up there;
    /// I would like the same on the phone.*
    ///
    /// **A seen mark alone is not enough on the phone.** On the TV the server fills
    /// the strip (`resumable`), and a mark there takes the title out. Until
    /// 2026-09-29 this history stood in front of it **in addition**; since then the
    /// phone builds the row like the TV, solely from the sources
    /// (``StartModel/ordered(_:)``). The handle stays for the places that still read the
    /// history.
    ///
    /// **And for a portal it is the only way.** The bridge does keep a position,
    /// but it keeps no list of "what I watched last" — that one is built here.
    ///
    /// - Parameter kennung: the title identifier. Together with the origin it is the
    ///   identifier of the entry; two services can assign the same number.
    public mutating func remove(_ identifier: String, origin: Catalog.Origin) {
        let id = "\(origin.rawValue):\(identifier)"
        entries.removeAll { $0.id == id }
    }

    /// What still applies — **expired and orphaned entries drop out.**
    ///
    /// * **Live expires, recorded content does not.** A channel from the day before yesterday is not
    ///   "continue watching"; a film that one watched half of two weeks ago very
    ///   much is. A channel keeps running whether one watches or not — what one saw yesterday
    ///   no longer exists today.
    /// * **An entry disappears with its source.** If the portal is switched off or
    ///   the channel list deleted, the tile is a button that leads to an error message
    ///   — worse than no tile.
    /// * **And for the portals the individual portal counts, not the origin** (finding
    ///   of 2026-09-07, on the device). Until then only `state.hasKey(.portals)` stood here: as long as
    ///   **any** portal answered, every portal entry counted — a switched-off
    ///   flatone stayed in "Continue Watching" with its titles. See
    ///   ``PortalPreferences``.
    ///
    /// - Parameter portale: The portals that count here — ready **and** not moved into their
    ///   own area. **`nil` means "nobody asked"** and filters
    ///   nothing: a caller without portal knowledge must not accidentally delete every
    ///   portal entry. An **empty set**, by contrast, explicitly means "none",
    ///   and that is the state without a bridge.
    public func validOnes(
        at state: CatalogState, portals allowed: Set<String>? = nil, now: Date = .now
    ) -> [HistoryEntry] {
        entries.filter { entry in
            guard state.hasKey(entry.origin) else { return false }
            if entry.origin == .portals, let allowed {
                // **An identifier without a readable portal stays.** It comes from a
                // state that this version does not know; throwing it out would be a
                // statement that nobody has substantiated — the same rule as for an
                // unknown origin in ``HistoryStore``.
                guard let portal = PortalPreferences.portal(zu: entry.identifier) else { return true }
                guard allowed.contains(portal) else { return false }
            }
            guard entry.origin == .channelList else { return true }
            return now.timeIntervalSince(entry.timestamp) < Self.liveValidity
        }
    }

    /// How long a channel entry applies: **six hours** — ``Flows/ChannelHistory/applies``,
    /// the same period with which the TV has also put recently watched channels
    /// into "Continue Watching" since 2026-09-26 (C5).
    ///
    /// Long enough for an evening, short enough to be gone the next morning. A
    /// figure like "until midnight" would be the wrong one for someone still watching at one.
    public static let liveValidity: TimeInterval = ChannelHistory.applies
}
