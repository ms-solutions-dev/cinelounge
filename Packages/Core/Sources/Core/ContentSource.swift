import Foundation

/// Where content comes from.
///
/// The first of the two load-bearing abstractions: every source delivers the same
/// models, and the UI does not distinguish whether a title comes from Jellyfin
/// or a channel from a channel list. Another source therefore costs
/// a new implementation of this contract instead of a rebuild.
public protocol ContentSource: Sendable {

    /// For display in settings — with several sources it must
    /// be recognisable which one is meant.
    var displayName: String { get }

    /// Whether this source can deliver a stream **from a desired position**.
    ///
    /// **A property of the source, not of the file — and that is why it lives here.**
    /// A media server can begin further ahead when repackaging; an
    /// IPTV provider delivers its films as finished files and knows no
    /// start point. Whoever does not distinguish this demands a delivery path from a source
    /// that it does not have: the address would carry a start point, the provider
    /// would ignore it, and the film would begin from the start — without an error, without a hint, and
    /// indistinguishable from a failed seek.
    ///
    /// Where it does not work, the player seeks itself. That is the path files take over
    /// HTTP anyway, as long as they answer range requests — for the films of the
    /// checked provider that is the case.
    ///
    /// **Explicitly `nonisolated`.** The value is already fixed before anything
    /// is fetched — it depends on the nature of the source, not its state. If
    /// it were bound to the actor, the decision about the delivery path would have to wait
    /// for it, although there is nothing to wait for.
    nonisolated var canStartAtOffset: Bool { get }

    /// Whether this source keeps its viewer's progress **itself**.
    ///
    /// **The question ``PlaylistKit/StateSource`` asks** (AP42, 2026-09-21). A
    /// media server keeps it: what has been watched and where someone stopped is known to
    /// Jellyfin, and that has to stay so — otherwise two truths would drift apart as soon as
    /// someone watches something on the phone or in the web UI. For the portals the
    /// bridge holds it. An Xtream panel, on the other hand, knows no user state; for its titles
    /// the app keeps it, per person in the ``Core/StillLedger``.
    ///
    /// **Explicitly `nonisolated`**, for the same reason as ``canStartAtOffset``: the
    /// value depends on the nature of the source and not on its state. The wrapper
    /// uses it at build time to decide whether it has anything to do at all.
    ///
    /// **And without a default**, for the same reason as with ``listChanges()``: a convenient
    /// default there once cut the wire of the source that actually reports.
    /// Here the damage would be the same in the other direction — a default `false` would let
    /// a forgotten source keep its server state twice, a default `true` would take
    /// a new source's state away entirely. Whoever writes a source answers the question.
    nonisolated var tracksStateItself: Bool { get }

    func libraries() async throws -> [Library]
    func items(in library: Library.ID, filter: ItemFilter) async throws -> [MediaItem]

    /// How many titles a library holds — **without fetching them.**
    ///
    /// The server includes the total with every list request; until now it was
    /// thrown away. It is needed where a catalog is **named** instead of shown:
    /// in the phone's index, each library's count is shown after its name, and without
    /// it you would have to open each one to know whether it is worthwhile.
    ///
    /// - Returns: `nil` if the source cannot say. That is not an error —
    ///   a channel list does not know a total per genre without loading it.
    func itemCount(in library: Library.ID, filter: ItemFilter) async throws -> Int?
    func item(id: String) async throws -> MediaItem
    func children(of itemID: String) async throws -> [MediaItem]

    /// Started titles, across all libraries.
    func resumable(limit: Int) async throws -> [MediaItem]

    /// This source's collections — series, box sets, whatever the service calls them.
    ///
    /// **Here and not as a special path to the media server** (AP29, 2026-09-11). Until then
    /// Home called it directly on ``JellyfinKit/JellyfinSource``, and so
    /// a view that is supposed to show all catalogs depended on exactly one implementation. Whoever
    /// holds no collections delivers none — that is not an error but the rule.
    func collections() async throws -> [MediaItem]

    func segments(for itemID: String) async throws -> [MediaSegment]
    func streamURL(for itemID: String, decision: PlaybackDecision) async throws -> URL

