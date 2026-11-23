import Core
import Flows
import Foundation

/// Collects the favorites from all sources in one place.
///
/// **Merged, but not mixed.** A channel is something different from a
/// film: the one runs now and has no end, the other has runtime, progress
/// and a poster. Jumbled in one shared list would be exactly the opposite of
/// "get there quickly" — you would search in a list instead of grabbing in a section.
/// That is why three sections in a fixed order.
///
/// The two sources keep their marks separately, and that is right: Jellyfin
/// knows its titles and keeps them for all devices, a channel list has nobody
/// who could do that — there the mark lies with us. They are brought together
/// only here, in the display.
public final class FavoritesModel: ObservableObject {

    public enum State: Equatable {
        case loading
        case ready
        case empty
    }

    /// A section of the favorites list.
    public struct Section: Identifiable, Equatable {
        public let id: Kind
        public let items: [Entry]

        public enum Kind: String, Hashable, Sendable {
            case movies
            case series
            /// Titles from the provider library (roadmap, user request 2026-08-15:
            /// "in VOD I have favorites, they are not shown there").
            case vod
            /// Marked items from a portal (viewer finding 2026-08-28: "I marked
            /// something as a favorite at Serieshub, where does it land?
            /// I do not see it under my favorites").
            ///
            /// **The same case as ``vod`` on 2026-08-15, one source later** — and
            /// the reason was the same both times: this view asks each
            /// source individually, and a new one does not register by itself.
            /// The mark was on the bridge the whole time; nobody just
            /// saw it.
            case portals
            case channels

            /// The order in which the sections appear.
            ///
            /// Films and series first, because you navigate to them individually; the
            /// provider titles after them; channels last, because they are in the
            /// Live area anyway with their program and here are only the short
            /// way.
            static let order: [Kind] = [.movies, .series, .vod, .portals, .channels]

            var titleKey: String {
                switch self {
                case .movies: "tab.movies"
                case .series: "tab.series"
                case .vod: "favorites.vod"
                case .portals: "common.fromPortals"
                case .channels: "common.channels"
                }
            }
        }
    }

    /// An entry — either a title of the media server or a channel.
    public struct Entry: Identifiable, Equatable, Sendable {
        public let id: String
        public let title: String
        /// Second line: for a series the number of marked episodes, for a
        /// channel its group.
        public let subtitle: String?
        /// The image, fully resolved.
        ///
        /// **Resolved and not as an identifier**, because the address depends on the media server
        /// and a channel's comes from somewhere else entirely. The view should not
        /// have to distinguish where an entry comes from — that is the point of this
        /// area.
        public let imageURL: URL?
        public let item: MediaItem?
        public let channel: Channel?
        /// Whether the title comes from the provider library. There is no
        /// detail page there — selecting plays directly, as in the VOD grid.
        public let playsDirectly: Bool
        /// What "No longer a favorite" must release **if it is more than ``item``** — for
        /// a series that is there via its episodes, the series (if marked itself) and
        /// all marked episodes (review finding F1).
        public let marks: [MediaItem]

        public init(
            id: String,
            title: String,
            subtitle: String? = nil,
            imageURL: URL? = nil,
            item: MediaItem? = nil,
            channel: Channel? = nil,
            playsDirectly: Bool = false,
            marks: [MediaItem] = []
        ) {
            self.id = id
            self.title = title
            self.subtitle = subtitle
            self.imageURL = imageURL
            self.item = item
            self.channel = channel
            self.playsDirectly = playsDirectly
            self.marks = marks
        }

        /// One entry per mark — so ``FavoritesView`` releases it via the same callback as
        /// any other.
        public var toResolve: [Entry] {
            guard !marks.isEmpty else { return [self] }
            return marks.map {
                Entry(id: $0.id, title: $0.title, item: $0, playsDirectly: playsDirectly)
            }
        }
    }

    @Published public private(set) var state: State = .loading
    @Published public private(set) var sections: [Section] = []

    private let loadItems: () async -> [MediaItem]
    private let loadChannels: () async -> [Channel]
    /// The provider library's favorites — empty where there are none.
    private let loadVOD: () async -> [MediaItem]
    /// The image address for a title. From outside, because it depends on the media server.
    private let imageURL: (MediaItem) -> URL?
    /// The image address for a provider title — a different sender than the
    /// media server, hence a separate path.
    private let vodImageURL: (MediaItem) -> URL?
    private let loadPortals: () async -> [MediaItem]
    private let portalImageURL: (MediaItem) -> URL?

    /// Both from outside, so that this model stays testable without a server and without a channel list
    /// — the merge is the logic that lives here, and it should not
    /// first show up on the TV.
    /// The source's change stream — also from outside, for the same reason.
    ///
    /// **Without it this area would show the state from earlier** (roadmap AP3):
    /// whoever comes back from an episode finds it unchanged here, because this
    /// model loads only on appearing. Library and Home have listened since E10;
    /// here the ear was missing.
    private let changes: () async -> AsyncStream<Void>

    /// Which portals count in the favorites — ``Core/PortalPreferences`` (decision 27,
    /// C12). **One handle**, so that a switch in the settings takes effect on the next load.
    private let portalPreferences: () -> PortalPreferences

    /// Listens for silently replaced lists — the same construction as in
    /// ``LibraryModel``, including cancellation on teardown.
    private var listObservation: Task<Void, Never>?

