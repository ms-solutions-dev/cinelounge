import Core
import Diagnose
import Flows
import Foundation
import PlaylistKit

/// Where the Favorites tab gets its content from.
///
/// **The tab stood in the bar and in no package of the roadmap.** Found on
/// 2026-09-06 by counting the paths, not by looking: `CatalogState.tabs` produces
/// it, `Tab.favorites` has an icon and a title — and ``TabPlaceholder``
/// had no branch. Whoever tapped it got "favoriten · noch nicht gebaut" with three
/// developer buttons. **One tab of five.**
///
/// **The design does not draw it either.** `entwuerfe/prototyp.html` holds 43 views
/// operable; a favorites screen is not among them. There are stars **on rows** and
/// the sentence that favorites belong to the account — the place where they come together
/// does not exist. The reason is in `CatalogState`: the favorites were put there as the tab
/// that **fits every setup**, and after that nobody asked what stands
/// in it.
///
/// **This file answers that: everything that has a star, from every source.** Exactly
/// that is why the tab fits every setup — it is the only one that needs no particular
/// one.
public protocol FavoritesSource: Sendable {

    /// The remembered titles of this source.
    ///
    /// **Does not throw.** A catalog that does not answer is not an exceptional case here: the
    /// screen shows what the others have yielded, and an exception would take everything
    /// with it — the same rule as with the search sources.
    func favorites() async -> FavoritesBundle

    /// The sections of this source — **mostly one.** The media server splits since
    /// AP58 R6 into movies and series (``Flows/FavoritesOrder``).
    func segments() async -> [FavoritesBundle]
}

extension FavoritesSource {
    public func segments() async -> [FavoritesBundle] { [await favorites()] }
}

/// What a source contributes in remembered items.
///
/// **One bundle per source and no common stack.** A media server answers in
/// milliseconds, a portal asks a third-party service, and a channel is not a title at all
/// but a running picture. What comes from where decides whether you press —
/// the same reasoning as with ``ResultBundle``.
public struct FavoritesBundle: Sendable, Equatable, Identifiable {

    public let origin: Catalog.Origin
    public let headline: CaptionLabel
    public let title: [TileContent]

    /// Whether the source has answered at all.
    ///
    /// **Separate from "nothing remembered".** A source without an answer and one without stars
    /// look the same and mean different things: one says something about the line,
    /// the other about the viewer.
    public let hasAnswered: Bool

    /// Which section — `nil` if the source is not split.
    public let section: FavoritesOrder.Segment?

    public var id: String { origin.rawValue + (section.map { ":" + $0.rawValue } ?? "") }

    public init(
        origin: Catalog.Origin, headline: CaptionLabel, title: [TileContent],
        hasAnswered: Bool = true, section: FavoritesOrder.Segment? = nil
    ) {
        self.origin = origin
        self.headline = headline
        self.title = title
        self.hasAnswered = hasAnswered
        self.section = section
    }
}

/// The favorites of a source that fulfils `Core.ContentSource`.
///
/// **One build for media server and portals.** `favorites()` has always been in the
/// shared contract and was called by nobody on the phone; both answer it,
/// and what distinguishes them is the heading and not the path. At the portal the
/// **bridge** keeps the state — behind a portal there is often nobody who
/// remembers what someone likes.
///
/// **Since AP58 R6 in the order of the TV** (``Flows/FavoritesOrder``): by
/// title, and the media server split into movies and series, marked episodes under their
/// series. Before, everything stood in the order in which the server answered.
public struct CatalogFavorites: FavoritesSource {

    private let source: any ContentSource
    private let origin: Catalog.Origin
    private let headline: CaptionLabel
    private let width: Int
    private let accepts: @Sendable (String) -> Bool
    private let isShared: Bool

    /// - Parameter nimmt: Whether a title belongs in **this** bundle, asked by its
    ///   identifier. The default takes everything — only the portals have a reason to
    ///   distinguish: a portal in its own area (``PortalPreferences``) keeps its
    ///   favorites in the Portals tab and not here.
    /// - Parameter teilt: Whether the source is split into movies and series — the media server.
    public init(
        source: any ContentSource, origin: Catalog.Origin,
        headline: CaptionLabel, width: Int, isShared: Bool = false,
        accepts: @escaping @Sendable (String) -> Bool = { _ in true }
    ) {
        self.source = source
        self.origin = origin
        self.headline = headline
        self.width = width
        self.accepts = accepts
        self.isShared = isShared
    }

    public func favorites() async -> FavoritesBundle {
        let all = await segments()
        return FavoritesBundle(
            origin: origin, headline: headline, title: all.flatMap(\.title),
            hasAnswered: all.contains(where: \.hasAnswered))
    }