    /// Reports the position back so that "Continue Watching" is right on all devices.
    ///
    /// `isPaused` has to be reported too and is no extra: the server shows in
    /// its web UI which device is currently playing something. Whoever does not
    /// report pausing keeps showing there as "playing" — and whoever checks in the
    /// living room why the picture is frozen finds no explanation there.
    func report(progress: PlaybackProgress, for itemID: String, isPaused: Bool) async throws

    /// Sets or clears the watched mark.
    ///
    /// **Belongs to the server and not the app.** The mark decides what appears under
    /// "Continue Watching" and what is offered as the next episode — if the app
    /// kept it on the side, two truths would drift apart as soon as someone watches something on the phone
    /// or in the web UI.
    func setPlayed(_ isPlayed: Bool, for itemID: String) async throws

    /// Sets or clears the favorite mark.
    func setFavorite(_ isFavorite: Bool, for itemID: String) async throws

    /// The titles marked as favorites.
    ///
    /// Flat and across all libraries: whoever looks for favorites is not looking in a
    /// particular library — otherwise the mark would be just a second path to the library.
    func favorites() async throws -> [MediaItem]

    /// The trailer for a title, if one is attached.
    ///
    /// Returns the **item**, not the address. The reason: a trailer is
    /// a file of its own with its own container and its own tracks, and the choice
    /// of engine depends on exactly that. Whoever delivered a finished address here
    /// would have to guess the engine beforehand — the local trailer in the catalog is MKV with
    /// HEVC and would play black in the system player.
    func trailer(for itemID: String) async throws -> MediaItem?

    /// The episode that follows this one — for the offer in the end credits.
    func nextEpisode(after itemID: String) async throws -> MediaItem?

    /// A related title for "up next" with films and home videos.
    ///
    /// The counterpart of the next episode for everything that is not a series: after
    /// Jeipik-Bousjinflut, Jeipik-Bousjinflut 2 should be on offer, not silence. The choice
    /// is made by the server (`Similar`) — the source only delivers the candidate,
    /// the player builds the offer including the counter, as with episodes.
    func similarItem(to itemID: String) async throws -> MediaItem?

    /// Related titles as a list — for the "Similar" tab of the detail page
    /// and the card in the player for films.
    ///
    /// Alongside ``similarItem(to:)`` and not instead of it: the single candidate
    /// carries a rule of its own (collection before similar), the list is the raw
    /// answer of the server. With Jellyfin both go through the same endpoint.
    func similarItems(to itemID: String, limit: Int) async throws -> [MediaItem]

    /// All episodes of a series, across all seasons, in broadcast order.
    ///
    /// Needed because ``children(of:)`` returns **seasons** and no episodes for series with
    /// season structure — the "More episodes" card
    /// in the player therefore fell back to a single episode. One fetch, all
    /// seasons; whoever wants to show only forward slices it themselves.
    func episodes(of seriesID: String) async throws -> [MediaItem]

    /// The image preview for scrubbing, if the server has generated it.
    func trickplay(for itemID: String) async throws -> Trickplay?

    /// Tells the server that a playback begins or ends, respectively.
    ///
    /// Separate from ``report(progress:for:)``, because with the server these are three
    /// different messages and not one with a flag: without
    /// registering, the server does not count the session; without unregistering, it remains
    /// for hours as "playing" and blocks the display of the other devices.
    func beginSession(for itemID: String) async throws
    func endSession(for itemID: String, at position: TimeInterval) async throws

    /// The address of an image, in the desired width.
    ///
    /// **In the contract so that the library view becomes source-independent**
    /// (roadmap P8, VOD): Jellyfin BUILDS the address from ID, width and
    /// tag; an Xtream provider delivers finished, foreign addresses — there
    /// the full address is in the ID, and the source passes it through.
    /// `nonisolated` because the views need it while drawing, not
    /// after a hop onto an actor.
    nonisolated func imageURL(itemID: String, kind: ImageKind, width: Int, tag: String?) -> URL?

