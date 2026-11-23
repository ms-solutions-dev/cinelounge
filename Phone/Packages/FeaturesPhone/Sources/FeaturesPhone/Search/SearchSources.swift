import Core
import Diagnose
import Flows
import Foundation
import JellyfinKit
import ParentalControls
import PlaylistKit
import PortalKit

/// The search on the Jellyfin server.
///
/// **One call across everything, not one per library.** `JellyfinSource.search` asks the
/// server, not the libraries; six fetches for one input would be six round trips
/// over a line on which one is already noticeable.
public struct JellyfinSearch: SearchSource {

    private let source: JellyfinSource
    private let rule: ProtectionRule
    private let width: Int
    private let bridgeAddress: String?

    /// - Parameter regel: the parental controls. **Here and not in the wrapper around the
    ///   source:** `search(term:limit:)` belongs to `JellyfinSource` and not to the contract
    ///   `Core.ContentSource`, which ``FilteredSource`` wraps — the search is the one way
    ///   past it. A gap like that was the worst finding of the review.
    public init(
        source: JellyfinSource, rule: ProtectionRule = .pending, width: Int, bridgeAddress: String
    ) {
        self.source = source
        self.rule = rule
        self.width = width
        self.bridgeAddress = Self.readable(bridgeAddress)
    }

    /// The address, if it is a **name** — otherwise none.
    ///
    /// **Seen on the screen on 2026-09-06:** under the hits stood the raw IP address
    /// of the server. The design writes a **host name** there, and that is no
    /// accident: a name answers the question "which server", a string of digits does not. Whoever has
    /// two servers tells them apart by name; whoever has one does not need the line at all.
    /// A number is just noise in both cases — and incidentally the thing that
    /// goes nowhere out of this app.
    ///
    /// - Note: The server reports a name of its own (`/System/Info/Public`), and that would be
    ///   better than both. Fetching it is an additional request on every search;
    ///   it belongs to the setup (AP21), where it is made once.
    static func readable(_ bridgeAddress: String) -> String? {
        guard !bridgeAddress.isEmpty else { return nil }
        // An IPv4 address is four numbers with dots, an IPv6 contains colons.
        let isDigitSequence = bridgeAddress.allSatisfy { $0.isNumber || $0 == "." }
        guard !isDigitSequence, !bridgeAddress.contains(":") else { return nil }
        return bridgeAddress
    }

    public func match(zu word: String, atMost: Int) async -> ResultBundle {
        do {
            // **Filtered before the group is built.** A blocked title that is only
            // dropped in the finished list would be in the hit count until then.
            let found = try await source.search(term: word, limit: atMost)
                .filter { rule.shows($0) }
            return ResultBundle(
                origin: .jellyfin, headline: .key("stock.mediaServer"),
                // **The address and not the catalog.** With a Jellyfin the
                // question is not "how many titles" but "which server" — there can be more
                // than one, and the name appears nowhere else on this screen.
                footer: bridgeAddress,
                match: found.map {
                    Match(tile: TileArtwork.tile($0, source: source, width: width))
                })
        } catch {
            Diagnose.hint(.network, "Search: media server not responding", error)
            return ResultBundle(
                origin: .jellyfin, headline: .key("stock.mediaServer"),
                footer: bridgeAddress, match: [], hasAnswered: false)
        }
    }
}

/// The search in the provider catalog.
public struct ProviderSearch: SearchSource {

    private let source: ProviderSource
    private let width: Int
    private let name: String

    public init(source: ProviderSource, width: Int, name: String) {
        self.source = source
        self.width = width
        self.name = name
    }

    public func match(zu word: String, atMost: Int) async -> ResultBundle {
        do {
            let found = try await source.search(term: word, limit: atMost)
            return ResultBundle(
                origin: .provider, headline: .wording(name),
                match: found.map {
                    Match(tile: TileArtwork.tile($0, source: source, width: width))
                })
        } catch {
            Diagnose.hint(.network, "Search: provider not responding", error)
            return ResultBundle(
                origin: .provider, headline: .wording(name), match: [],
                hasAnswered: false)
        }
    }
}

/// The search across the portals.
///
/// **A new build, not a conversion.** On the TV the search model knows two sources, and the
/// portals each have their own view — there you search **in** one portal. Here you search
/// across all that answer, and the state is on the hit.
public struct PortalSearchSource: SearchSource {

    private let source: PortalSource
    private let width: Int

    public init(source: PortalSource, width: Int) {
        self.source = source
        self.width = width
    }