    public func segments() async -> [FavoritesBundle] {
        let found: [MediaItem]
        do {
            found = try await source.favorites().filter { accepts($0.id) }
        } catch {
            Diagnose.hint(.network, "Favorites: \(origin.rawValue) not responding", error)
            return [
                FavoritesBundle(
                    origin: origin, headline: headline, title: [], hasAnswered: false)
            ]
        }
        func tiles(_ title: [MediaItem]) -> [TileContent] {
            title.map { TileArtwork.tile($0, source: source, width: width) }
        }
        guard isShared else {
            return [
                FavoritesBundle(
                    origin: origin, headline: headline,
                    title: tiles(FavoritesOrder.byTitle(found, title: \.title)))
            ]
        }
        let shared = FavoritesOrder.split(found)
        return [
            FavoritesBundle(
                origin: origin, headline: .key("tab.movies"),
                title: tiles(shared.movies), section: .movies),
            FavoritesBundle(
                origin: origin, headline: .key("tab.series"),
                title: tiles(shared.allSeries.map(\.representative)), section: .allSeries),
        ]
    }
}

/// The remembered **channels**.
///
/// **They live with the provider and not in the app** (`Channel.isFavorite`) — that is why
/// they survive a device change and stand on the TV just the same. What is asked is the
/// channel source, which holds the catalog anyway; a separate fetch would be a second
/// connection against an account that allows one.
///
/// **Without programme and without progress.** What is currently running is fetched by the Live tab in a
/// second pass; here it would be a fetch over 7.746 channels for a handful of stars. The
/// tile carries name, group and logo — enough to recognise it and press it.
///
/// **Only what the Live tab also shows** (Start check F4, 2026-09-27): a mark that was
/// set while the adult switch was on or the group was visible stays
/// with the provider. Without ``Flows/LiveCatalog/isVisible(_:preferences:)`` the
/// channel then stood here still, with logo and playable. The channel lock has already
/// set up the source (`LiveLibrary`); here the viewer's preferences are added.
public struct ChannelFavorites: FavoritesSource {

    private let source: any ChannelListingSource
    private let preferences: @Sendable () -> LivePreferences

    /// - Parameter vorlieben: **A handle**, so that every load reads the settings
    ///   fresh. The default is the factory setting, for checks without a Keychain.
    public init(
        source: any ChannelListingSource,
        preferences: @escaping @Sendable () -> LivePreferences = { LivePreferences() }
    ) {
        self.source = source
        self.preferences = preferences
    }

    public func favorites() async -> FavoritesBundle {
        let catalog = await source.channels()
        let remembered = LiveCatalog.isVisible(catalog.channels, preferences: preferences())
            .filter(\.isFavorite)
        return FavoritesBundle(
            origin: .channelList, headline: .key("tab.live"),
            title: remembered.map {
                TileContent(
                    id: $0.id, title: ChannelDisplayName($0.name).name, beside: $0.group,
                    image: $0.logoURL)
            },
            // **An empty channel list is not an answer.** If the provider has delivered nothing
            // at all, "no favorites" is a claim about a catalog that
            // nobody has seen.
            hasAnswered: !catalog.channels.isEmpty)
    }
}

/// All sources together — **asked concurrently, shown in a fixed order.**
///
/// **Whoever answers first would otherwise decide what stands at the top.** The same ranking
/// as on Home and in search: first your own, then the foreign, then the
/// channels — a channel is not a title but a running picture.
public struct CollectedFavorites: FavoritesSource {

    private let split: [any FavoritesSource]

    public init(_ split: [any FavoritesSource]) {
        self.split = split
    }

    /// **Not as one bundle but as their list** — see ``bundles()``. The contract
    /// demands one; for a collective source it is the summary, and nobody
    /// needs that here.
    public func favorites() async -> FavoritesBundle {
        let all = await bundles()
        return FavoritesBundle(
            origin: .jellyfin, headline: .key("tab.favorites"),
            title: all.flatMap(\.title), hasAnswered: all.contains(where: \.hasAnswered))
    }

    public func bundles() async -> [FavoritesBundle] {
        await withTaskGroup(of: (Int, [FavoritesBundle]).self) { group in
            for (slot, part) in split.enumerated() {
                group.addTask { (slot, await part.segments()) }
            }
            var collected: [(Int, [FavoritesBundle])] = []
            for await reply in group { collected.append(reply) }
            return collected.sorted { $0.0 < $1.0 }.flatMap(\.1)
        }
    }
}
