import Core
import Diagnose
import Flows
import Foundation
import PlaylistKit

/// What is running right now — as a shelf on Home.
///
/// **Perishable goods, and that is why it sits at the top.** A channel that shows
/// something now is a different one in two hours; the shelf answers "what is on right now"
/// and nothing else. Further down it would be worthless.
///
/// **From the stored data and without a single request.** The channel list is on disk, the
/// program too — the Live area fetches both when you open it. Home must not go onto the
/// network for that: it is the first screen, and what holds it up holds up the whole app.
/// If nothing has been fetched yet, the shelf stays empty and disappears under the rule
/// "an empty shelf does not appear".
///
/// **Unless someone has stayed silent** — then it stays and says who. See ``disruption(_:)``.
///
/// **Vertical, and the draft was right** (objection W2, decided on 2026-09-06). It draws three
/// channel rows here "as wide as the shelf"; what was built was an ordinary shelf of
/// tiles, with the principle "Home has **one** grammar". The principle is right and the
/// conclusion was wrong: at 200 points you ended up with a logo and **not a word** about
/// what is on — so exactly the information this shelf exists for was missing. What is
/// drawn now is ``LiveShelfRow``.
///
/// **Which channels stand here is determined by the viewer** (`Presentation → Startseite`).
/// Without a choice of their own, the **most recently watched** ones that are showing
/// something right now are there — the product owner's requirement of 2026-09-06. The list for
/// that lives in the ``ChannelHistory``. Only if that is empty too does the old rule apply:
/// the first ones with something running.
public struct TodayLive: StartSource {

    private let source: any ChannelListingSource
    private let width: Int
    private let preferences: @Sendable () -> StartPreferences
    private let history: ChannelHistory

    /// This many channels go into the shelf — ``Core/LiveShelfChoice/atMost``, the same
    /// number as on the TV.
    public static let atMost = LiveShelfChoice.atMost

    public init(
        source: any ChannelListingSource, width: Int,
        preferences: (@Sendable () -> StartPreferences)? = nil,
        history: ChannelHistory = ChannelHistory()
    ) {
        self.source = source
        self.width = width
        self.preferences = preferences ?? { .preset }
        self.history = history
    }

    public func home(perShelf: Int) async throws -> StartContent {
        let catalog = await source.channels()
        guard !catalog.channels.isEmpty else {
            return Self.disruption(catalog.silent)
        }

        // **The same settings as in the Live tab.** Before, the factory setting was used here: on
        // Home that made channels appear from groups that were hidden in the Live tab — the same
        // app with two opinions about what is visible.
        // **The preferences of the person, not those of the device** (2026-09-29) — as on the TV.
        // On the iPad other groups were hidden, and a channel that the TV showed was missing
        // there. Via ``Core/ProfileStore`` they travel with the profile.
        let visibility = LivePreferences.load(from: ProfileStore.playback)
        let isVisible = visibility.isVisible(catalog.channels)
        let chosen = preferences().liveChannel
        let ordered = Self.order(from: isVisible, chosen: chosen, recent: history.names)

        // **Order first, then cut off** — see ``Core/LiveShelfChoice/programmeFor``.
        let programs = await source.program(
            forItem: Array(ordered.prefix(LiveShelfChoice.programmeFor)))

        let now = Date()
        let tiles = LiveShelfChoice.selection(
            ordered, chosen: chosen, atMost: min(perShelf, Self.atMost)
        ) { channelList in
            programs[channelList.id]?.first(where: { $0.isRunning(at: now) })
        }
        .map { entry in
            entry.isRunning.map { Self.tile(entry.channels, isRunning: $0, now: now) }
                ?? Self.tile(entry.channels)
        }

        // **The most recently watched channels also in "Continue Watching"** (2026-09-28) — as on
        // the TV (`MainView.recentChannels`): only those of the last few hours, one tile per
        // station, with the time. Since then the history travels via the cloud.
        let next = Self.continueWatching(
            isVisible: isVisible, history: history, programs: programs, now: now)

        guard !tiles.isEmpty else {
            Diagnose.step(
                .network,
                "Home: Today live — \(isVisible.count) channels, "
                    + "\(programs.count) with program, \(chosen.count) chosen, none running")
            guard !next.isEmpty else { return Self.empty }
            return StartContent(
                state: CatalogState.fromAccesses(channelList: true), heroes: [],
                tiles: [.fixed(ShelfIdentifier.continueWatching): next])
        }
        Diagnose.step(.network, "Home: Today live with \(tiles.count) channels")
        var all: [Shelf.Identifier: [TileContent]] = [.fixed("live"): tiles]
        if !next.isEmpty { all[.fixed(ShelfIdentifier.continueWatching)] = next }
        return StartContent(
            state: CatalogState.fromAccesses(channelList: true), heroes: [], tiles: all)
    }

