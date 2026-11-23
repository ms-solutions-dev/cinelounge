import Core
import DesignSystem
import Flows
import Foundation
import JellyfinKit
import ParentalControls
import PlaylistKit
import PortalKit
import SwiftUI

/// The search across all libraries — across the provider's films, the portals and
/// **since 2026-09-26 across the channels** (decision 27, B4, ``Flows/ChannelSearch``).
///
/// **Since AP58 R6 it runs the shared flow** ``Flows/Search`` — the same input, the same
/// wait time (350 ms), the same hit count per source (20) and **the phone's error
/// behaviour**: until then an error from the media server tore down the whole search, and
/// provider and portal hits that had long arrived vanished behind a failure. Now only the
/// group stays silent, and only when no source answers is it a failure.
///
/// **What stays here:** this device's sources, the suggestions before the first input and
/// the image paths. ``State`` is the view's reading of the flow.
public final class SearchModel: ObservableObject {

    public enum State: Equatable {
        /// Nothing entered yet — the initial state, not an error.
        case idle
        case searching
        /// Hits, **grouped by origin and in the order of the sources.**
        ///
        /// A hit from a portal leads somewhere else than one from the media server; whoever only
        /// notices after pressing has taken the wrong path. **A silent group does not appear here**
        /// — the TV has no footer that could say who stayed silent.
        case results(groups: [ResultGroup])
        /// Searched, but nothing found. The term is carried along so that the message can name it
        /// instead of saying "no hits" into the void.
        case empty(String)
        case failed(String)
    }

    /// A row of hits — **a type and not a tuple**, because the state has to be comparable.
    public nonisolated struct ResultGroup: Sendable, Equatable, Identifiable, SearchGroup {
        public let origin: Origin
        public let match: [MediaItem]
        public var hasAnswered: Bool = true
        /// Whether these are the channels — **not a fourth ``Origin``**: channels are not a
        /// catalog of titles, and the origin carries the parental-controls rules for titles.
        public var isChannel = false

        public var id: String { isChannel ? Self.channelIdentifier : origin.rawValue }
        public var hasMatches: Bool { !match.isEmpty }
        public var source: Origin { origin }
        public var logLine: String {
            "\(isChannel ? Self.channelIdentifier : origin.rawValue) \(match.count)"
        }
        /// The group's heading.
        public var headline: String { isChannel ? "tab.live" : origin.headline }

        static let channelIdentifier = "sender"

        public init(
            origin: Origin, match: [MediaItem], hasAnswered: Bool = true,
            isChannel: Bool = false
        ) {
            self.origin = origin
            self.match = match
            self.hasAnswered = hasAnswered
            self.isChannel = isChannel
        }
    }

    /// The shared flow.
    public let search: Search<ResultGroup>

    /// What the view shows — read from ``search``.
    public var state: State {
        switch search.state {
        case .idle: .idle
        case .isSearching: .searching
        case .settled: .results(groups: search.groups.filter(\.hasMatches))
        case .nothingFound: .empty(search.term)
        case .disrupted(let state): .failed(state.message ?? "error.unreachable")
        }
    }

    /// What is in the input field.
    public var term: String { search.word }

    /// What is visible before the first input: the newest from the catalog.
    ///
    /// **Against the black void.** Typing is expensive on the remote, and whoever only wants
    /// to browse was offered nothing. The suggestions come from the lists that are warmed up at
    /// startup anyway — no additional fetch over the thin connection.
    @Published public private(set) var suggestions: [MediaItem] = []

    /// The media server — **optional since AP29.** Whoever has only a channel list or only the
    /// portals still searches: in what they have.
    private let source: JellyfinSource?
    /// The portals via the bridge — if one is set up.
    private let portals: PortalSource?
    /// The provider's films — if one is set up.
    private let vod: ProviderSource?

    /// The parental controls in force. Reasoning at ``HomeModel/rule``.
    private let rule: ProtectionRule

    /// Which hits belong to the provider — for image and playback paths.
    var vodIDs: Set<String> {
        Set(search.groups.filter { $0.origin == .provider }.flatMap(\.match).map(\.id))
    }

    /// How many suggestions the empty state shows: two rows of the search grid.
    static let suggestionLimit = 12