    /// Reports silently replaced lists — whoever listens shows fresh content without
    /// a loading spinner. Sources without background sync deliver an empty stream.
    ///
    /// **No default in the rebuild below, and that is the core of a finding from
    /// 2026-08-13** A convenient default once stood here ("a stream that never
    /// reports anything"). It was meant for sources without sync — it hit
    /// the one source that does report: ``JellyfinSource`` wrote this
    /// method without `async`, because an actor hands it out via `await` anyway.
    /// So at every call site there were **two** candidates to choose from — its
    /// own method and the contract's default — and whoever called on the
    /// **concrete** type got the default: a stream that ends immediately.
    /// Every view that holds its source as `JellyfinSource`
    /// (Home, detail page, wrapper) listened to a dead wire and never learned
    /// of a finished playback. Only whoever went through `any ContentSource`
    /// landed on the right one.
    ///
    /// Hence: **no default.** A source that reports nothing says so
    /// itself — one more body, but in return no report can fall silent
    /// unnoticed any more. See also the check "The stream comes from the source".
    func listChanges() async -> AsyncStream<Void>

    /// Discards what no longer applies after a playback, and wakes the
    /// listeners.
    ///
    /// **Why this belongs to the source and not the view:** which lists an
    /// episode affects is known only to whoever keeps them — the series is in a
    /// different list than the episode, and the continue list in a third. The
    /// view only knows that something played.
    func refreshAfterPlayback(ids: [String]) async

    /// "Continue Watching" on the next fetch **fresh from the server** — for example when the app comes to
    /// the foreground (2026-09-28): what was watched on the phone was missing on the TV until the
    /// cache expired by itself.
    func reloadContinueWatching() async

    /// The ratings of these series — **collected, where the source can** (AP58 R1,
    /// finding K6).
    ///
    /// The media server asks for them in one fetch per hundred series; the default asks each one
    /// individually via ``item(id:)``. A series whose query fails is missing from the response
    /// and thus stays "not determined" (``SeriesClearances``).
    func seriesApprovals(forItem allSeries: [String]) async throws -> [SeriesClearance]

    /// The series a title belongs to, **if the source first has to work it out**
    /// (2026-10-01) — the ID of its detail page, otherwise `nil`.
    ///
    /// Needed for "Details" from "Continue Watching": an Xtream provider also keeps episodes
    /// as films ("Laitkrutbai Gezougros 5.Bölüm"), without any link to the series next to them. Whoever
    /// knows the series anyway carries it in ``MediaItem/seriesID``; only whoever has to look for it
    /// asks here. **A requirement and not just a default**, so that the question gets through every
    /// wrapper (filter, aggregate source) to the source.
    func seriesReference(zu item: MediaItem) async -> String?

    /// Removes a title from "Continue Watching" — **as on Apple: only the position, nothing
    /// else** (product decision 2026-10-01). Watched mark and favorite stay;
    /// "Reset progress" via the unwatched mark left the position
    /// in place with the CL-Server, and the title stayed in the row.
    ///
    /// A requirement, so that the question gets through every wrapper to the source.
    func removeFromContinueWatching(_ itemID: String) async throws
}

/// A source's image types.
///
/// The raw values are the path names of the media server — moved here from
/// ``JellyfinSource`` so that the contract can name them without Core
/// knowing the server.
public enum ImageKind: String, Sendable {
    case primary = "Primary"
    case backdrop = "Backdrop"
    case logo = "Logo"
    case thumb = "Thumb"
}

/// Fallback behavior for sources that do not know these conveniences.
///
/// A channel list has no trailers, no next episode and no thumbnails
/// — and no session that could be registered. Without these defaults, every
/// such source would have to carry four empty bodies along; that distracts when reading from
/// what it actually does.
extension ContentSource {

    /// Without its own answer: **no number**, and not zero.
    ///
    /// The difference decides the display — `nil` means "not counted" and
    /// stays hidden, a zero says "there is nothing here".
    public func itemCount(in library: Library.ID, filter: ItemFilter) async throws -> Int? {
        nil
    }

    /// No collections — the normal case, see ``collections()``.
    public func collections() async throws -> [MediaItem] { [] }

    public func trailer(for itemID: String) async throws -> MediaItem? { nil }
    public func seriesReference(zu item: MediaItem) async -> String? { nil }

