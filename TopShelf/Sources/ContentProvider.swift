import Core
import Foundation
import ParentalControls
// `@preconcurrency`, because TVServices does not yet declare its return types as
// `Sendable` — without the mitigation Swift 6 rejects the asynchronous
// override of `loadTopShelfContent`.
@preconcurrency import TVServices

/// Supplies the Apple TV Home Screen with real content instead of the brand image.
///
/// The extension runs as its own short-lived process: tvOS calls it
/// when CineLounge sits in the top row and the Home Screen wants to fill the
/// upper area. It reads the state stored by the app
/// (``TopShelfBridge``), queries the server once briefly and builds a
/// row from it — Continue Watching, favorites or new arrivals, depending on the setting —, **filtered
/// by the rule of the active profile** (AP52, ``ShelfFilter``).
///
/// **Deliberately without the large packages of the app.** `JellyfinKit` brings
/// cache, reconciliation and playback knowledge along — all things that a
/// process with a budget of seconds should not carry. The three queries here are
/// slim direct fetches with their own small model of the response. `ParentalControls`
/// is added (AP52), because the interpretation of a rating lives there; it depends on `Core`
/// and on nothing else.
final class ContentProvider: TVTopShelfContentProvider {

    // `nonisolated(nonsending)`: since Xcode 27 an asynchronous, non-isolated
    // override counts as `@concurrent`, and a non-`Sendable` result
    // (`TVTopShelfContent`) would not be allowed to cross its boundary — a warning that
    // made the build clean only "without". Staying on the caller means: no boundary.
    nonisolated(nonsending) override func loadTopShelfContent() async -> (any TVTopShelfContent)? {
        guard let context = TopShelfBridge.load(), context.mode != .off else {
            // Without login or switched off: deliver nothing — tvOS then shows
            // the brand image from the app bundle.
            TopShelfBridge.reportExtension(
                "no snapshot (shared group \(TopShelfBridge.sharesKeychain ? "yes" : "no"))")
            return nil
        }

        // **First fetch seven, then shorten** (AP52): the shelf shows the active profile, and for
        // a child what its rule does not show drops out. The query therefore asks for
        // more than the shelf holds — otherwise for a child, after the filter of eight
        // titles, perhaps two would be left, although the server had twenty matching ones.
        //
        // **Jellyfin only if it is included, and the app's contributions on top** (2026-09-28):
        // IPTV VOD and CL-Server come ready-made from the profile's state
        // (``Core/TopShelfContext/extras``). For Continue Watching what ran last counts —
        // regardless of which source, as with Netflix.
        let entries =
            context.jellyfin == nil
            ? [] : await Self.filtered(await Self.entries(for: context), context: context)
        let items = Self.mixed(entries, extras: context.extras ?? [], context: context)
        TopShelfBridge.reportExtension(
            "\(context.mode.rawValue): Jellyfin \(entries.count), App \(context.extras?.count ?? 0), shelf \(items.count)")
        guard !items.isEmpty else { return nil }
        let section = TVTopShelfItemCollection(items: items)
        section.title = Self.sectionTitle(for: context.mode)
        return TVTopShelfSectionedContent(sections: [section])
    }

    // MARK: - Abrufe

    /// The small model of a server response — only what the row needs.
    fileprivate struct Entry: Decodable {
        let id: String
        let name: String?
        let kind: String?
        let seriesName: String?
        /// The series of an episode or season — its rating applies to the episode
        /// (strand K): Jellyfin carries none on episodes.
        let seriesID: String?
        let backdropImageTags: [String]?
        /// The rating in the server's wording — feed for the filter.
        let officialRating: String?
        /// When last watched — for mixing with IPTV and CL-Server (2026-09-28).
        let userData: UserData?

        struct UserData: Decodable {
            let lastPlayedDate: String?
            enum CodingKeys: String, CodingKey { case lastPlayedDate = "LastPlayedDate" }
        }

        enum CodingKeys: String, CodingKey {
            case id = "Id"
            case name = "Name"
            case kind = "Type"
            case seriesName = "SeriesName"
            case seriesID = "SeriesId"
            case backdropImageTags = "BackdropImageTags"
            case officialRating = "OfficialRating"
            case userData = "UserData"
        }
    }

    /// This many titles fit in the row.
    private static let shelfSize = 8

    /// This many are requested — enough that after a child's filter a row
    /// remains, and few enough for a process with a budget of seconds.
    private static let querySize = "40"

    /// What may go on the shelf by the rule of the active profile, at most one row full.
    ///
    /// **The images go with the titles:** a title that drops out here never gets
    /// an image address — so the shelf does not even give away its poster.
    ///
    /// **Episodes inherit the rating of their series** (strand K, 2026-09-25) — via the same
    /// ``Core/SeriesClearances`` as the app's source and with the same rule
    /// (``ParentalControls/ShelfFilter/allows(_:)``): if the lookup fails, the
    /// episode drops out in kids mode. It is only asked if the filter has a limit at all
    /// — an adult costs no additional fetch.
    private static func filtered(_ entries: [Entry], context: TopShelfContext) async -> [Entry] {
        let filter = context.filter
        var title = entries.map(\.title)
        if filter.applies, filter.limit != nil {
            title = await SeriesClearances().complete(title) { allSeries in
                try await seriesApprovals(allSeries, context: context)
            }
        }
        let finished = Set(title.filter(filter.allows).map(\.id))
        return Array(entries.filter { finished.contains($0.id) }.prefix(shelfSize))
    }