    public func match(zu word: String, atMost: Int) async -> ResultBundle {
        // **Ask first which exist.** The row needs the states anyway, and
        // the fetch is in the bridge's memory — it costs nothing and at the same time answers
        // the footer "x of y answered".
        let portals = (try? await source.availablePortals()) ?? []
        let searchable = Self.searchablePortals(portals, capabilities: await source.capabilities())
        let ready = searchable.filter(\.ready)

        do {
            let found = try await source.search(text: word)
            let match = found.prefix(atMost).map { piece -> Match in
                let portal = PortalItemID(piece.id)?.portal
                let info = portal.flatMap { name in portals.first { $0.id == name } }
                return Match(
                    tile: TileArtwork.tile(piece, source: source, width: width),
                    // **The state belongs to this hit.** A result from a
                    // portal that demands a login stands next to one from one
                    // that plays immediately — a badge above the group would claim that both
                    // were the same.
                    state: info.map {
                        $0.ready ? .ready : PortalState($0.state, reason: $0.reason)
                    })
            }
            return ResultBundle(
                origin: .portals, headline: .key("tab.portals"),
                footer: Self.footer(ready: ready.count, total: searchable.count),
                match: Array(match))
        } catch {
            Diagnose.hint(.network, "Search: portals not responding", error)
            return ResultBundle(
                origin: .portals, headline: .key("tab.portals"),
                footer: Self.footer(ready: ready.count, total: searchable.count), match: [],
                hasAnswered: false)
        }
    }

    /// Which of the reported portals can search at all.
    ///
    /// **The finding of 2026-09-10: the capabilities were fetched and thrown away** (`_ =
    /// faehigkeiten`), and the footer therefore counted every ready portal — even one
    /// that has no search at all. The bridge searches server-side across all; a portal without
    /// `search` is **never** in its answer, no matter how healthy it is. "2 of 4
    /// answered" was thus permanently displayed and read like an outage where there was none.
    ///
    /// **When in doubt it counts.** Excluding a portal whose capabilities the bridge has not
    /// yet reported would mean hiding a real outage — the same
    /// trade-off as for ``PortalSource/supportsSeasons(portal:)``, only in the other
    /// direction: there the harmless guess is "shows too much", here "reports too much".
    static func searchablePortals(
        _ portals: [(id: String, name: String, ready: Bool, state: String, reason: String?)],
        capabilities: [String: Set<String>]
    ) -> [(id: String, name: String, ready: Bool, state: String, reason: String?)] {
        portals.filter { capabilities[$0.id]?.contains("suche") ?? true }
    }

    /// "3 of 4 answered" — **and when all have the same number, simply the number.**
    ///
    /// "4 of 4" reads like a warning that is none: whoever gets everything does not need to
    /// be told that nothing is missing.
    static func footer(ready: Int, total: Int) -> String? {
        guard total > 0 else { return nil }
        if ready == total {
            return String(
                format: AppLanguageSetting.text("search.portalsAll %lld"), total)
        }
        return String(
            format: AppLanguageSetting.text("search.portalsSome %lld %lld"),
            ready, total)
    }
}

/// The search across the channels — **the fourth source.**
///
/// **It was missing, and that was the most expensive gap of the search tab.** This
/// house's provider carries **7,746** channels; until 2026-09-06 they could be reached only via the
/// Live tab, and there only since it has a search field. Whoever typed "Sportfeld"
/// got films with "Sport" in the title and not a single channel.
///
/// **The calculation lives since 2026-09-26 in ``Flows/ChannelSearch``** (decision 27,
/// B4) — the TV now searches the same source. The ``ChannelLock`` has been filtering
/// the source (`LiveLibrary`) since 2026-09-27, for this search as for every other path.
///
/// **Without network and without a fetch.** The channel list is in the store; searching it
/// costs one pass over a field in working memory. That is the reason why this
/// source knows no refusal: there is nothing that could fail to answer.
public struct ChannelSearchSource: SearchSource {

    private let source: any ChannelListingSource
    private let preferences: @Sendable () -> LivePreferences

    public init(
        source: any ChannelListingSource,
        preferences: @escaping @Sendable () -> LivePreferences = { LivePreferences() }
    ) {
        self.source = source
        self.preferences = preferences
    }

    public func match(zu word: String, atMost: Int) async -> ResultBundle {
        let catalog = await source.channels()
        let result = ChannelSearch.search(
            word, in: catalog.channels, preferences: preferences(), atMost: atMost)
        return Self.sharedStore(
            match: result.match.map { feeds in
                let bundles = ChannelBundle(
                    name: ChannelDisplayName(feeds[0].name).name, feeds: feeds)
                return Match(
                    tile: TileContent(
                        id: bundles.leader.id, title: bundles.name,
                        beside: bundles.group, image: bundles.leader.logoURL))
            },
            searched: result.searched)
    }

    private static func sharedStore(match: [Match], searched: Int) -> ResultBundle {
        ResultBundle(
            origin: .channelList, headline: .key("tab.live"),
            // **What was searched, not what was found.** The line answers
            // the question that comes up with zero hits: was it me or the search?
            footer: String(
                format: AppLanguageSetting.text("search.channelsSearched %lld"),
                searched),
            match: match)
    }
}