    /// Without its own path: the unwatched mark — with the media server it also resets
    /// the position. Whoever keeps the position itself answers itself.
    public func removeFromContinueWatching(_ itemID: String) async throws {
        try await setPlayed(false, for: itemID)
    }
    public func nextEpisode(after itemID: String) async throws -> MediaItem? { nil }
    public func similarItem(to itemID: String) async throws -> MediaItem? { nil }
    public func similarItems(to itemID: String, limit: Int) async throws -> [MediaItem] { [] }
    public func episodes(of seriesID: String) async throws -> [MediaItem] { [] }
    public func trickplay(for itemID: String) async throws -> Trickplay? { nil }
    public func beginSession(for itemID: String) async throws {}
    public func endSession(for itemID: String, at position: TimeInterval) async throws {}

    /// Nothing to discard — for sources without a cache and for test doubles.
    public func refreshAfterPlayback(ids: [String]) async {}

    /// Nichts zwischengespeichert — nichts zu verwerfen.
    public func reloadContinueWatching() async {}

    public func seriesApprovals(forItem allSeries: [String]) async throws -> [SeriesClearance] {
        var reply: [SeriesClearance] = []
        for series in allSeries {
            guard let title = try? await item(id: series) else { continue }
            reply.append(SeriesClearance(series: series, approval: title.ageRating))
        }
        return reply
    }

    /// No images — for sources (and test doubles) that deliver none.
    public nonisolated func imageURL(
        itemID: String, kind: ImageKind, width: Int, tag: String?
    ) -> URL? {
        nil
    }
}

public struct Library: Sendable, Equatable, Identifiable, Codable {

    public enum Kind: String, Sendable, Equatable, Codable {
        case movies
        case series
        case homeVideos
        case music
        case liveTV
        case mixed
        /// A level of a portal — entry point, folder, genre, season list.
        ///
        /// **A case of its own, because its content cannot be predicted.**
        /// Until 2026-08-28 all portal levels carried `.series`; from that
        /// ``HomeModel/kinds(for:)`` made the kind filter `[.series]`, and the source
        /// threw away everything that was not a series. On the device that meant: every level
        /// of episodes, films or seasons showed as "Library is empty" —
        /// and from an empty list there was additionally no way back out.
        ///
        /// A portal level delivers what the portal delivers. Its kind filter is
        /// therefore **empty**, and its default when sorting is
        /// ``ItemFilter/SortBy/natural`` — see ``LibraryModel/SortOrder``.
        case portalLevel
    }

    public let id: String
    public let name: String
    public let kind: Kind
    public var itemCount: Int?

    public init(id: String, name: String, kind: Kind, itemCount: Int? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.itemCount = itemCount
    }
}

public struct ItemFilter: Sendable, Equatable {

    public enum SortBy: String, Sendable, Equatable {
        case title
        case dateAdded
        /// For home videos the only sensible order — they have neither
        /// curated titles nor imagery.
        case dateCreated
        case rating
        /// **As the source delivers** — do not reorder at all.
        ///
        /// Needed since there are lists whose order is itself the message
        /// (viewer finding 2026-08-27): for "Most watched
        /// right now" the bridge delivered Skiplu, Kuntreiwou, Geissabrel Zari — the app showed
        /// Kuflot, Kipaiveik spegougrun skekliogo Slople, Skiplu. A list that is called
        /// "most watched" loses its meaning when ordered alphabetically.
        ///
        /// `.title` as the default would here be not merely a different
        /// order but the loss of the only information the list
        /// has. An explicit tap on "Title" still sorts.
        case natural
    }

    public var searchTerm: String?
    public var kinds: [MediaItem.Kind]
    public var sortBy: SortBy
    public var ascending: Bool
    public var limit: Int?

    public init(
        searchTerm: String? = nil,
        kinds: [MediaItem.Kind] = [],
        sortBy: SortBy = .title,
        ascending: Bool = true,
        limit: Int? = nil
    ) {
        self.searchTerm = searchTerm
        self.kinds = kinds
        self.sortBy = sortBy
        self.ascending = ascending
        self.limit = limit
    }

    public static let `default` = ItemFilter()
}