    /// The collected fetch of the series ratings — **one** fetch for all series of the row.
    ///
    /// Throws on every deviation instead of returning an empty response: an empty
    /// response would mean "no series found", a throw "not determined" — both lock
    /// in kids mode, but only the throw is asked again at the next visit.
    private static func seriesApprovals(
        _ allSeries: [String], context: TopShelfContext
    ) async throws -> [SeriesClearance] {
        guard let jf = context.jellyfin else { throw URLError(.userAuthenticationRequired) }
        guard
            var components = URLComponents(
                url: jf.server.appending(path: "/Users/\(jf.user)/Items"),
                resolvingAgainstBaseURL: false)
        else { throw URLError(.badURL) }
        components.queryItems = [
            URLQueryItem(name: "Ids", value: allSeries.joined(separator: ",")),
            URLQueryItem(name: "Fields", value: "OfficialRating"),
        ]
        guard let url = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue(jf.tag, forHTTPHeaderField: "X-Emby-Token")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let page = try JSONDecoder().decode(Page.self, from: data)
        return (page.items ?? []).map { SeriesClearance(series: $0.id, approval: $0.officialRating) }
    }

    private struct Page: Decodable {
        let items: [Entry]?

        enum CodingKeys: String, CodingKey {
            case items = "Items"
        }
    }