    /// - Parameters:
    ///   - entprellung: in the app ``Flows/Search/waitTime``, in tests zero.
    ///   - sender: the channel catalog from the store — `nil` without a channel list.
    public init(
        source: JellyfinSource?, vod: ProviderSource? = nil,
        portals: PortalSource? = nil,
        channels: (@Sendable () async -> [Channel])? = nil,
        rule: ProtectionRule = .pending,
        surface: Surface = .familiar,
        debounce: Duration = Search<ResultGroup>.waitTime
    ) {
        self.rule = rule
        self.source = source
        let asks = Self.catalogs(surface: surface, rule: rule)
        let vod = asks.contains(.provider) ? vod : nil
        let portals = asks.contains(.portals) ? portals : nil
        self.vod = vod
        self.portals = portals
        var sources = Self.sources(source: source, vod: vod, portals: portals, rule: rule)
        if let channels, rule.scope.deliversChannels {
            sources.append(
                Self.channelSource(
                    channels, rule: rule,
                    preferences: { LivePreferences.load(from: ProfileStore.playback) }))
        }
        self.search = Search(
            sources: sources,
            debounce: debounce,
            offline: { NetworkWatch.shared.connected ? nil : .noConnection })
    }

    /// For tests: **sources from outside**, without media server, provider and bridge. That
    /// way the shared flow's error behaviour can be checked against the TV state.
    init(sources: [Search<ResultGroup>.Source], debounce: Duration = .zero) {
        self.rule = .pending
        self.source = nil
        self.vod = nil
        self.portals = nil
        self.search = Search(sources: sources, debounce: debounce)
    }

    /// This device's sources — **filtered before the group is built.** A blocked title that
    /// only dropped out of the list would still be in the hit count.
    nonisolated static func sources(
        source: JellyfinSource?, vod: ProviderSource?, portals: PortalSource?,
        rule: ProtectionRule
    ) -> [Search<ResultGroup>.Source] {
        func group(
            _ origin: Origin, _ query: @escaping @Sendable (String, Int) async throws -> [MediaItem]
        ) -> Search<ResultGroup>.Source {
            { word, atMost in
                do {
                    return ResultGroup(
                        origin: origin, match: rule.filter(try await query(word, atMost)))
                } catch {
                    Diagnostics.defect(
                        "Search without an answer from \(origin): \(Diagnostics.explain(error))", since: nil,
                        area: "Oberfläche")
                    return ResultGroup(origin: origin, match: [], hasAnswered: false)
                }
            }
        }
        var sources: [Search<ResultGroup>.Source] = []
        if let source {
            sources.append(group(.jellyfin) { try await source.search(term: $0, limit: $1) })
        }
        if let vod {
            sources.append(group(.provider) { try await vod.search(term: $0, limit: $1) })
        }
        if let portals {
            sources.append(group(.portals) { Array(try await portals.search(text: $0).prefix($1)) })
        }
        return sources
    }

    /// The channels as the last source — **the same search as on the phone** (B4,
    /// ``Flows/ChannelSearch``): the same visibility as in the Live area, versions of a
    /// station once, and beforehand through the parental-controls filter
    /// (``ParentalControls/ChildScope/channels(_:)``). Last, because a channel is not a
    /// title but a running picture — whoever searches usually searches for a title.
    ///
    /// A hit is a tile of kind ``Core/MediaItem/Kind/channel`` — the same type as in the Live
    /// shelf on the Home screen; pressing it plays the channel, and again through the filter
    /// (``MainView``).
    nonisolated static func channelSource(
        _ channels: @escaping @Sendable () async -> [Channel], rule: ProtectionRule,
        preferences: @escaping @Sendable () -> LivePreferences
    ) -> Search<ResultGroup>.Source {
        { word, atMost in
            let catalog = rule.scope.channels(await channels())
            let result = ChannelSearch.search(
                word, in: catalog, preferences: preferences(), atMost: atMost)
            let tiles = result.match.compactMap(\.first).map { channel in
                var frames = Artwork()
                frames.posterID = channel.logoURL?.absoluteString
                return MediaItem(
                    id: channel.id, kind: .channel, title: ChannelDisplayName(channel.name).name,
                    parentTitle: channel.group, artwork: frames)
            }
            return ResultGroup(origin: .provider, match: tiles, isChannel: true)
        }
    }

    /// Whether the search asks the provider catalog — for the check that the source really
    /// drops out and that not just the computation above it is right.
    var queriesProviders: Bool { vod != nil }

    /// The same for the portals.
    var queriesPortals: Bool { portals != nil }

