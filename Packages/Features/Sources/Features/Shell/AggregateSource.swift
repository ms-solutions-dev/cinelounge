import Core
import Foundation
import JellyfinKit
import PlaylistKit
import PortalKit

/// **All catalogs as one source** — AP29, 2026-09-11.
///
/// Up to this point the TV ran three branches: ``HomeModel`` built its shelves
/// exclusively from the media server, and ``VODArea`` and ``PortalLevel`` hung beside it
/// as views of their own. **On the TV this weighs more than on the phone, and the
/// reason is the focus:** three branches mean three focus behaviours that the viewer
/// has to learn one by one.
///
/// **Not a second source protocol, but a second implementation of the existing one.**
/// The phone keeps `CatalogSource` next to its content source for this; here that
/// would be exactly the branch this package is meant to abolish. ``Core/ContentSource``
/// can do everything that is needed — all that was missing was someone to make several
/// of them appear as one.
///
/// *(In its older lines the roadmap names `CatalogState` and `AggregateCatalogSource`,
/// following the phone's pattern. Those lines date from 2026-09-07 and are superseded by the
/// decision of 2026-09-11 — amended in place.)*
///
/// ## Three rules, and each has a finding behind it
///
/// **1. The assignment is fixed before anyone asks.** Which source is responsible for an
/// identifier is stated in the identifier — ``Origin/forItem(identifier:)`` reads it off.
/// The finding behind it dates from 2026-09-05 on the phone: the first version looked for
/// the responsible source on *every* title fetch by asking all of them about their
/// state; for the media server that meant six libraries including counts, and the
/// screen said "taking longer than usual".
///
/// **2. A source that does not answer does not take the others down with it.** An
/// expired provider login must not make the media server disappear — that would look
/// like data loss. Applies to the **collecting** queries; a fetch for a specific
/// identifier throws through, because there the failure is the answer to the question
/// asked.
///
/// **3. The order is that of the origins, not that of the response times.** Whoever
/// answers first would otherwise decide anew on every opening what stands at the top.
actor AggregateSource: ContentSource {

    /// The sources, named by ``Origin`` — **each at most once.**
    ///
    /// A dictionary and not a list: the assignment is the core of this class, and a list
    /// would allow two sources of the same origin. Which of the two then answers an
    /// identifier could no longer be said.
    /// **`nonisolated`, and that is not a convenience.** An image address is formed while
    /// every tile is drawn and must not wait for an actor. The assignment is fixed at
    /// construction and never changes — a `let` over `Sendable` values needs no actor, and
    /// a second copy beside it would be a second truth.
    private nonisolated let sources: [Origin: any ContentSource]

    /// **The media server is optional too** (AP29, 2026-09-11).
    ///
    /// Anyone who has set up only a channel list or only the portals has none — and this
    /// class exists for exactly that case. Whatever needs it asks beforehand.
    init(jellyfin: JellyfinSource?, provider: ProviderSource?, portals: PortalSource?) {
        var found: [Origin: any ContentSource] = [:]
        if let jellyfin { found[.jellyfin] = jellyfin }
        if let provider { found[.provider] = provider }
        if let portals { found[.portals] = portals }
        self.sources = found
    }

    /// For tests and for the day a fourth origin is added.
    init(_ sources: [Origin: any ContentSource]) {
        self.sources = sources
    }

    /// The sources this collection carries, **in the fixed order of the origin.**
    ///
    /// For the holder of the library models (``ShellModels``): the collection itself is
    /// recreated on every draw, its components are not. Whether a remembered model still
    /// matches the source is decided by them (check 2026-09-27, D-S4).
    nonisolated var components: [any ContentSource] {
        Origin.allCases.compactMap { sources[$0] }
    }

    /// The existing sources in the order of the origins.
    private var ordered: [(Origin, any ContentSource)] {
        Origin.order.compactMap { origin in
            sources[origin].map { (origin, $0) }
        }
    }

    /// Who answers this identifier — **read off, not asked.**
    /// Asks **all sources at the same time** and returns the answers in ranking order.
    ///
    /// **The finding (2026-09-29, on all devices):** The Home screen stood for a long time
    /// on "loading" and was there immediately after switching the tab. Sources were asked
    /// one by one — Jellyfin, IPTV, then the CL-Server, which for a portal can also take
    /// 20 s. So the wait was for the sum, now it is for the slowest. Anyone who takes
    /// longer than three seconds appears in the report.
    private func perSource<Value: Sendable>(
        _ what: String,
        _ query: @escaping @Sendable (Origin, any ContentSource) async -> Value
    ) async -> [(Origin, Value)] {
        let list = ordered
        return await withTaskGroup(of: (Int, Value).self) { group in
            for (location, (origin, source)) in list.enumerated() {
                group.addTask {
                    let start = Date()
                    let value = await query(origin, source)
                    let duration = Date().timeIntervalSince(start)
                    if duration > 3 {
                        Diagnostics.defect(
                            "Home: \(origin.rawValue) took \(Int(duration)) s for \(what)",
                            since: nil, area: "Startseite")
                    }
                    return (location, value)
                }
            }
            var answers: [(Int, Value)] = []
            for await reply in group { answers.append(reply) }
            return answers.sorted { $0.0 < $1.0 }.map { (list[$0.0].0, $0.1) }
        }
    }

    private func source(forItem identifier: String) -> (any ContentSource)? {
        sources[Origin.forItem(identifier: identifier)]
    }

    private func source(forLibrary identifier: String) -> (any ContentSource)? {
        sources[Origin.forItem(library: identifier)]
    }

    // MARK: - Aggregating queries

    nonisolated var displayName: String { "CineLounge" }

    /// **The safe way, and that is the right answer here.**
    ///
    /// The statement belongs to *one* source — a media server can start further forward when
    /// repacking, a provider cannot. A collection of several cannot answer it without
    /// knowing which title is meant.
    ///
    /// **That is not a shortcoming but the division of labour:** this source collects
    /// lists, it does not play. The player gets the title's source, and that one knows. If
    /// someone does play from here after all, the player seeks by itself — that always
    /// works, it just takes longer.
    nonisolated var canStartAtOffset: Bool { false }

    /// **Each source answers that for itself** — this one keeps nothing, it only
    /// distributes. A wrapper around the collecting source would be the wrong place: it
    /// would then also book for the media server, whose state lies with the server. That is
    /// why each source is wrapped individually before it goes in here.
    nonisolated var tracksStateItself: Bool { true }

    /// All libraries, in the order of the origins.
    ///
    /// **A swallowed error cost a whole evening** (2026-09-12). The secondary sources are
    /// queried with `try?` so that a silent bridge does not take the media server down with
    /// it — correct, and until today **mute**: the Home screen reported "0 levels
    /// reported", and why was written nowhere. The same finding was reported three times,
    /// and I guessed three times.
    ///
    /// **The failure is now written down, not handled.** It is still thrown away — that is
    /// the decision, and it remains right. But a `try?` without a word is information that
    /// nobody receives.
    ///
    /// **The media server no longer takes the others down** (check finding A-S9,
    /// 2026-09-27). Until then its failure threw through, and the whole Home screen stood
    /// there as a fault while the phone kept showing providers, portals and Live
    /// (``CompositeStartSource`` there). Now the same rule applies: **the fault reports itself
    /// when nothing else comes** — then it is not an empty list but an outage, and that
    /// should be reported rather than concealed.
    func libraries() async throws -> [Library] {
        var found: [Library] = []
        var failure: (any Error)?
        let answers = await perSource("Bibliotheken") { _, source -> Result<[Library], any Error> in
            do { return .success(try await source.libraries()) } catch { return .failure(error) }
        }
        for (origin, reply) in answers {
            switch reply {
            case .success(let part):
                found += part
            case .failure(let error) where origin == .jellyfin:
                guard sources.count > 1 else { throw error }
                Diagnostics.network.info(
                    "Aggregate source: media server reports no libraries — \(error)")
                failure = error
            case .failure(let error):
                Diagnostics.network.info(
                    "Aggregate source: \(origin.rawValue) reports no libraries — \(error)")
            }
        }
        if found.isEmpty, let failure { throw failure }
        return found
    }

    /// Started items from **all** origins — `limit` applies per origin.
    ///
    /// **The shared cut at the end is gone** (2026-09-12). Here it said
    /// `Array(found.prefix(limit))`: every origin was asked with the same limit, the
    /// answers concatenated — and then cut off at `limit`. A media server with twelve
    /// started titles thereby filled all twelve places, and **none** from the portal got
    /// through any more. That is exactly the case "started on the phone, continue watching
    /// on the TV", and it was noticed on the device.
    ///
    /// **The same kind of error is already written down twice in this project:**
    /// ``ShelfRule/perOrigin`` names it ("Counted across all, with six libraries and two
    /// provider categories exactly the provider categories dropped out, because they stand
    /// at the back"), and on the phone it was fixed on 2026-09-05. An upper limit that makes the
    /// second service invisible does not protect the line — it hides the service.
    ///
    /// **The phone does it the same way**, line by line: ``CompositeStartSource`` asks every
    /// source with `perShelf` and **appends** ("Merged and not replaced. Two sources can fill
    /// the same fixed shelf — 'Continue Watching' explicitly takes each"). There is no
    /// shared cut there, and now none here either: two apps that fill the same row
    /// differently have no recognisable identity.
    ///
    /// **Deduplicated since AP58 R6** (``Core/ContinueWatching/mix(_:identifier:ersetze:)``):
    /// the same rule as on the phone — a title that two sources report appears once, at the
    /// position of the higher-ranking origin.
    func resumable(limit: Int) async throws -> [MediaItem] {
        var listen: [[MediaItem]] = []
        let answers = await perSource("Weiterschauen") { _, source -> Result<[MediaItem], any Error> in
            do { return .success(try await source.resumable(limit: limit)) } catch {
                return .failure(error)
            }
        }
        for (origin, reply) in answers {
            switch reply {
            case .success(let part): listen.append(part)
            case .failure(let error) where origin == .jellyfin && sources.count == 1:
                throw error
            case .failure: listen.append([])
            }
        }
        return ContinueWatching.mix(listen, identifier: \.id, recent: \.lastWatched)
    }

    func favorites() async throws -> [MediaItem] {
        var found: [MediaItem] = []
        for (origin, source) in ordered {
            if origin == .jellyfin {
                found += try await source.favorites()
            } else {
                found += (try? await source.favorites()) ?? []
            }
        }
        return found
    }

    /// So far only the media server carries collections — all are asked anyway.
    func collections() async throws -> [MediaItem] {
        var found: [MediaItem] = []
        for (_, source) in ordered {
            found += (try? await source.collections()) ?? []
        }
        return found
    }

    // MARK: - Queries about an identifier

    func items(in library: Library.ID, filter: ItemFilter) async throws -> [MediaItem] {
        guard let source = source(forLibrary: library) else { return [] }
        return try await source.items(in: library, filter: filter)
    }

    func itemCount(in library: Library.ID, filter: ItemFilter) async throws -> Int? {
        try await source(forLibrary: library)?.itemCount(in: library, filter: filter)
    }

    func item(id: String) async throws -> MediaItem {
        guard let source = source(forItem: id) else { throw Missing.source(id) }
        return try await source.item(id: id)
    }

    /// Only the media server carries series with releases (AP58 R1, K6).
    func seriesApprovals(forItem allSeries: [String]) async throws -> [SeriesClearance] {
        try await sources[.jellyfin]?.seriesApprovals(forItem: allSeries) ?? []
    }

    func children(of itemID: String) async throws -> [MediaItem] {
        try await source(forItem: itemID)?.children(of: itemID) ?? []
    }

    func seriesReference(zu item: MediaItem) async -> String? {
        await source(forItem: item.id)?.seriesReference(zu: item)
    }

    func removeFromContinueWatching(_ itemID: String) async throws {
        guard let source = source(forItem: itemID) else { throw Missing.source(itemID) }
        try await source.removeFromContinueWatching(itemID)
    }

    func segments(for itemID: String) async throws -> [MediaSegment] {
        try await source(forItem: itemID)?.segments(for: itemID) ?? []
    }

    func streamURL(for itemID: String, decision: PlaybackDecision) async throws -> URL {
        guard let source = source(forItem: itemID) else { throw Missing.source(itemID) }
        return try await source.streamURL(for: itemID, decision: decision)
    }

    func report(progress: PlaybackProgress, for itemID: String, isPaused: Bool) async throws {
        try await source(forItem: itemID)?.report(progress: progress, for: itemID, isPaused: isPaused)
    }

    func setPlayed(_ isPlayed: Bool, for itemID: String) async throws {
        try await source(forItem: itemID)?.setPlayed(isPlayed, for: itemID)
    }

    func setFavorite(_ isFavorite: Bool, for itemID: String) async throws {
        try await source(forItem: itemID)?.setFavorite(isFavorite, for: itemID)
    }

    func trailer(for itemID: String) async throws -> MediaItem? {
        try await source(forItem: itemID)?.trailer(for: itemID)
    }

    func nextEpisode(after itemID: String) async throws -> MediaItem? {
        try await source(forItem: itemID)?.nextEpisode(after: itemID)
    }

    func similarItem(to itemID: String) async throws -> MediaItem? {
        try await source(forItem: itemID)?.similarItem(to: itemID)
    }

    func similarItems(to itemID: String, limit: Int) async throws -> [MediaItem] {
        try await source(forItem: itemID)?.similarItems(to: itemID, limit: limit) ?? []
    }

    func episodes(of seriesID: String) async throws -> [MediaItem] {
        try await source(forItem: seriesID)?.episodes(of: seriesID) ?? []
    }

    func trickplay(for itemID: String) async throws -> Trickplay? {
        try await source(forItem: itemID)?.trickplay(for: itemID)
    }

    func beginSession(for itemID: String) async throws {
        try await source(forItem: itemID)?.beginSession(for: itemID)
    }

    func endSession(for itemID: String, at position: TimeInterval) async throws {
        try await source(forItem: itemID)?.endSession(for: itemID, at: position)
    }

    func reloadContinueWatching() async {
        for (_, source) in ordered { await source.reloadContinueWatching() }
    }

    func refreshAfterPlayback(ids: [String]) async {
        for (origin, source) in ordered {
            let own = ids.filter { Origin.forItem(identifier: $0) == origin }
            guard !own.isEmpty else { continue }
            await source.refreshAfterPlayback(ids: own)
        }
    }

    /// The image address from the source that carries the title.
    nonisolated func imageURL(itemID: String, kind: ImageKind, width: Int, tag: String?) -> URL? {
        // **A finished address is used and not built.** A channel brings its logo as a
        // complete address, a portal the images of its entries — both come from third-party
        // services that assign no identifiers from which anything could be calculated. Without
        // this branch such an address would go through the origin reading, fall through to the
        // media server as "neither of the two forms", and end up as a Jellyfin request to a
        // foreign machine.
        if let done = URL(string: itemID), done.scheme?.hasPrefix("http") == true {
            return done
        }
        return sources[Origin.forItem(identifier: itemID)]?
            .imageURL(itemID: itemID, kind: kind, width: width, tag: tag)
    }

    /// **All sources together, as one stream.**
    ///
    /// Each reports for itself when it has silently replaced a list; the Home screen then
    /// reloads. Which one it was does not matter — everything is reloaded anyway.
    func listChanges() async -> AsyncStream<Void> {
        let sources = ordered.map(\.1)
        return AsyncStream { continuation in
            let task = Task {
                await withTaskGroup(of: Void.self) { group in
                    for source in sources {
                        group.addTask {
                            for await _ in await source.listChanges() {
                                continuation.yield()
                            }
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// When no source is set up for an identifier.
    ///
    /// **An error of its own and not a silent `nil`:** It can only occur when an identifier
    /// points to an origin whose access is missing — for example a portal title from the
    /// history after the bridge was removed. That is information and not nothing.
    enum Missing: Error {
        case source(String)
    }
}
