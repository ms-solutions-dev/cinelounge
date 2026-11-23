import Core
import Foundation

/// Talks to a provider using the Xtream protocol.
///
/// Network access lives here, the **parsing** in ``XtreamPayload`` — separated
/// so that it can be tested without a network. Tests that depend on the network fail
/// for no reason sooner or later, and then nobody believes them anymore.
public actor XtreamClient: ChannelSource {

    public enum Failure: Error, Equatable {
        /// Username or password rejected, or the account has expired.
        case unauthorized
        /// The account is valid, but blocked or over its limit. The provider
        /// reports this specifically, and it asks something different of the user than a
        /// wrong password — hence a case of its own.
        case accountDisabled
        case unreachable
        /// Response in an unexpected form. Happens when there is no
        /// Xtream provider behind the address at all, but an error page, say.
        case malformed

        public var messageKey: String {
            switch self {
            case .unauthorized: "error.xtreamUnauthorized"
            case .accountDisabled: "error.xtreamDisabled"
            case .unreachable: "error.unreachable"
            case .malformed: "error.xtreamMalformed"
            }
        }
    }

    public let playlist: Playlist
    private let credentials: XtreamEndpoint
    private let session: URLSession

    /// Fetched channels. Re-fetching a list of four hundred channels on every opening
    /// is the most common complaint about comparable apps.
    private var cachedChannels: [Channel]?

    /// The categories of the library, fetched once.
    ///
    /// At the provider they change at most daily, and the sidebar asks for them
    /// on every expand. Without this store, a movement that
    /// is made constantly would send out a request every time — to an account that allows one
    /// connection.
    private var cachedVODCategories: [XtreamVOD.Category]?
    /// **Separate from the movie cache**, because Xtream keeps them separately: A panel
    /// with 24 movie categories has 24 different ones for series, and the identifiers
    /// overlap. Held in one field, the second fetch would overwrite the first.
    private var cachedSeriesCategories: [XtreamVOD.Category]?
    private var cachedCategories: [String: String] = [:]

    /// The texts of the sorted-out group headings, in the order of the
    /// list. Reasoning at ``XtreamPayload/sectionTitles(in:)``.
    public private(set) var sectionTitles: [String] = []

    public init(playlist: Playlist, credentials: XtreamEndpoint) {
        self.playlist = playlist
        self.credentials = credentials

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 25
        // Responses are large and rarely change. The system's cache takes
        // care of that without us having to manage it.
        config.urlCache = URLCache(
            memoryCapacity: 4 * 1024 * 1024,
            diskCapacity: 200 * 1024 * 1024,
            diskPath: "cinelounge.xtream"
        )
        self.session = URLSession(configuration: config)
    }

    // MARK: - Sender

    public func channels() async throws -> [Channel] {
        if let cachedChannels { return cachedChannels }

        // Categories first: Without them every channel would have no group, and with
        // four hundred channels without structure you find nothing.
        let categories = try await fetchCategories(action: "get_live_categories")
        let streams: [XtreamPayload.LiveStream] = try await fetch(action: "get_live_streams")

        let channels = streams.compactMap { stream in
            XtreamPayload.channel(
                from: stream,
                categories: categories,
                playlistID: playlist.id,
                credentials: credentials
            )
        }

        // The number of sorted-out entries belongs in the log. With the test provider it is
        // 113 of 5389 — whoever recounts a channel list and finds 5276 should
        // find the explanation instead of suspecting an error.
        if channels.count < streams.count {
            Diagnostics.network.info(
                "Xtream: \(streams.count - channels.count) of \(streams.count) entries are not channels"
            )
        }

        cachedCategories = categories
        cachedChannels = channels
        sectionTitles = XtreamPayload.sectionTitles(in: streams)
        return channels
    }

    /// The program guide of one channel.
    ///
    /// **One channel per fetch, via `get_short_epg` with `stream_id` and `limit`.**
    /// With the test provider that is not a subtlety but the difference between
    /// usable and unusable: Its complete program file comprises 243277
    /// programs in 75 MiB, and over the measured 0.3 Mbit/s of the tunnel that
    /// would be a process of 33 minutes — for 610 channels, out of 5389, that find any
    /// entry at all. A fetch per channel, by contrast, costs a few
    /// kilobytes, and only for the one you are watching.
    ///
    /// The path via XMLTV remains alongside (``XMLTVParser``): For
    /// M3U lists it is the only one, because there is no per-channel interface
    /// there.
    ///
    /// Title and description arrive Base64-encoded — see
    /// ``XtreamPayload/programs(from:channelID:)``.
    public func programmes(for channelID: String, around date: Date) async throws -> [Programme] {
        // Our channel identifier contains the list identifier. The query
        // needs the number the provider uses.
        guard let streamID = XtreamPayload.streamID(fromChannelID: channelID) else {
            return []
        }

        // Without a guide identifier there is nothing to fetch. In this case the provider answers
        // with an empty list under `epg_listings` and not with
        // an error — checked in the recording. The request is skipped here
        // anyway: 4409 of the 5389 channels have no identifier, and over the
        // tunnel every request costs a wait for a result that is
        // predictably empty. Only if the channel list is not yet loaded
        // is a request made — then it is not known whether an identifier exists.
        if let cachedChannels, let channel = cachedChannels.first(where: { $0.id == channelID }),
            channel.epgID == nil
        {
            return []
        }

        let payload: XtreamPayload.EPGResponse = try await fetch(
            action: "get_short_epg",
            extra: ["stream_id": String(streamID), "limit": String(Self.epgEntryLimit)]
        )

        // Evaluated over the whole response and not line by line. Whether a
        // provider sends its titles in Base64 is decided by the
        // response: A single plain-text title can by itself be valid
        // Base64 — `Film`, for instance, can be decoded and yields three
        // control characters. Queried line by line, exactly there gibberish would come out instead
        // of the program name, and only for individual programs, which makes the
        // error practically unfindable. Reasoning and measurement at
        // ``XtreamPayload/isEncoded(_:)``.
        return XtreamPayload.programmes(from: payload.epgListings ?? [], channelID: channelID)
    }

    /// How many programs are fetched per channel.
    ///
    /// 24 covers more than a day with the test provider and stays under ten
    /// kilobytes. Fetching more helps nobody: The channel view shows "on
    /// now" and "next", and whoever wants to scroll further would rather wait briefly
    /// again than long at every channel.
    static let epgEntryLimit = 24

    public func invalidateCache() {
        cachedChannels = nil
        // The movie cache was missing here until 2026-09-07 — "reload" fetched channels and
        // series categories fresh and kept serving the movie categories from memory.
        cachedVODCategories = nil
        cachedSeriesCategories = nil
        cachedCategories = [:]
        sectionTitles = []
        session.configuration.urlCache?.removeAllCachedResponses()
    }

    // MARK: - Verify access

    /// Checks the account and reports what the provider says about it.
    ///
    /// Specifically before saving a new account: It is better to show the error
    /// on entry than later with an empty channel list, where it
    /// looks like an app bug.
    public func verify() async throws -> XtreamPayload.AccountInfo {
        let payload: XtreamPayload.LoginResponse = try await fetch(action: "")

        guard let info = payload.userInfo else { throw Failure.malformed }
        guard info.auth == 1 else { throw Failure.unauthorized }

        // "Expired" and "Banned" differ clearly for the user from
        // a typo in the password.
        if let status = info.status?.lowercased(), status != "active" {
            throw Failure.accountDisabled
        }
        return info
    }

    // MARK: - Abruf

    // MARK: - Filme und Serien on demand

    /// The categories of the provider's library — "Action", "New 2026" and so on.
    ///
    /// **Separate from the channels, and that is no formality.** A channel runs
    /// now and has no end; a movie has a runtime, poster and progress
    /// you want to keep. Throwing them into one pot would mean having to distinguish in the UI
    /// everywhere what is to be distinguished once here.
    ///
    /// The fetch is small: It delivers only the categories, not their content. With a
    /// provider with 27558 movies that is the difference between a response in
    /// half a second and one of nine megabytes.
    public func vodCategories() async throws -> [XtreamVOD.Category] {
        if let cachedVODCategories { return cachedVODCategories }

        let list: [XtreamPayload.Category] = try await fetch(action: "get_vod_categories")
        let categories = list.compactMap { raw -> XtreamVOD.Category? in
            guard let id = raw.categoryID, let name = raw.categoryName, !name.isEmpty else {
                return nil
            }
            return XtreamVOD.Category(id: id, name: name)
        }

        cachedVODCategories = categories
        return categories
    }

    /// The categories of the provider's **series**.
    ///
    /// **A fetch of its own, not a by-product of ``vodCategories()``.** Xtream
    /// keeps `get_series_categories` separate from `get_vod_categories`, with its
    /// own number range — with the test provider 24 categories here as there, and
    /// "427" means something different for series than for movies. Whoever merged both lists
    /// would show movies once and series once under "Netflix Produktion",
    /// depending on who fetched last.
    ///
    /// As with the movies the fetch is small: only the categories, not their
    /// content. With 7419 series that is the difference between half a
    /// second and several megabytes.
    public func seriesCategories() async throws -> [XtreamVOD.Category] {
        if let cachedSeriesCategories { return cachedSeriesCategories }

        let list: [XtreamPayload.Category] = try await fetch(action: "get_series_categories")
        let categories = list.compactMap { raw -> XtreamVOD.Category? in
            guard let id = raw.categoryID, let name = raw.categoryName, !name.isEmpty else {
                return nil
            }
            return XtreamVOD.Category(id: id, name: name)
        }

        cachedSeriesCategories = categories
        return categories
    }

    private func fetchCategories(action: String) async throws -> [String: String] {
        let list: [XtreamPayload.Category] = try await fetch(action: action)
        return Dictionary(
            list.compactMap { category in
                category.categoryID.map { ($0, category.categoryName ?? "") }
            },
            // Duplicate category identifiers occur; the first wins.
            uniquingKeysWith: { first, _ in first }
        )
    }

    func fetch<T: Decodable>(action: String, extra: [String: String] = [:]) async throws -> T {
        let data = try await fetchData(action: action, extra: extra)
        do {
            return try XtreamPayload.decoder.decode(T.self, from: data)
        } catch {
            // The beginning of the response helps find the cause — but only after
            // removing the password that sits in addresses within it.
            let head = String(data: data.prefix(300), encoding: .utf8) ?? ""
            let safeHead = credentials.redacted(head)
            Diagnostics.network.error(
                "Xtream: unexpected response to \(action, privacy: .public) — \(safeHead, privacy: .public)"
            )
            throw Failure.malformed
        }
    }

    /// The raw response of a query — for the parsers in ``XtreamVOD``.
    ///
    /// Separate from the decoding ``fetch(action:extra:)``, because the
    /// panels' VOD responses are too messy for `Decodable`: Numbers arrive
    /// as text, lists as dictionaries, depending on PHP's mood. ``XtreamVOD``
    /// therefore parses them itself — and needs the bytes for that, not a
    /// finished model.
    ///
    /// **Through the ``ConnectionLock`` and not around it.** This is the
    /// only place where all queries of this protocol converge —
    /// channels, categories, titles, episodes and the account check. A queue
    /// further up (say in a view) would only ever see its own part,
    /// and the rest would keep running in parallel against an account with **one**
    /// allowed connection. Reasoning and measurement are at the gate.
    func fetchData(action: String, extra: [String: String] = [:]) async throws -> Data {
        guard let url = credentials.apiURL(action: action, extra: extra) else {
            throw Failure.unreachable
        }

        return try await ConnectionLock.shared.finished(credentials.accountIdentifier) {
            try await self.fetch(url: url, action: action)
        }
    }

    /// The network fetch itself — behind the gate.
    private func fetch(url: URL, action: String) async throws -> Data {
        // For the log without credentials — it is enough to know which
        // query ran.
        Diagnostics.attempt(
            URL(string: credentials.server.absoluteString + "/player_api.php") ?? url,
            step: "Xtream: \(action.isEmpty ? "Anmeldung" : action)"
        )

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse else { throw Failure.unreachable }

            switch http.statusCode {
            case 200: break
            case 401, 403: throw Failure.unauthorized
            default:
                // **512 means "already busy".** The status code is not one from the
                // standard but the one with which these panels reject a second simultaneous
                // connection. Since the ``ConnectionLock`` it should not
                // actually occur here anymore — if it still shows up in the log, a
                // second device is on the same account, and that is different information from
                // "unreachable". For the viewer it stays the same: There is nothing
                // they could do that a separate error case could tell them.
                let extras = http.statusCode == 512 ? " — access currently in use elsewhere" : ""
                Diagnostics.network.error(
                    "Xtream answered with \(http.statusCode) to \(action, privacy: .public)\(extras, privacy: .public)"
                )
                throw Failure.unreachable
            }

            return data
        } catch let failure as Failure {
            throw failure
        } catch {
            let reason = Diagnostics.explain(error)
            Diagnostics.network.error(
                "Xtream unreachable at \(action, privacy: .public): \(reason, privacy: .public)"
            )
            throw Failure.unreachable
        }
    }
}