    /// The channels for "Continue Watching" — **the same rule as on the TV.**
    static func continueWatching(
        isVisible: [Channel], history: ChannelHistory, programs: [String: [Programme]], now: Date
    ) -> [TileContent] {
        let when = Dictionary(
            history.entries.compactMap { e in e.timestamp.map { (e.name, $0) } },
            uniquingKeysWith: { first, _ in first })
        let perName = Dictionary(
            isVisible.map { ($0.channelName, $0) }, uniquingKeysWith: { first, _ in first })
        let channels = ChannelVariants.perStation(history.recentlyUsed(now: now).compactMap { perName[$0] })
        return channels.map { channelList in
            var tile =
                programs[channelList.id]?.first(where: { $0.isRunning(at: now) })
                .map { tile(channelList, isRunning: $0, now: now) } ?? tile(channelList)
            tile.recent = when[channelList.channelName]
            return tile
        }
    }

    /// Which channels go into the shelf — **the rule is in
    /// ``Core/LiveShelfChoice/order(from:chosen:recent:)``** (AP58 R5, finding L3) and
    /// applies on the TV in exactly the same way: a choice or a default, never both; one name,
    /// one channel; without a choice first the most recently watched (``ChannelHistory``), then
    /// the favorites, then the rest.
    static func order(
        from channelList: [Channel], chosen: [String], recent: [String]
    ) -> [Channel] {
        LiveShelfChoice.order(from: channelList, chosen: chosen, recent: recent)
    }

    /// A channel tile: the channel on top, the show below.
    ///
    /// **The channel name is the title, not the show.** Anyone who reads "Friopliolian" does
    /// not yet know what they are pressing on; anyone who reads "Das Nordlicht" does. The show
    /// appears as a secondary line — it says whether it is worth it right now.
    /// The same tile without a show — for a chosen channel whose program the provider does not
    /// carry.
    ///
    /// **No invented secondary line.** A "running now" without program data would be a claim;
    /// the empty space tells the truth, and the channel name alone is enough to tap it.
    static func tile(_ channelList: Channel) -> TileContent {
        TileContent(
            id: channelList.id, title: ChannelDisplayName(channelList.name).name, image: channelList.logoURL)
    }

    static func tile(_ channelList: Channel, isRunning: Programme, now: Date) -> TileContent {
        TileContent(
            id: channelList.id,
            title: ChannelDisplayName(channelList.name).name,
            beside: isRunning.title,
            image: channelList.logoURL,
            progress: LiveModel.progress(isRunning, um: now),
            // **The end and not the remaining time** — see ``TileContent/runsUntil``.
            runsUntil: isRunning.end)
    }

    /// The empty store — **two different pieces of information, and until 2026-09-07 the same
    /// one.**
    ///
    /// ``ChannelCatalog/silent`` carries the lists that did not respond. The Live tab has
    /// distinguished by it since 2026-09-06. (``LiveModel/load()``); here there was still a single
    /// sentence — "no channels in the store" —, and because that leaves no catalog with the
    /// origin channel list in a position to qualify, the shelf was not even created
    /// (``FixedShelf/shelves(forItem:)``). An account that is just not responding at the moment
    /// looked exactly like one that never existed: **not there at all.**
    ///
    /// **With an empty `silent` it stays with the quiet disappearance**, and that is not an
    /// oversight: a still-empty store is the documented normal case of this shelf — the Live
    /// area fills it as soon as you open it.
    ///
    /// **The same state as in the tab** and not one of its own: ``PlaybackPhase/networkXtream`` is
    /// already "the provider does not respond", and a second version of the same cause would
    /// be the one that stays when the first changes.
    private static func disruption(_ silent: [String]) -> StartContent {
        guard !silent.isEmpty else {
            Diagnose.step(.network, "Home: Today live — no channel list fetched yet")
            return empty
        }
        Diagnose.step(
            .network,
            "Home: Today live — \(silent.count) list(s) without response: "
                + silent.joined(separator: DelimiterChars.point))
        return StartContent(
            state: CatalogState.fromAccesses(channelList: true), heroes: [], tiles: [:],
            disruptions: [.fixed("live"): ShelfDisruption(state: .networkXtream, names: silent)])
    }

    private static let empty = StartContent(state: .empty, heroes: [], tiles: [:])
}
