import Core
import Foundation

/// Holds the ``SeriesEpisodeIndex`` per channel list — on disk and in memory.
///
/// **The display never waits for it.** ``index(for:endpoint:)`` returns what
/// is there — even an old state, even nothing at all — and kicks off the renewal
/// on the side. A grid that waits eight seconds for a directory would be
/// the very disease the directory fights.
///
/// **At most once a day.** A provider's catalog changes in
/// days, not in minutes, and the fetch weighs 11 MB.
///
/// **Re-measured against the account's one-connection limit:** During the eight
/// seconds of download, four `player_api` requests went through alongside, in 0.13 to
/// 0.50 seconds. The limit counts streams, not requests — so the download
/// does not get in the way of browsing.
public actor SeriesEpisodeIndexStore {

    public static let shared = SeriesEpisodeIndexStore()

    /// How long a state counts as fresh.
    public static let maximumAge: TimeInterval = 24 * 3600

    private let directory: URL
    private let session: URLSession

    private var loaded: [String: SeriesEpisodeIndex] = [:]
    /// Is a renewal currently running for this list? Prevents every
    /// opening of a category from triggering its own 11 MB fetch.
    private var refreshing: Set<String> = []

    public init(directory: URL? = nil, session: URLSession? = nil) {
        let base =
            directory
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.directory = base

        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            // Plenty of time: 11 MB over a weak line may take a while.
            config.timeoutIntervalForRequest = 120
            // **Without the system's cache.** The client shares a
            // `URLCache` of 60 MB with all other fetches; 11 MB in it would
            // push out everything else — and the parsed state lies
            // here on disk anyway, at 100 KB instead of 11 MB.
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.urlCache = nil
            self.session = URLSession(configuration: config)
        }
    }

    /// The best available state — immediately, without waiting for the network.
    public func index(for playlistID: String, endpoint: XtreamEndpoint) -> SeriesEpisodeIndex? {
        let current = loaded[playlistID] ?? readFromDisk(playlistID)
        if let current { loaded[playlistID] = current }

        let age = current.map { Date().timeIntervalSince($0.builtAt) } ?? .infinity
        if age > Self.maximumAge { refresh(playlistID, endpoint: endpoint) }

        return current
    }

    /// Fetches the list and parses it — in the background, without slowing anyone down.
    private func refresh(_ playlistID: String, endpoint: XtreamEndpoint) {
        guard !refreshing.contains(playlistID) else { return }
        guard let url = endpoint.playlistURL else { return }
        refreshing.insert(playlistID)

        // **Detached, and that is the whole point** (AP15, 2026-09-02). Here
        // was an ordinary `Task { }` — and a `Task` **inside an
        // actor inherits its isolation**. The network fetch suspends fine, but
        // ``SeriesEpisodeIndex/titles(inPlaylist:)`` afterwards parses eleven megabytes of
        // M3U **on the actor**; while that runs, every
        // ``index(for:endpoint:)`` from the view stands still. The promise at the very top —
        // "The display never waits for it" — was thus exactly backwards.
        //
        // The compiler had been saying it all along: the two `await`s below
        // warned with "no 'async' operations occur within 'await' expression",
        // because they ran **on the same actor** and waited for nothing at all.
        // Now they do.
        let requestAddress = URL(string: endpoint.server.absoluteString + "/get.php") ?? url
        // **And explicitly NOT through the ``ConnectionLock``** (E38 named
        // this openly; decided on 2026-09-09). The thought suggested itself — this
        // fetch is the only one that bypasses it, because it uses its own
        // `URLSession` instead of ``XtreamClient/fetchData(action:extra:)``.
        // It stays outside anyway, for two measured reasons:
        //
        // 1. **It does not interfere.** During the eight seconds of download, four
        //    `player_api` requests went through alongside, in 0.13 to 0.50 seconds — the
        //    account's limit counts streams, not requests (measurement above).
        // 2. **In the gate it would interfere.** Eleven megabytes through the
        //    measured 0.3 Mbit/s of the tunnel is around five minutes, and for that
        //    long every category, every search and every detail page would queue
        //    behind it. A fetch nobody notices would become the
        //    only one everybody notices.
        //
        // **The detail page does not depend on it anyway.** It asks
        // ``XtreamVODSource/episodes(of:)``, and that is `get_series_info` —
        // measured on 2026-09-09 on "Neiscand" 22 616 bytes in 0.35 s, on "Cefeibrem
        // Klimuma" with seven seasons 327 674 bytes in 0.37 s. This
        // directory marks only the **grid**, and nobody waits on it
        // there.
        Task.detached { [session] in
            defer { Task { await self.finishRefresh(playlistID) } }
            do {
                Diagnostics.attempt(requestAddress, step: "Episode index")
                let (data, response) = try await session.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    // `884` was the answer with which this provider blocked `get.php`
                    // for months. Not an app bug — just no
                    // directory, and then everything stays colorful.
                    Diagnostics.verbose(
                        "Episode index: provider answers with "
                            + "\((response as? HTTPURLResponse)?.statusCode ?? -1)"
                    )
                    return
                }
                let titles = SeriesEpisodeIndex.titles(inPlaylist: data)
                let index = SeriesEpisodeIndex(titles: titles, builtAt: Date())
                guard index.isUsable else {
                    Diagnostics.verbose(
                        "Episode index discarded: only \(titles.count) titles from "
                            + "\(data.count) bytes — below the threshold of "
                            + "\(SeriesEpisodeIndex.minimumUsable)"
                    )
                    return
                }
                Diagnostics.verbose(
                    "Episode index: \(titles.count) series with episodes from \(data.count) bytes"
                )
                await self.adopt(index, for: playlistID)
            } catch {
                // The fetch goes to `get.php?username=…&password=…` — the raw
                // error would carry the address along.
                Diagnostics.verbose("Episode index unreachable: \(Diagnostics.explain(error))")
            }
        }
    }

    private func finishRefresh(_ playlistID: String) {
        refreshing.remove(playlistID)
    }

    private func adopt(_ index: SeriesEpisodeIndex, for playlistID: String) {
        loaded[playlistID] = index
        writeToDisk(index, playlistID)
    }

    // MARK: - Platte

    /// A file name from the list identifier — it can contain anything.
    private func fileURL(_ playlistID: String) -> URL {
        let safe = playlistID.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return directory.appendingPathComponent("cinelounge-folgen-\(String(safe)).json")
    }

    private struct Stored: Codable {
        let titles: [String]
        let builtAt: Date
    }

    private func readFromDisk(_ playlistID: String) -> SeriesEpisodeIndex? {
        guard let data = try? Data(contentsOf: fileURL(playlistID)),
            let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return nil }
        return SeriesEpisodeIndex(titles: Set(stored.titles), builtAt: stored.builtAt)
    }

    private func writeToDisk(_ index: SeriesEpisodeIndex, _ playlistID: String) {
        let stored = Stored(titles: Array(index.titles), builtAt: index.builtAt)
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? data.write(to: fileURL(playlistID), options: .atomic)
    }
}