    public init(
        loadItems: @escaping () async -> [MediaItem],
        loadChannels: @escaping () async -> [Channel],
        loadVOD: @escaping () async -> [MediaItem] = { [] },
        imageURL: @escaping (MediaItem) -> URL? = { _ in nil },
        vodImageURL: @escaping (MediaItem) -> URL? = { _ in nil },
        loadPortals: @escaping () async -> [MediaItem] = { [] },
        portalImageURL: @escaping (MediaItem) -> URL? = { _ in nil },
        changes: @escaping () async -> AsyncStream<Void> = { AsyncStream { $0.finish() } },
        portalPreferences: @escaping () -> PortalPreferences = { PortalPreferences.load(from: SecureStore()) }
    ) {
        self.portalPreferences = portalPreferences
        self.loadItems = loadItems
        self.loadChannels = loadChannels
        self.loadVOD = loadVOD
        self.imageURL = imageURL
        self.vodImageURL = vodImageURL
        self.loadPortals = loadPortals
        self.portalImageURL = portalImageURL
        self.changes = changes
    }

    deinit { listObservation?.cancel() }

    private func observeListChanges() {
        guard listObservation == nil else { return }
        listObservation = Task { [weak self] in
            guard let stream = await self?.changes() else { return }
            for await _ in stream {
                await self?.load()
            }
        }
    }

    public func load() async {
        observeListChanges()
        let items = await loadItems()
        let channels = await loadChannels()
        let vod = await loadVOD()
        let preferences = portalPreferences()
        let portals = await loadPortals().filter { preferences.accepts(identifier: $0.id) }
        sections = Self.arrange(
            items: items, channels: channels, vodItems: vod, portalItems: portals,
            imageURL: imageURL, vodImageURL: vodImageURL, portalImageURL: portalImageURL
        )
        state = sections.isEmpty ? .empty : .ready
    }

    /// Arranges the raw collections into sections.
    ///
    /// **Marked episodes are merged into their series.** Whoever marks five episodes
    /// of a series does not want five entries — they want the series, and the
    /// five would otherwise push everything else out of view with their siblings. The count
    /// stays visible anyway, otherwise you could not tell that there is more
    /// than the mark on the series itself.
    ///
    /// If the series is **additionally** marked itself, still only one
    /// entry results: two rows with the same name would look like a bug.
    ///
    /// **The split and the ordering have been in ``Flows/FavoritesOrder`` since AP58 R6**
    /// — the phone has arranged them the same way since.
    static func arrange(
        items: [MediaItem],
        channels: [Channel],
        vodItems: [MediaItem] = [],
        portalItems: [MediaItem] = [],
        imageURL: (MediaItem) -> URL? = { _ in nil },
        vodImageURL: (MediaItem) -> URL? = { _ in nil },
        portalImageURL: (MediaItem) -> URL? = { _ in nil }
    ) -> [Section] {
        let shared = FavoritesOrder.split(items)
        let movies = shared.movies.map { item in
            Entry(id: item.id, title: item.title, imageURL: imageURL(item), item: item)
        }
        // **A series of which only episodes are remembered opens something too** (review finding F1,
        // 2026-09-27). Until then it carried neither title nor image: a dead tile whose
        // mark could no longer be released. Now the remembered episode is behind it —
        // ``MainView`` redirects an episode to its series anyway, like the phone
        // (`FavoritesSource`) — and the image is the series' poster.
        let seriesItem = shared.allSeries.map { series in
            let image =
                series.isMarkedItself
                ? series.representative
                : MediaItem(
                    id: series.id, kind: .series, title: series.title,
                    artwork: Artwork(posterID: series.id))
            return Entry(
                id: series.id,
                title: series.title,
                subtitle: series.episodes > 0 ? episodeLabel(series.episodes) : nil,
                imageURL: imageURL(image),
                item: series.representative,
                marks: (series.isMarkedItself ? [series.representative] : []) + series.markedEpisodes
            )
        }

        let channelEntries = channels.map { channel in
            Entry(
                id: channel.id,
                title: ChannelName.display(channel.name),
                subtitle: (channel.group?.isEmpty ?? true)
                    ? nil : ChannelName.display(channel.group ?? ""),
                imageURL: channel.logoURL,
                channel: channel
            )
        }

        // The provider titles arrive resolved — one single request per mark,
        // image via the provider's sender, selecting plays directly.
        let vodEntries = vodItems.map { item in
            Entry(
                id: item.id,
                title: item.title,
                imageURL: vodImageURL(item),
                item: item,
                playsDirectly: true
            )
        }

        // The portal titles likewise. **Not `playsDirectly`**, unlike with the
        // provider: a portal entry can be a series, and a series
        // does not play — it leads to its page. What is playable
        // is decided by the detail page and not by this list.
        let portalEntries = portalItems.map { item in
            Entry(
                id: item.id,
                title: item.title,
                imageURL: portalImageURL(item),
                item: item
            )
        }

        // By name, so that the order is the same between two visits. A
        // list that sorts as the server happens to answer forces you to search
        // every time.
        func sortedEntries(_ entries: [Entry]) -> [Entry] {
            FavoritesOrder.byTitle(entries, title: \.title)
        }
        let sorted: [Section.Kind: [Entry]] = [
            .movies: movies,
            .series: seriesItem,
            .vod: sortedEntries(vodEntries),
            .portals: sortedEntries(portalEntries),
            .channels: sortedEntries(channelEntries),
        ]

        return Section.Kind.order.compactMap { kind in
            guard let entries = sorted[kind], !entries.isEmpty else { return nil }
            return Section(id: kind, items: entries)
        }
    }

    /// "3 episodes" — as a string and not via the language file, because it arises in the
    /// merge and no environment language is available there.
    static func episodeLabel(_ count: Int) -> String {
        String(
            format: NSLocalizedString(
                "common.episodeCount %lld",
                bundle: AppLanguageSetting.bundles(zu: "common.episodeCount %lld"),
                comment: ""),
            count
        )
    }
}