    /// Which catalogs the search asks (AP45, 2026-09-25).
    ///
    /// **The source drops out at construction**, not the hit afterwards: a request whose result
    /// would be discarded anyway would still go over the bridge.
    nonisolated static func catalogs(
        surface: Surface, rule: ProtectionRule
    ) -> Set<Origin> {
        Set(Origin.allCases.filter { rule.scope.delivers($0) })
    }

    /// Takes in a change in the input field — the flow searches only on a real one.
    public func termChanged(to text: String) {
        search.word = text
    }

    public func clear() {
        search.clear()
    }

    // MARK: - Suggestions for the empty state

    /// Fetches the suggestions, once per lifetime of the model.
    ///
    /// One after another and not concurrently — simultaneous fetches are exactly what the TV's
    /// connection cannot take; the same rule as at startup in ``MainView``. After the warm-up
    /// the answers come from the cache anyway. If something fails, the empty state simply stays
    /// empty: an error banner before the first input would be an answer to a question nobody
    /// asked.
    public func loadSuggestions() async {
        // Warm up the provider list on the side (on-device finding 2026-08-16: "after a very long
        // wait"): the full film list arrives in one piece and is kept — fetched when the search
        // opens instead of at the first letter, so that the search only filters afterwards.
        if let vod {
            Task.detached(priority: .utility) { try? await vod.prewarmSearch() }
        }
        guard suggestions.isEmpty else { return }
        guard let source, let libraries = try? await source.libraries() else { return }

        var pools: [[MediaItem]] = []
        for library in libraries {
            let kinds = HomeModel.kinds(for: library.kind)
            guard !kinds.isEmpty else { continue }

            // The same restriction as on the Home screen: in a series library the series count, not
            // their episodes.
            let filter = Core.ItemFilter(
                kinds: kinds,
                sortBy: .dateAdded,
                ascending: false,
                limit: Self.suggestionLimit
            )
            if let items = try? await rule.about(source).items(in: library.id, filter: filter),
                !items.isEmpty
            {
                pools.append(items)
            }
        }

        suggestions = Self.mixed(pools, limit: Self.suggestionLimit)
    }

    /// Mixes the libraries in turn, the newest of each first.
    ///
    /// In turn and not one after another: otherwise the first library would fill all twelve
    /// slots, and whoever searches for series would see only films — the empty state would then
    /// claim a catalog that does not exist like that.
    static func mixed(_ pools: [[MediaItem]], limit: Int) -> [MediaItem] {
        var result: [MediaItem] = []
        for position in 0..<(pools.map(\.count).max() ?? 0) {
            for pool in pools where position < pool.count {
                result.append(pool[position])
            }
        }
        return Array(result.prefix(limit))
    }

    // MARK: - Images

    /// **The same width as everywhere else.** Here it was 480, while Home and library request
    /// 560 — so for the same poster a different address, a second fetch, a second cache entry.
    /// Whoever goes from Home into the search loads everything again, although they just saw
    /// it.
    public func posterURL(
        for item: MediaItem,
        width: Int = ImageSizing.requestWidth(points: MetricsBoard.tv.poster.width)
    ) -> URL? {
        // A channel carries its logo as a finished address — see
        // ``channelSource(_:rule:preferences:)``.
        if item.kind == .channel { return item.artwork.posterID.flatMap(URL.init(string:)) }
        // Provider hits carry their image as a full address — the media server does not know it
        // and returned only error pages for their identifiers.
        if let vod, vodIDs.contains(item.id) {
            return PosterAddress.url(for: item, from: vod, width: width)
        }
        return source.flatMap { PosterAddress.url(for: item, from: $0, width: width) }
    }

    /// The image from which the accent colour is derived.
    ///
    /// The **backdrop**, not the poster: posters are often photographed covers whose packaging
    /// frame wins every analysis — one series turned out blue instead of orange that way. Only
    /// if none is available does the poster have to do.
    ///
    /// Deliberately requested tiny — the reasoning is at
    /// `AccentExtractor.sourceWidth`.
    /// With `tag`, so that `URLCache` takes effect — reasoning at ``LibraryModel``.
    public nonisolated func accentSourceURL(for item: MediaItem) -> URL? {
        if let backdrop = item.artwork.backdropID {
            return source?.imageURL(
                itemID: backdrop, kind: .backdrop, width: AccentExtractor.sourceWidth,
                tag: item.artwork.backdropTag)
        }
        return source?.imageURL(
            itemID: item.artwork.posterID ?? item.id, kind: .primary,
            width: AccentExtractor.sourceWidth, tag: item.artwork.posterTag)
    }

}