    private static func entries(for context: TopShelfContext) async -> [Entry] {
        guard let jf = context.jellyfin else { return [] }
        let path: String
        let query: [URLQueryItem]

        switch context.mode {
        case .resume:
            path = "/Users/\(jf.user)/Items/Resume"
            query = [
                URLQueryItem(name: "Limit", value: querySize),
                URLQueryItem(name: "MediaTypes", value: "Video"),
            ]
        case .favorites:
            path = "/Users/\(jf.user)/Items"
            query = [
                URLQueryItem(name: "Recursive", value: "true"),
                URLQueryItem(name: "Filters", value: "IsFavorite"),
                URLQueryItem(name: "IncludeItemTypes", value: "Movie,Series"),
                URLQueryItem(name: "SortBy", value: "SortName"),
                URLQueryItem(name: "Limit", value: querySize),
            ]
        case .latest:
            path = "/Users/\(jf.user)/Items/Latest"
            query = [
                URLQueryItem(name: "Limit", value: querySize),
                URLQueryItem(name: "IncludeItemTypes", value: "Movie,Series"),
            ]
        case .off:
            return []
        }

        guard
            var components = URLComponents(
                url: jf.server.appending(path: path),
                resolvingAgainstBaseURL: false
            )
        else { return [] }
        components.queryItems = query
        guard let url = components.url else { return [] }

        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(jf.tag, forHTTPHeaderField: "X-Emby-Token")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200
        else { return [] }

        // `Latest` answers as a bare list, the others as a page with
        // `Items` — both forms are tried instead of distinguished: the
        // extension should stay empty on a server quirk, not
        // crash.
        if let page = try? JSONDecoder().decode(Page.self, from: data) {
            return page.items ?? []
        }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    // MARK: - Bauen

    /// Jellyfin and the app's contributions in one row, at most one shelf full.
    ///
    /// **For Continue Watching by time**, otherwise Jellyfin first: favorites and
    /// "Recently Added" have no common time by which they could be mixed.
    private static func mixed(
        _ entries: [Entry], extras: [TopShelfEntry], context: TopShelfContext
    ) -> [TVTopShelfSectionedItem] {
        // **Fresh from Jellyfin first, then the app's row** (2026-09-28): the app puts down
        // its "Continue Watching" as it appears on Home — channels, IPTV,
        // CL-Server, Jellyfin too. The extension still asks Jellyfin itself, so that
        // an episode started on the phone is on the shelf without an app launch. The same title
        // twice counts once, with the fresh state.
        var seen = Set<String>()
        var row: [(id: String, when: Date?, item: TVTopShelfSectionedItem)] = []
        for entryItem in entries where seen.insert(entryItem.id).inserted {
            row.append(
                (
                    entryItem.id, entryItem.userData?.lastPlayedDate.flatMap(Self.timestamp(from:)),
                    item(for: entryItem, context: context)
                ))
        }
        for record in extras where seen.insert(record.id).inserted {
            row.append((record.id, record.recent, item(for: record, context: context)))
        }
        if context.mode == .resume {
            // The same ordering as in the app (``Core/ContinueWatching/arrange(_:recent:)``):
            // last watched first, without a time to the back, otherwise stable.
            row = ContinueWatching.arrange(row, recent: \.when)
        }
        return Array(row.prefix(shelfSize).map(\.item))
    }

    /// Jellyfin's timestamp — **with seven fractional digits** (`…:39.8350000Z`), and the
    /// ISO parser with fractions fails on that depending on version. Read without a fraction,
    /// the second suffices for ordering.
    static func timestamp(from text: String) -> Date? {
        let reader = ISO8601DateFormatter()
        reader.formatOptions = [.withInternetDateTime]
        if let point = text.firstIndex(of: ".") {
            let end = text[point...].firstIndex { $0 == "Z" || $0 == "+" || $0 == "-" }
            let without = String(text[..<point]) + (end.map { String(text[$0...]) } ?? "Z")
            return reader.date(from: without)
        }
        return reader.date(from: text)
    }

    /// **The image of the spot where it continues** — the same as in the app (product decision,
    /// 2026-10-01), only for "Continue Watching". It lies in the shared folder of the app group.
    private static func stillFrame(_ identifier: String, context: TopShelfContext) -> URL? {
        guard context.mode == .resume else { return nil }
        return StillFrameStore.address(forItem: identifier, profile: context.profile)
    }

    /// A contribution of the app — image and title are ready in the entry.
    private static func item(
        for entry: TopShelfEntry, context: TopShelfContext
    ) -> TVTopShelfSectionedItem {
        let item = TVTopShelfSectionedItem(identifier: entry.id)
        item.title = entry.title
        item.imageShape = context.mode == .resume ? .hdtv : .poster
        if let image = Self.stillFrame(entry.id, context: context) ?? entry.image {
            item.setImageURL(image, for: [.screenScale1x, .screenScale2x])
        }
        let identifier =
            entry.id.addingPercentEncoding(
                withAllowedCharacters: CharacterSet.urlPathAllowed.subtracting(
                    CharacterSet(charactersIn: "/")))
            ?? entry.id
        if let action = URL(string: "cinelounge://item/\(identifier)") {
            item.displayAction = TVTopShelfAction(url: action)
        }
        return item
    }

    private static func item(for entry: Entry, context: TopShelfContext) -> TVTopShelfSectionedItem {
        let server = context.jellyfin?.server
        let item = TVTopShelfSectionedItem(identifier: entry.id)

        // For an episode the row carries the series name — "Blibiagraik" says more on
        // the Home Screen than "Episode 12".
        item.title = entry.seriesName ?? entry.name

        // Continue Watching shows scene images (16:9), the others posters: a
        // started episode is recognized by the scene, a title by the poster.
        let wide = context.mode == .resume
        item.imageShape = wide ? .hdtv : .poster

        // The image address: scene image from the background where there is one;
        // otherwise the main image. The server delivers images without login —
        // the address therefore carries no access token.
        let imageKind: String
        if wide, entry.kind != "Episode", entry.backdropImageTags?.isEmpty == false {
            imageKind = "Backdrop"
        } else {
            imageKind = "Primary"
        }
        if let stillFrame = Self.stillFrame(entry.id, context: context) {
            item.setImageURL(stillFrame, for: [.screenScale1x, .screenScale2x])
            if let action = URL(string: "cinelounge://item/\(entry.id)") {
                item.displayAction = TVTopShelfAction(url: action)
            }
            return item
        }
        guard var image = server?.appending(path: "/Items/\(entry.id)/Images/\(imageKind)") else {
            return item
        }
        image.append(queryItems: [
            URLQueryItem(name: "maxWidth", value: wide ? "1280" : "600"),
            URLQueryItem(name: "quality", value: "90"),
        ])
        item.setImageURL(image, for: [.screenScale1x, .screenScale2x])

        // Selection opens the app on this title — ``MainView`` knows the path
        // via its own address scheme.
        if let action = URL(string: "cinelounge://item/\(entry.id)") {
            item.displayAction = TVTopShelfAction(url: action)
        }
        return item
    }

    /// The heading of the row, in the device's system language.
    ///
    /// The app has its own language choice, but that lives in its private
    /// settings — here the device language counts. For the three
    /// shipped languages the small table suffices; everything else falls
    /// back to English.
    private static func sectionTitle(for mode: TopShelfMode) -> String {
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        switch (mode, language) {
        case (.resume, "de"): return "Weiterschauen"
        case (.resume, "tr"): return "İzlemeye Devam Et"
        case (.resume, _): return "Continue Watching"
        case (.favorites, "de"): return "Favoriten"
        case (.favorites, "tr"): return "Favoriler"
        case (.favorites, _): return "Favorites"
        case (.latest, "de"): return "Neu hinzugefügt"
        case (.latest, "tr"): return "Yeni Eklenenler"
        case (.latest, _): return "Recently Added"
        case (.off, _): return ""
        }
    }
}

extension ContentProvider.Entry {

    /// The title as ``Core/MediaItem`` — only what the filter asks: identifier, kind, series
    /// and rating. That way supplement and rule run through the **same** functions as in
    /// the app and not through a copy.
    var title: MediaItem {
        let category: MediaItem.Kind =
            switch kind {
            case "Episode": .episode
            case "Season": .season
            case "Series": .series
            case "Video": .homeVideo
            default: .movie
            }
        return MediaItem(
            id: id, kind: category, title: name ?? "", seriesID: seriesID, ageRating: officialRating)
    }
}
