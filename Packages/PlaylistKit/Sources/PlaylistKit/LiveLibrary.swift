import Core
import Foundation

/// All stored channel lists as **one** collection.
///
/// This is the bracket around ``M3UChannelSource``, ``XtreamClient`` and
/// ``PlaylistStore``: It loads every enabled list, merges the channels
/// and returns them organized by group. The UI thereby sees
/// only one collection and does not need to know how many sources it comes from.
///
/// **Lists are loaded side by side, not one after another.** With four lists
/// at two seconds of waiting each, that would otherwise be eight seconds during which the
/// screen stays empty. And a list that does not answer must not hold the others
/// up — that is why each is considered on its own, and a failure
/// only shrinks the result.
public actor LiveLibrary {

    /// Channels of a group, for display.
    public struct Group: Identifiable, Sendable, Equatable {
        public let id: String
        public let name: String
        public let channels: [Channel]

        public init(id: String, name: String, channels: [Channel]) {
            self.id = id
            self.name = name
            self.channels = channels
        }
    }

    /// What went wrong while loading, per list.
    ///
    /// Delivered along instead of thrown: With four lists of which one stalls, you
    /// want to see the others **and** know that one is missing. A thrown error
    /// would show nothing at all, a concealed one would feign completeness.
    public struct LoadIssue: Sendable, Equatable {
        public let playlistID: String
        public let playlistName: String
        public let messageKey: String
    }

    public struct Result: Sendable, Equatable {
        public let channels: [Channel]
        public let groups: [Group]
        public let issues: [LoadIssue]

        public var isEmpty: Bool { channels.isEmpty }
    }

    private let store: PlaylistStore
    /// The matching source for each list. Built once and kept — each carries
    /// its own cache.
    private var sources: [String: any ChannelSource] = [:]
    private var lastResult: Result?

    /// The air times per channel — stored as an **operation**, not as a result.
    ///
    /// The difference matters when scrolling through: Focus moves faster than
    /// the provider answers, and the view asks for the same channel a second
    /// time while the first fetch is still running. A result store would
    /// still be empty at that point and would send a second fetch after it.
    /// The operation, by contrast, is already there, and the second asker attaches to it.
    private var programmeTasks: [String: Task<[Programme], Error>] = [:]

    /// The parsed XMLTV file per list, likewise as an operation. Rationale
    /// at ``guide(for:at:)``.
    private var guideTasks: [String: Task<[String: [Programme]], Error>] = [:]

    /// For fetching the XMLTV file. Generous timeout as when fetching the
    /// channel list: Such files are tens of megabytes and arrive slowly.
    private let session: URLSession

    /// The stock on disk. Injectable, so that checks get their own
    /// database in memory — otherwise a check would see the channels
    /// of the previous one and fail randomly.
    private let cache: LiveCache

    /// Who computes the schedule — an actor of its own, so that this one
    /// does not stand around meanwhile. Rationale at ``ScheduleCalculator``.
    private let calculator = ScheduleCalculator()

    /// Where the broadcast plan comes from.
    ///
    /// As a property and not hard-wired, because a second source is meant to
    /// be added here (Germany is open as of 2026-08-29) — and because a
    /// check would otherwise have to go onto the network.
    private let scheduleSource: any BroadcastScheduleSource

    /// The ``Core/ChannelLock`` — **asked afresh on every delivery**, so that a
    /// flipped switch applies without reloading. Injectable for checks; the default reads
    /// the store of both devices (``Core/ChannelLock/stored(store:keychain:)``).
    private let lock: @Sendable () -> ChannelLock

    public init(
        store: PlaylistStore, cache: LiveCache = .shared,
        scheduleSource: any BroadcastScheduleSource = SporEkraniSource(),
        lock: @escaping @Sendable () -> ChannelLock = { ChannelLock.stored() }
    ) {
        self.store = store
        self.cache = cache
        self.scheduleSource = scheduleSource
        self.lock = lock

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        self.session = URLSession(configuration: config)
    }

    // MARK: - Auslieferung

    /// **Every channel that leaves this library goes through here** (Live check,
    /// finding 1, 2026-09-27) — the ``Core/ChannelLock``, both rules about
    /// adult channels. **Exactly once and on the full catalog**: The block measures
    /// which list flags, and a filtered catalog would look like one without.
    ///
    /// **At delivery and not when merging:** The remembered catalog
    /// (`lastResult`) stays unfiltered, so that a flipped switch applies on the next query
    /// and not only after a fetch from the provider. The groups are derived
    /// anew, otherwise an empty group of a hidden list would stand in the bar.
    ///
    /// A guard (`ChannelSourceFilterTests`) checks that every public query for
    /// channels goes through here or through ``load(forceReload:)``.
    private func delivered(_ result: Result) -> Result {
        let filtered = delivered(result.channels)
        guard filtered.count != result.channels.count else { return result }
        return Result(channels: filtered, groups: Self.groups(from: filtered), issues: result.issues)
    }

    private func delivered(_ channels: [Channel]) -> [Channel] {
        lock().filter(channels)
    }

    // MARK: - Laden

    /// The catalog of all enabled lists — **filtered** (``delivered(_:)``).
    public func load(forceReload: Bool = false) async -> Result {
        delivered(await loaded(forceReload: forceReload))
    }

    /// The catalog as loaded — **unfiltered, only for this library.**
    private func loaded(forceReload: Bool) async -> Result {
        // **The remembered catalog is delivered, but its favorite markers are set
        // afresh.** The two belong apart: The channels themselves come from the provider and
        // may be two minutes old — with 5389 entries over a thin line
        // anything else would be unusable. The marker, by contrast, is set by the viewer just
        // now, and it lives with us.
        //
        // Without this refresh a marked channel stayed invisible in the
        // favorites area: The store knew about it, the delivered catalog did not. From
        // the outside it looked as if the marker landed "somewhere else".
        if !forceReload, let lastResult {
            return await refreshedFavorites(in: lastResult)
        }

        let playlists = await store.enabledPlaylists
        guard !playlists.isEmpty else {
            let empty = Result(channels: [], groups: [], issues: [])
            lastResult = empty
            return empty
        }

        // **First the stock, then the network** (roadmap P8.1): What was fetched
        // last time lies on disk and is there in
        // milliseconds. The fetch from the provider runs anyway — it
        // replaces the catalog as soon as it arrives. Without this head start one saw
        // nothing for seconds with 5389 channels over a thin line.
        if !forceReload {
            var stored: [String: [Channel]] = [:]
            for playlist in playlists {
                let channels = await cache.channels(for: playlist.id)
                if !channels.isEmpty { stored[playlist.id] = channels }
            }
            if !stored.isEmpty {
                let merged = await store.merged(stored)
                let result = Result(
                    channels: merged, groups: Self.groups(from: merged), issues: [])
                lastResult = result
                // **Reload only if the stock is really old.** A
                // fetch of 5389 channels is the most expensive of the whole app; starting it
                // in the background on every opening of the sidebar
                // meant occupying the line exactly when the
                // Home screen fetches its images (viewer finding 2026-08-08).
                // Channels do not change hourly — six hours is
                // plenty, and the Refresh button fetches immediately at any time.
                if await LiveCache.shared.channelsAreStale() {
                    Task { [weak self] in _ = await self?.load(forceReload: true) }
                }
                return result
            }
        }

        // Load side by side. Each list is considered on its own, so that one that
        // stalls does not hold the others up.
        var loaded: [String: [Channel]] = [:]
        var issues: [LoadIssue] = []

        await withTaskGroup(of: (String, [Channel]?, String?).self) { group in
            for playlist in playlists {
                group.addTask { [weak self] in
                    guard let self else { return (playlist.id, nil, "error.unreachable") }
                    return await self.loadOne(playlist)
                }
            }

            for await (id, channels, errorKey) in group {
                if let channels {
                    loaded[id] = channels
                } else {
                    let name = playlists.first { $0.id == id }?.name ?? id
                    issues.append(
                        LoadIssue(
                            playlistID: id,
                            playlistName: name,
                            messageKey: errorKey ?? "error.unreachable"
                        )
                    )
                }
            }
        }

        let merged = await store.merged(loaded)
        // Clean up favorites of channels that no longer exist — otherwise the
        // list grows with every channel list switched.
        await store.pruneFavorites(against: merged)

        let result = Result(
            channels: merged,
            groups: Self.groups(from: merged),
            issues: issues
        )
        lastResult = result
        return result
    }

    /// Resets the favorite markers of a remembered catalog.
    ///
    /// The store is the truth, not the catalog: The marker survives a
    /// reload and hangs on an ID, not on the order of the
    /// provider. It is computed via the same ID as when enriching — two
    /// versions of it would drift apart as soon as one of them is touched.
    private func refreshedFavorites(in result: Result) async -> Result {
        let marked = await store.favorites

        func marking(_ channels: [Channel]) -> [Channel] {
            channels.map { channel in
                var updated = channel
                updated.isFavorite = marked.contains(PlaylistStore.favoriteKey(for: channel))
                return updated
            }
        }

        return Result(
            channels: marking(result.channels),
            groups: result.groups.map {
                Group(id: $0.id, name: $0.name, channels: marking($0.channels))
            },
            issues: result.issues
        )
    }

    /// A provider — a stored list — with the names of its groups.
    public struct ProviderGroups: Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
        public let groups: [String]

        public init(id: String, name: String, groups: [String]) {
            self.id = id
            self.name = name
            self.groups = groups
        }
    }

    /// The groups per enabled list, in the user's order of rank.
    ///
    /// For the provider level of the sidebar (roadmap P6): With several
    /// lists all channels ran into one collection, and whose "News" group
    /// one was looking at could not be told. It is computed from the
    /// catalog that is loaded anyway — the channels carry their list ID with them.
    ///
    /// A list without channels drops out: It has either failed (then
    /// it is in the ``LoadIssue``s) or is empty — an expandable level
    /// without content would be a promise the app does not keep.
    public func providerGroups() async -> [ProviderGroups] {
        let result = await load()
        var providers: [ProviderGroups] = []

        for playlist in await store.enabledPlaylists {
            let channels = result.channels.filter { $0.playlistID == playlist.id }
            guard !channels.isEmpty else { continue }
            providers.append(
                ProviderGroups(
                    id: playlist.id,
                    name: playlist.name,
                    groups: Self.groups(from: channels).map(\.name)
                )
            )
        }

        return providers
    }

    /// The categories of the media library, across all enabled lists.
    ///
    /// **Xtream only.** An M3U file knows no categories for movies — it carries a
    /// flat list in which movies can at best be recognized by their address. Whoever
    /// has entered only an M3U therefore does not get to see the area at all,
    /// instead of an empty one.
    ///
    /// Merged and ordered by name: With two providers "Action" would otherwise
    /// appear twice one under the other, and which is which could not be seen.
    public func vodCategories() async -> [String] {
        var names: Set<String> = []

        for playlist in await store.enabledPlaylists {
            // Via the same source as the channels: It is already built, carries its
            // cache and the credentials. A second one beside it would mean fetching the
            // password from the store a second time.
            guard let client = try? await source(for: playlist) as? XtreamClient,
                let categories = try? await client.vodCategories()
            else { continue }
            names.formUnion(categories.map(\.name))
        }

        return names.sorted()
    }

    private func loadOne(_ playlist: Playlist) async -> (String, [Channel]?, String?) {
        do {
            let source = try await self.source(for: playlist)
            let channels = Self.usable(try await source.channels())
            // **Into the stock, so that the next start does not wait**
            // (roadmap P8.1): The channels of a group do not change
            // between two glances; fetching them anew on every open means
            // 5389 entries over the line for a list that is already there.
            await cache.save(channels, for: playlist.id)
            return (playlist.id, channels, nil)
        } catch let failure as M3UChannelSource.Failure {
            Diagnostics.defect(
                "Channel list not loaded: \(Diagnostics.explain(failure))", since: nil, area: "Live")
            return (playlist.id, nil, failure.messageKey)
        } catch let failure as XtreamClient.Failure {
            Diagnostics.defect(
                "Channel list not loaded: \(Diagnostics.explain(failure))", since: nil, area: "Live")
            return (playlist.id, nil, failure.messageKey)
        } catch {
            Diagnostics.defect(
                "Channel list not loaded: \(Diagnostics.explain(error))", since: nil, area: "Live")
            return (playlist.id, nil, "error.unreachable")
        }
    }

    /// The source for a list, built or from the catalog.
    private func source(for playlist: Playlist) async throws -> any ChannelSource {
        if let existing = sources[playlist.id] { return existing }

        let source: any ChannelSource
        switch playlist.kind {
        case .m3u(let url):
            source = M3UChannelSource(playlist: playlist, url: url)

        case .xtream(let server, let username):
            // The password is kept separately — hence fetched here from the store and
            // not read from the list.
            guard let password = await store.password(for: playlist.id) else {
                throw XtreamClient.Failure.unauthorized
            }
            source = XtreamClient(
                playlist: playlist,
                credentials: XtreamEndpoint(
                    server: server,
                    username: username,
                    password: password
                )
            )

        case .jellyfinLiveTV:
            // The channel management of the media server. Planned but not yet
            // built — that the case stands here keeps it visible.
            throw XtreamClient.Failure.unreachable
        }

        sources[playlist.id] = source
        return source
    }

    /// Injects the source of a list from outside.
    ///
    /// For checks only. Without this seam every check case would go to the provider, and
    /// the checks would be as reliable as the line to it — with an
    /// access that expires, that is, at some point not at all.
    func install(_ source: any ChannelSource, for playlistID: String) {
        sources[playlistID] = source
    }

    /// What the diagnostics say about a sync of the program guide.
    ///
    /// **Extracted, because the branch is otherwise not testable.** The message
    /// came into being in the middle of ``syncGuide()`` — behind a fetch over the network and
    /// a database on disk. The very branch that names the silent
    /// failure was therefore not producible on the computer; it occurred
    /// on the device (2026-08-16).
    struct GuideReport: Sendable, Equatable {
        let text: String
        let verdict: Diagnostics.ProbeVerdict
    }

    /// The counters of a sync — what was asked, what answered, what arrived.
    struct GuideTally: Sendable, Equatable {
        /// Lists with a guide source that were asked.
        var attempted = 0
        /// Of those, the ones that answered with 200.
        var answered = 0
        /// Xtream-Listen ohne hinterlegten Zugang — dort wurde nichts gefragt.
        var withoutAccess = 0
        /// What the parser read from the files.
        var read = 0
    }

    /// The message about the sync — a pure function over the counters.
    ///
    /// **One chain and not two lines.** Before, in a silent failure
    /// BOTH ran: first the error, then "0 programs in stock" as a check mark below it.
    static func guideReport(tally: GuideTally, stored: Int) -> GuideReport {
        if stored > 0 {
            // **Catalog is not a success of this run.** The stock may be from yesterday;
            // if the fetch fails today, that previously went only to
            // ``Diagnostics/network`` — a pure logger with no line in the trace.
            // The report then showed a check mark over a number that has
            // nothing to do with this run.
            guard tally.attempted > 0, tally.read == 0 else {
                return GuideReport(
                    text: "Program guide: \(stored) programmes in the cache.", verdict: .plain)
            }
            return GuideReport(
                text: "Program guide: \(stored) programmes in the cache, but nothing read "
                    + "this time — \(tally.answered) of \(tally.attempted) sources answered",
                verdict: .problem)
        }
        if tally.read > 0 {
            // Only a total failure is an error: Fewer than read is normal
            // (duplicates in the file, the past is cleared away) — read and
            // NOTHING arrived is the silent failure.
            return GuideReport(
                text: "Program guide: \(tally.read) programmes read, "
                    + "but none arrived in the database",
                verdict: .problem)
        }
        if tally.attempted > 0 {
            // **Not reached is not the same as empty.** "The source delivered
            // no programs" convicted the provider although there
            // was no answer at all — the fetch had failed. Without information, no verdict.
            guard tally.answered > 0 else {
                return GuideReport(
                    text: "Program guide: none of the \(tally.attempted) sources "
                        + "answered — the fetch failed, the guide is not empty",
                    verdict: .problem)
            }
            // The same one level deeper: If only some answered, the
            // accusation "delivered no programs" is unfounded for the silent sources.
            guard tally.answered == tally.attempted else {
                return GuideReport(
                    text: "Program guide: nothing read and nothing in the cache — only "
                        + "\(tally.answered) of \(tally.attempted) sources answered",
                    verdict: .problem)
            }
            return GuideReport(
                text: "Program guide: nothing read and nothing in the cache — "
                    + "the source delivered no programmes",
                verdict: .problem)
        }
        if tally.withoutAccess > 0 {
            // This does not accuse any provider either: Nothing was asked, because the
            // access is missing. It counts as a deficiency anyway — a password that has disappeared from the
            // Keychain would otherwise go unnoticed by everyone.
            return GuideReport(
                text: "Program guide: \(tally.withoutAccess) Xtream list(s) without "
                    + "stored credentials — nothing queried",
                verdict: .problem)
        }
        // **Not a deficiency, but information.** No source was asked
        // here at all; a cross would accuse a provider that nobody called.
        return GuideReport(
            text: "Program guide: no guide source in the active "
                + "lists — nothing queried.",
            verdict: .plain)
    }

    /// Fetches the **complete** program guide of all lists into the stock.
    ///
    /// **The counter-design to the per-channel fetch** (roadmap P8.2): `get_short_epg`
    /// asks for one channel and costs one request on every focus change —
    /// with an access that allows a single connection, this is the
    /// most expensive spot of the app. `xmltv.php` delivers everything at once: for the
    /// tested provider 75 MiB for 610 of the 5389 channels.
    ///
    /// That is why the fetch hangs on the **Refresh button** and not on startup:
    /// Over a thin line it is an operation of minutes that nobody
    /// should trigger casually. It is read in batches into the database — the
    /// file never comes into working memory as a whole.
    ///
    /// - Returns: How many programs were stored.
    @discardableResult
    public func syncGuide() async -> Int {
        // **Whether a query was made, and whether anyone answered.** Without these counters
        // "nothing read" could be told apart neither from "nothing to read" nor from "nobody
        // answered": A pure M3U list falls through at the very beginning
        // at the `continue` and would arrive below with the same zero as a
        // source that has failed — and a source that does not answer at all does
        // not for that reason have an empty guide.
        var tally = GuideTally()

        for playlist in await store.enabledPlaylists {
            guard case .xtream(let server, let username) = playlist.kind else { continue }
            // **A list without a stored access is something other than no source
            // at all.** Both fell through the same `continue`, and the message below
            // afterwards said "no guide source in the active lists" —
            // while a set-up list is there that is only missing its password.
            guard let password = await store.password(for: playlist.id),
                let url = XtreamEndpoint(server: server, username: username, password: password)
                    .guideURL
            else {
                tally.withoutAccess += 1
                continue
            }

            Diagnostics.attempt(url, step: "Fetch program guide")
            tally.attempted += 1
            guard let (file, response) = try? await session.download(from: url),
                (response as? HTTPURLResponse)?.statusCode == 200
            else {
                // Stays as a system line; it contributes nothing to the trace —
                // `network` is a pure logger. The summary below is the
                // only place where this failure appears in the submitted report,
                // and that is why it is counted there.
                Diagnostics.network.error("Program guide unreachable")
                continue
            }
            tally.answered += 1
            defer { try? FileManager.default.removeItem(at: file) }

            // Only the channels of this access: A merged file often carries
            // channels that the access does not have at all — their program would be
            // ballast in the database and computing time when reading.
            let known = Set(
                await cache.channels(for: playlist.id)
                    .compactMap(\.epgID).filter { !$0.isEmpty }
            )

            // The parser expressly does NOT run on the actor: It reads
            // megabytes and calls back per batch; on the actor every query of the
            // view would wait that long.
            //
            // **And expressly not in the cooperative pool** (AP15, 2026-09-02).
            // The backpressure below is right — without it reading would run away from
            // writing and memory would fill up after all —, but it stops
            // the thread, and `Task.detached` runs on exactly the threads that
            // Swift keeps ready for everything concurrent in the app. Their number
            // equals the cores; a blocked one among them is the case
            // that Apple warns about.
            //
            // Today it was harmless, because only **one** sync runs at a time.
            // That is not a property of this place but of the caller —
            // so a trap for the next person who wants to sync two accesses
            // side by side. On a queue of its own, waiting is
            // allowed; there it costs a thread and no guarantee.
            let cache = self.cache
            let counted: Int = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    var written = 0
                    XMLTVParser.parse(fileURL: file, channelIDs: known.isEmpty ? nil : known) {
                        batch in
                        written += batch.count
                        let semaphore = DispatchSemaphore(value: 0)
                        Task {
                            await cache.save(programmes: batch)
                            semaphore.signal()
                        }
                        semaphore.wait()
                    }
                    continuation.resume(returning: written)
                }
            }

            tally.read += counted
        }

        await cache.pruneProgrammes()
        // What is counted is what REALLY lies in the database, not what the
        // parser read: On the device the measurement reported "61,026 in
        // stock" while every store operation failed silently (2026-08-16, Application
        // Support not writable on tvOS) — the lie sent a whole
        // troubleshooting session in the wrong direction.
        let stored = await cache.programmeCount()
        storedGuideKnown = stored > 0 ? true : nil
        // What was fetched individually before the sync is now outdated.
        programmeTasks.removeAll()
        // And the schedule likewise. The key of the result store notices
        // a freshly fetched guide by itself as a rule — count
        // or reach move —, but not necessarily: Whoever delivers the same
        // guide again with corrected titles changes
        // neither number. The viewer pressed a button here
        // and expects a fresh answer; it costs 3.4 s once at
        // device size and happens at most as often as someone presses.
        await calculator.clear()
        await cache.clearSchedules()
        // The wording is produced as a pure function and outside the main thread —
        // there it is testable, in the block below it never was.
        let report = Self.guideReport(tally: tally, stored: stored)
        await MainActor.run {
            Diagnostics.probe(report.text, verdict: report.verdict)
            // **An empty guide belongs in the report** (diagnosis F-025,
            // 2026-09-28): There it said only "Schedule: 0 programs", and why was not
            // said — `probe` stores nothing without the debug switch.
            if stored == 0 {
                Diagnostics.defect(report.text, since: nil, area: "Live")
            }
        }

        // **When that was belongs to the stock.** Without the timestamp the
        // device cannot tell whether the schedule is empty because nothing
        // is on, or because the guide has not been fetched for days — and
        // `syncGuide()` had exactly ONE trigger in the whole project, the
        // button of a single channel list in the settings.
        //
        // **Only if someone answered** (F-025): Otherwise it said "guide less than
        // an hour ago" next to an empty stock, and that read as if nothing
        // were running — when in fact no provider was reachable.
        if tally.answered > 0 {
            await cache.setNote(String(Int(Date().timeIntervalSince1970)), forItem: Self.guideStamp)
        }

        // The fixtures along with it — same occasion, same visibility:
        // Whoever refreshes the guide also gets the sync fresh.
        await syncFixtures()
        // And the living board, in the same motion. Rationale there.
        await maintainChannelBoard()

        return stored
    }

    /// Carries the observations of the living channel board forward and lets them
    /// age.
    ///
    /// **Why here and not in a service alongside** (addendum 2 of
    /// 2026-08-29): There is no server that could do it. The guide is
    /// the viewer's, it lies on their device, and only there is it
    /// complete — a service would know neither which channel list it has nor
    /// what its provider calls the channels. Maintenance therefore happens exactly when
    /// the guide is fetched anyway.
    ///
    /// **Three steps, and the middle one is the important one.** The
    /// whole guide is read, not the day window — the board is meant to learn over
    /// weeks and not via the tab that happens to be open. Evidence
    /// comes only from the strongest evidence — both team names in the title
    /// or the broadcast plan (``SportMatch/observations(fixtures:programmes:channels:broadcastPlan:)``,
    /// which also says why no other stage may write). And
    /// **aging** happens every time: A row that has not been confirmed for sixty days
    /// disappears. This is the automatic maintenance that was
    /// asked for — if a broadcast right moves, the board heals itself
    /// within a few weeks.
    func maintainChannelBoard(now: Date = Date()) async {
        guard SportSyncSettings.load(from: SecureStore()).isEnabled else { return }
        let span = await cache.programSpan()
        guard let from = span.oldest, let until = span.newest else { return }
        let broadcasts = await cache.programmes(from: from, to: until.addingTimeInterval(1))
        let fixtures = await cache.fixtures(from: from, to: until.addingTimeInterval(1))
        let catalog = await cache.channelCompetitions()

        // **The broadcast plan writes along** — and that is the answer to its
        // knowing only today. "Arena Spor 1 showed the Süper Lig"
        // is a fact about the channel, not about the match;
        // after two such days tomorrow's fixture finds its channel from
        // its own observation. In the app, without an outside service.
        let preferences = LivePreferences.load(from: SecureStore())
        let isVisible = Self.visibleIngredients(
            channels: await load().channels, programmes: [], preferences: preferences)
        let fresh = SportMatch.observations(
            fixtures: fixtures, programmes: broadcasts,
            channels: isVisible.sportChannels, broadcastPlan: await cache.broadcastSlots())
        let maintained = SportChannelBoard.aged(
            SportChannelBoard.merged(catalog: catalog, fresh: fresh), now: now)
        await cache.setChannelCompetitions(maintained)
        // New assignments change the schedule without a program
        // being added — the key of the result store does not notice.
        await calculator.clear()
        await cache.clearSchedules()

        let established = maintained.count { $0.match >= SportChannelBoard.minimumDays }
        // What has aged: rows that were there before and are not anymore.
        let survived = Set(maintained.map { $0.channels + "#" + $0.path })
        let dropped = catalog.count { !survived.contains($0.channels + "#" + $0.path) }
        let report =
            "Channel board: \(maintained.count) rows, \(established) of them supporting "
            + "(from \(SportChannelBoard.minimumDays) days) · \(fresh.count) pieces of evidence from "
            + "\(fixtures.count) fixtures · \(max(0, dropped)) aged out"
        await MainActor.run { Diagnostics.probe(report, verdict: .plain) }
    }

    static let guideStamp = "guide.zuletzt"

    /// What the program stock says about itself.
    ///
    /// **Five numbers instead of two** (E1 of the sports concept). The previous
    /// schedule line derived "stock empty or carries" from the number of
    /// *results* — from what was left after all filters. An
    /// empty stock and a filter that eats everything thus looked the same.
    public struct DownloadsState: Sendable, Equatable {
        public let broadcasts: Int
        public let inWindow: Int
        public let oldest: Date?
        public let newest: Date?
        public let lastFetched: Date?
        /// How many fixtures are stored (E6/E7).
        public let fixtures: Int
        /// The latest kickoff in the stock — the reach of the **fixtures**.
        ///
        /// It is not the same as ``newest``: The guide reaches, as
        /// measured, about +24 h; the fixture source is queried over three days.
        /// Since 2026-09-02 the view shows only the next 24 hours
        /// (``Core/SportWindow/lookahead``); the fixtures reaching further
        /// stay in the stock anyway, because the channel board learns from them.
        public let fixturesNewest: Date?

        public init(
            broadcasts: Int, inWindow: Int, oldest: Date?, newest: Date?,
            lastFetched: Date?, fixtures: Int = 0, fixturesNewest: Date? = nil
        ) {
            self.broadcasts = broadcasts
            self.inWindow = inWindow
            self.oldest = oldest
            self.newest = newest
            self.lastFetched = lastFetched
            self.fixtures = fixtures
            self.fixturesNewest = fixturesNewest
        }

        public var isEmpty: Bool { broadcasts == 0 }
    }

    public func downloadsState(from start: Date, to end: Date) async -> DownloadsState {
        let span = await cache.programSpan()
        let fixtures = await cache.fixtureSpan()
        let stamp = await cache.note(Self.guideStamp).flatMap(Double.init)
        return DownloadsState(
            broadcasts: span.count,
            inWindow: await cache.programCount(from: start, to: end),
            oldest: span.oldest,
            newest: span.newest,
            lastFetched: stamp.map { Date(timeIntervalSince1970: $0) },
            fixtures: fixtures.count,
            fixturesNewest: fixtures.newest
        )
    }

    /// Fills the store from the stock — **without network, without reloading**.
    ///
    /// **So that the Live area is already there on first entry.** Without it
    /// the view builds its list only when it is opened; with a
    /// database on disk that is needless waiting. Expressly without
    /// the question of age: A fetch from the provider has no business at startup
    /// — that is exactly what the Home screen has choked on twice already
    /// (2026-08-01 and 2026-08-08).
    public func warmFromStore() async {
        guard lastResult == nil else { return }
        let merged = await rawDownloads()
        guard !merged.isEmpty else { return }
        lastResult = Result(channels: merged, groups: Self.groups(from: merged), issues: [])
    }

    /// The channels from the stock — **and expressly no fetch, under no circumstances.**
    ///
    /// ``load(forceReload:)`` also delivers the stock first, but goes onto the network
    /// if nothing is stored, and kicks off a sync if the stock is old.
    /// For the Home screen both are wrong: **It is the first screen, and whatever holds
    /// it up holds up the whole app** — that is exactly what it choked on twice
    /// (2026-08-01 and 2026-08-08). If nothing is there, nothing is there; the shelf is then left out.
    public func downloadedChannels() async -> [Channel] {
        delivered(await rawDownloads())
    }

    /// The stock unfiltered — for ``warmFromStore()``, which fills the remembered catalog.
    private func rawDownloads() async -> [Channel] {
        var stored: [String: [Channel]] = [:]
        for playlist in await store.enabledPlaylists {
            let channels = await cache.channels(for: playlist.id)
            if !channels.isEmpty { stored[playlist.id] = channels }
        }
        guard !stored.isEmpty else { return [] }
        return await store.merged(stored)
    }

    /// The program of many channels at once — **only from the stock**.
    ///
    /// Expressly without network: The list asks this for everything that
    /// is currently visible. If a fetch were possible, a group with a hundred
    /// channels would produce exactly the flood of requests that the stock is
    /// meant to abolish. What is not stored stays empty — the row then
    /// simply shows no program title.
    ///
    /// **`nonisolated`, and a stubborn finding hung on it** (2026-08-08: on
    /// the first call nothing is shown, on the second everything is there): This query
    /// needs nothing from the library except the stock, which has an
    /// actor of its own. Bound to this one, it still had to queue
    /// behind everything that was currently running — and when the app opens,
    /// the channel catalog runs here, five thousand entries long. The program thus came
    /// only when that was done; on the second open it was.
    ///
    /// Without the binding the query goes straight to the stock and is
    /// answered in milliseconds, no matter what the library is doing.
    /// The program of a **time window**, re-keyed to the
    /// channel ID — the source of the grid (AP14).
    public nonisolated func storedProgrammes(
        for channels: [Channel], from start: Date, to end: Date
    ) async -> [String: [Programme]] {
        let ids = channels.compactMap(\.epgID).filter { !$0.isEmpty }
        guard !ids.isEmpty else { return [:] }

        let byEPG = await cache.programmes(epgIDs: ids, from: start, to: end)
        guard !byEPG.isEmpty else { return [:] }
        return byEPG
    }

    public nonisolated func storedProgrammes(
        for channels: [Channel], at date: Date = Date()
    )
        async -> [String: [Programme]]
    {
        let ids = channels.compactMap(\.epgID).filter { !$0.isEmpty }
        guard !ids.isEmpty else { return [:] }

        let byEPG = await cache.programmes(epgIDs: ids, around: date)
        guard !byEPG.isEmpty else { return [:] }

        // Re-key to the channel ID: The view knows its rows by
        // channel ID, and two channels may share the same
        // program ID — HD and FHD of the same channel do that.
        var result: [String: [Programme]] = [:]
        for channel in channels {
            guard let epgID = channel.epgID, let listing = byEPG[epgID] else { continue }
            result[channel.id] = listing
        }
        return result
    }

    /// Whether any program lies in the stock at all.
    ///
    /// Asked once and kept: The answer changes only on sync,
    /// and it is in the way on every focus change — a count over
    /// a hundred thousand rows is cheap, but not free.
    public func hasStoredGuide() async -> Bool {
        if let storedGuideKnown { return storedGuideKnown }
        let has = await cache.hasProgrammes()
        storedGuideKnown = has
        return has
    }

    private var storedGuideKnown: Bool?

    /// Discards what was loaded. Needed after a change to the lists.
    ///
    /// The air times go with it: They hang on channel IDs, and after a
    /// changed list the same ID can denote a different channel.
    /// If it stayed, the view would show a foreign program — an error
    /// that nobody recognizes as such because it looks plausible.
    /// **`async` since E5**, and not out of convenience: The result store
    /// of the schedule lives in an actor of its own, and a `Task` pushed after
    /// might have emptied it only after the view had
    /// asked again. All callers were in `await` anyway.
    public func invalidate() async {
        sources.removeAll()
        lastResult = nil
        programmeTasks.removeAll()
        guideTasks.removeAll()
        // The schedule hangs on the channels: Their names carry the
        // channel signal, and the events carry their IDs. If the
        // result store stayed, the area would show, after a changed
        // list, the schedule of the old one — an error that nobody recognizes
        // as such because it looks plausible.
        await calculator.clear()
        await cache.clearSchedules()
    }

    // MARK: - Sendezeiten

    /// What is on this channel and what comes after.
    ///
    /// **It is fetched per channel, not for all.** For the test provider the
    /// complete guide file is 75 MiB for 610 usable of 5389 channels; over
    /// the measured 0.3 Mbit/s of the tunnel that would be an operation of 33 minutes.
    /// Xtream can do it individually (`get_short_epg`), XMLTV cannot — see
    /// ``guide(for:at:)``.
    ///
    /// **A failure yields an empty list, not an error.** A channel without
    /// a program is the normal case and not the exception: Only 11 percent of the
    /// tested channels find any entry at all. The view leaves the row
    /// out then. A thrown error would force it to treat this normal case like a
    /// fault, and the viewer would see a message
    /// for almost every channel.
    ///
    /// The return value is ordered by start time. The view shows "now playing"
    /// and "next" and relies on it; XMLTV guarantees no order.
    /// The live sports broadcasts of a time window — for the schedule.
    ///
    /// Reads the whole day from the program stock and lets ``SportPlan``
    /// compute; the channel names help the detection ("NBA Arena" tells
    /// the sport when the title is silent). Without a filled stock an
    /// empty list comes back — the area then says that the program guide
    /// must be fetched first.
    /// **The computing happens elsewhere** (E5, 2026-08-29). Here the whole chain stood in the
    /// body of the actor, and an actor handles one request after
    /// another: As long as the pattern detection ran — measured at device size
    /// 3.4 s, before E5 7.4 s —, nobody else got an answer, not even the
    /// channel list in a completely different area. This spot now fetches
    /// only the ingredients and frees the actor; the full rationale
    /// is at ``ScheduleCalculator``.
    ///
    /// And it computes **at most once per state of the stock**: Whoever switches the
    /// tab back and forth gets the second answer for free,
    /// without a query and without computing.
    public func sportEvents(from start: Date, to end: Date) async -> [SportEvent] {
        // Switchable (Settings → Live): Then it stays at the suggestion. The
        // switch belongs in the key — whoever flips it gets a
        // different list from the same stock, and a store that conceals this
        // would show the old schedule for no reason.
        let syncEnabled = SportSyncSettings.load(from: SecureStore()).isEnabled
        let span = await cache.programSpan()
        let scheduleKey = ScheduleCalculator.Key(
            from: start, end: end, broadcasts: span.count, newest: span.newest,
            syncEnabled: syncEnabled)

        // **The disk first** (on-device finding 2026-08-29: reloading on every open
        // is unwanted, since the program run does not change over the course
        // of the day). The store from E5 lived only in working memory
        // and was gone on quitting; it saved the second
        // tab switch, not the second start — and opening happens more often
        // than switching.
        //
        // Same key, same guarantee: If window, count and
        // reach of the stock and the switch do not change, the answer
        // cannot be a different one. What the key does NOT see — fresh fixtures,
        // a newly delivered guide with the same numbers — is
        // discarded by hand, at exactly the same places as in working memory.
        if let stored = await cache.schedule(scheduleKey.identifier) {
            return stored
        }

        let computedValue = await calculator.events(scheduleKey) { [weak self] in
            guard let self else {
                return ScheduleCalculator.Ingredients(
                    broadcasts: [], channelNames: [:], fixtures: [], channels: [],
                    observations: [], broadcastPlan: [])
            }
            return await self.ingredients(from: start, to: end, syncEnabled: syncEnabled)
        }
        await cache.setSchedule(computedValue, forItem: scheduleKey.identifier)
        return computedValue
    }

    /// What the computation needs from the stock — fetched only on a failure of the
    /// result store.
    private func ingredients(
        from start: Date, to end: Date, syncEnabled: Bool
    ) async -> ScheduleCalculator.Ingredients {
        let preferences = LivePreferences.load(from: SecureStore())
        let isVisible = Self.visibleIngredients(
            channels: await load().channels,
            programmes: await cache.programmes(from: start, to: end),
            preferences: preferences)

        return ScheduleCalculator.Ingredients(
            broadcasts: isVisible.broadcasts,
            channelNames: isVisible.names,
            fixtures: syncEnabled ? await cache.fixtures(from: start, to: end) : [],
            channels: isVisible.sportChannels,
            observations: syncEnabled ? await cache.channelCompetitions() : [],
            broadcastPlan: syncEnabled ? await cache.broadcastSlots() : [])
    }

    /// What the schedule may see of the catalog at all.
    ///
    /// **Only the visible channels** (on-device finding 2026-08-29: some groups
    /// are hidden, currently only Turkish and German groups are
    /// available — so sports should consider only the
    /// visible ones; French or Portuguese channels are not needed).
    ///
    /// The filter has stood since 2026-08-29 at the channel list and at the
    /// player's overlay, and it stood expressly as a rule at the
    /// **source** instead of at every view — precisely so that it is not
    /// forgotten at a third place. Here it was, nonetheless. The same lesson
    /// for the second time, and that is why it stands here once more.
    ///
    /// **Both ingredients, not just the channel list.** The sport detection
    /// and the placeholder stage read the *programs*; a program of a
    /// hidden channel would otherwise still bring its row along, only without a
    /// channel beneath it. Measured on the guide of 2026-08-29: 492 channels and
    /// 230 events without the filter, 276 and 152 with it.
    ///
    /// **But only what IS hidden.** A program whose channel the app
    /// does not know at all stays — otherwise a catalog that is not yet loaded
    /// would empty the whole schedule.
    ///
    /// **A function of its own and not lines in the body**, because ``ingredients``
    /// touches the Keychain and the disk and is therefore not testable.
    /// The rule here is.
    static func visibleIngredients(
        channels: [Channel], programmes: [Programme], preferences: LivePreferences
    ) -> (broadcasts: [Programme], names: [String: String], sportChannels: [SportChannel]) {
        let isVisible = preferences.isVisible(channels)

        var names: [String: String] = [:]
        var visibleIdentifiers: Set<String> = []
        for channel in isVisible {
            guard let epg = channel.epgID, !epg.isEmpty else { continue }
            visibleIdentifiers.insert(epg)
            if names[epg] == nil { names[epg] = channel.name }
        }

        // **What is thrown away is what IS hidden — not what is unknown.**
        // The first attempt filtered the programs against the visible
        // IDs, and that was too sharp: As long as the channel list is not yet
        // loaded (first start, fetch failed), it is empty, and
        // then the whole schedule would vanish. The checks of E3 showed this
        // immediately — they deliberately build the model without a channel list.
        //
        // An ID counts as hidden if it is in the list and
        // **none** of its versions is visible. If HD and UHD share a
        // program ID and only one of them is hidden, it stays.
        var hiddenIdentifiers: Set<String> = []
        for channel in channels {
            guard let epg = channel.epgID, !epg.isEmpty,
                !visibleIdentifiers.contains(epg)
            else { continue }
            hiddenIdentifiers.insert(epg)
        }

        // Several versions of the same channel (HD/FHD/UHD) share a
        // program ID; for the board that is one, and that is why only the first
        // per key comes along. Otherwise the name search would run several times over
        // the same string.
        var seen: Set<String> = []
        var sportChannels: [SportChannel] = []
        for channel in isVisible {
            let piece = SportChannel(id: channel.id, name: channel.name, epgID: channel.epgID)
            guard seen.insert(piece.key).inserted else { continue }
            sportChannels.append(piece)
        }

        return (programmes.filter { !hiddenIdentifiers.contains($0.channelID) }, names, sportChannels)
    }

    /// Fetches the scheduled matches of the online source into the stock.
    ///
    /// Part of the guide sync, not of opening: The schedule
    /// itself stays networkless. If the source fails, the old catalog
    /// stays — the sync is enrichment, not a prerequisite.
    ///
    /// **Three days ahead** (E6, requirement of 2026-08-29). The provider's guide
    /// reaches about +24 h; the fixture source knows the schedulings
    /// independently of that. What reaches beyond the guide finds
    /// no channel today and therefore appears in no row — it lies in the
    /// stock and waits for E7. No channel is invented.
    ///
    /// **Only one source is ever in the stock.** If ESPN answers, the
    /// fallback's rows go; if the fallback steps in, ESPN's go. Two
    /// catalogs side by side would be the same match twice —
    /// with different IDs, so without any chance of
    /// merging them.
    public func syncFixtures(from start: Date = Date()) async {
        guard SportSyncSettings.load(from: SecureStore()).isEnabled else { return }
        let result = await SportFixtureSource().fixtures(from: start)
        let counter = result.counter

        guard !result.fixtures.isEmpty else {
            await MainActor.run {
                Diagnostics.probe(
                    "Fixture sync: no fixtures — \(counter.report)", verdict: .problem)
            }
            return
        }
        await cache.save(fixtures: result.fixtures, of: counter.source)
        for other in SportFixtureProvider.allCases where other != counter.source {
            await cache.removeFixtures(of: other)
        }
        // **And the broadcast plan in the same motion.** It alone answers
        // the question "which match on which channel" and therefore belongs
        // with the fixtures, not with the guide. If the source does not answer,
        // the previous plan stays — a silent web page is
        // something other than a day without broadcast.
        let slots = await scheduleSource.broadcastSlots()
        await cache.setBroadcastSlots(slots)

        // New fixtures change the schedule without a program
        // being added — the key of the result store does not notice.
        await calculator.clear()
        await cache.clearSchedules()

        // **What is counted is what lies in the database.** Here stood the number
        // of what was fetched, and next to it the comment that this is exactly the
        // mix-up of 2026-08-16. Since E6 the counter exists that it
        // called for.
        let stored = await cache.fixtureCount()
        let report = counter.report
        // **What is counted is what REALLY lies in the database**, not what the
        // source delivered. Exactly this mix-up sent a
        // whole troubleshooting session in the wrong direction on 2026-08-16. ("61,026 in
        // stock" while every store operation failed silently) — and again on 2026-08-29 at
        // 21:25: The line reported "68 broadcasts" while in
        // the board 68 rows with an end time of 1970 lay, and therefore
        // not a single one arrived in the schedule.
        let storedSlots = await cache.broadcastSlots()
        let scheduleCount = storedSlots.count
        let scheduleChannels = Set(storedSlots.flatMap(\.channels)).count
        await MainActor.run {
            Diagnostics.probe(
                "Fixture sync: \(stored) fixtures in the cache · \(report)",
                verdict: counter.isFault ? .problem : .plain)
            Diagnostics.probe(
                "Broadcast schedule: \(scheduleCount) broadcasts on \(scheduleChannels) channels",
                verdict: scheduleCount == 0 ? .problem : .plain)
        }
    }

    /// The channels for a program ID — for channel choice and jump-off of the
    /// schedule. Several versions (HD/FHD/UHD) share an ID
    /// and all come back.
    ///
    /// **The channel ID itself counts too:** The League Pass stage of the
    /// sync finds channels WITHOUT a program ID via their name — their
    /// events then carry the channel ID in the place of the
    /// program ID (``SportMatch``).
    public func channels(withEPGIDs ids: [String]) async -> [Channel] {
        let wanted = Set(ids.filter { !$0.isEmpty })
        guard !wanted.isEmpty else { return [] }
        return await load().channels.filter { channel in
            if wanted.contains(channel.id) { return true }
            guard let epg = channel.epgID else { return false }
            return wanted.contains(epg)
        }
    }

    public func programmes(for channel: Channel) async -> [Programme] {
        // Without a program ID no query is made. For the test provider 4409 of
        // 5389 channels have none, and the provider answers with an empty
        // list instead of an error — so the request costs only waiting time for
        // a predictably empty result. Without this condition, scrolling through
        // produces a flood of fetches of which nine tenths deliver
        // nothing, and the one fetch that matters is queued behind them.
        guard let epgID = channel.epgID, !epgID.isEmpty else { return [] }

        // **The stock first** (roadmap P8.2): After a sync the
        // program of all channels lies on disk — then this question costs one
        // millisecond instead of a request to the provider, who allows only a single
        // connection.
        let stored = await cache.programmes(epgID: epgID, around: Date())
        if !stored.isEmpty { return stored }

        // **And once the stock is there, it is the truth.** If program lies in
        // the database but none for this channel, then it has none —
        // the provider delivers it in the same file. Without this line
        // the app would ask the provider again for each of the 4779 channels without program
        // on every focus change and wait for a
        // predictably empty result (viewer finding 2026-08-08: it should
        // be there immediately).
        if await hasStoredGuide() { return [] }

        // A running or completed operation serves this asker as well.
        if let running = programmeTasks[channel.id] {
            return (try? await running.value) ?? []
        }

        // The operation is created and stored **before** anything is
        // awaited here. Even looking up the list is a hop to the
        // main strand and thus a gap in which a second asker would pass an
        // empty store — when scrolling, exactly that happens, and it
        // would result in two fetches for the same channel. That is why the lookup
        // too stands inside the operation and not before it.
        let task = Task { try await self.fetchProgrammes(for: channel, epgID: epgID) }
        programmeTasks[channel.id] = task

        do {
            return try await task.value
        } catch {
            Diagnostics.verbose("Programme for \(channel.id) not fetched: \(Diagnostics.explain(error))")
            // The failure is **not** kept. Its most frequent cause is
            // the line, not the channel; if the failed operation
            // stayed, this channel would show no program until the next reload,
            // although it would long be retrievable again. Only the
            // creator may remove it — as long as its entry stands, no second operation
            // arises that it could accidentally clear away.
            programmeTasks.removeValue(forKey: channel.id)
            return []
        }
    }

    /// What can go wrong here without it being a fault.
    private enum GuideFailure: Error {
        /// The channel's list is no longer stored. Happens when the
        /// user deletes it while its channels are still on screen.
        /// Thrown instead of returned empty, so that the operation does not stay lying around as a valid
        /// "this channel has no program".
        case unknownPlaylist
    }

    private func fetchProgrammes(for channel: Channel, epgID: String) async throws -> [Programme] {
        guard let playlist = await store.playlist(withID: channel.playlistID) else {
            throw GuideFailure.unknownPlaylist
        }

        let found: [Programme]

        switch playlist.kind {
        case .xtream:
            let source = try await self.source(for: playlist)
            found = try await source.programmes(for: channel.id, around: Date())

        case .m3u:
            // An M3U carries no air times. Where the provider names an XMLTV file
            // for it, its address is on the list; without it there is nothing
            // to fetch, and the request does not happen.
            guard let epgURL = playlist.epgURL else { return [] }
            found = try await guide(for: playlist, at: epgURL)[epgID] ?? []

        case .jellyfinLiveTV:
            found = []
        }

        return found.sorted { $0.start < $1.start }
    }

    /// The XMLTV file of a list, ordered by program ID.
    ///
    /// **Once per list, not once per channel.** XMLTV has no query for
    /// a single channel: There is exactly one file, and it contains everything. Fetching it
    /// anew on every focus change would mean pulling the same megabytes
    /// over the line four hundred times. That is why it is read once,
    /// stored by program ID and served from memory afterwards.
    ///
    /// **An empty result stays**, unlike a failure: A file
    /// that yields nothing yields nothing on the second read either — and the second
    /// attempt costs not one request but the full fetch.
    ///
    /// **Filtering is not done when reading**, although ``XMLTVParser`` could. The
    /// filter would need the IDs of all channels of the list, and those are only
    /// settled once loading has happened. A file that was filtered with the currently known
    /// catalog would be empty for every channel added later — and a
    /// channel without program looks like a deficiency of the provider, not like an
    /// error here.
    private func guide(for playlist: Playlist, at url: URL) async throws -> [String: [Programme]] {
        if let running = guideTasks[playlist.id] { return try await running.value }

        let session = self.session
        let task = Task { try await Self.loadGuide(from: url, session: session) }
        guideTasks[playlist.id] = task

        do {
            return try await task.value
        } catch {
            // As with the air times: A failure does not stay.
            guideTasks.removeValue(forKey: playlist.id)
            throw error
        }
    }

    /// Fetches and parses an XMLTV file without blocking the actor.
    ///
    /// `nonisolated` and via a file, both for the same reason: A
    /// program guide for four hundred channels over a week easily has 50 MB.
    /// Fetching it as `Data` would put it completely into the working memory of a
    /// device that shares it with the player; parsing it on the actor
    /// would also stop the reloading of the channel list during that time.
    private nonisolated static func loadGuide(
        from url: URL,
        session: URLSession
    ) async throws -> [String: [Programme]] {
        let file: URL
        let isOurs: Bool

        if url.isFileURL {
            // A file in the file system — for example one that the user puts there themselves.
            // It does not belong to us and is therefore not deleted.
            file = url
            isOurs = false
        } else {
            Diagnostics.attempt(url, step: "Fetch program guide")

            let (downloaded, response) = try await session.download(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                Diagnostics.network.error("Program guide answered with \(http.statusCode)")
                throw M3UChannelSource.Failure.unreachable
            }

            // The downloaded file belongs to the system and disappears as soon as
            // the fetch is cleared away. Move first, then parse.
            let own = FileManager.default.temporaryDirectory
                .appendingPathComponent("cinelounge-epg-\(UUID().uuidString).xml")
            try FileManager.default.moveItem(at: downloaded, to: own)
            file = own
            isOurs = true
        }

        defer {
            if isOurs { try? FileManager.default.removeItem(at: file) }
        }

        let programmes = XMLTVParser.parse(fileURL: file)
        return Dictionary(grouping: programmes, by: \.channelID)
    }

    // MARK: - Gliederung

    /// Arranges channels by groups.
    ///
    /// The order of the groups follows **first appearance**, not the
    /// alphabet: Providers sort their lists deliberately — domestic before foreign,
    /// general-interest before niche channels. Ordering alphabetically would throw this work
    /// away and put "ZDF" after "Animal Planet".
    ///
    /// Channels without a group go into one of their own, **at the end**. Mixing them into the first
    /// would be wrong; searching for them where they do not belong costs
    /// more time than one additional row.
    public static func groups(from channels: [Channel]) -> [Group] {
        var order: [String] = []
        var buckets: [String: [Channel]] = [:]
        var ungrouped: [Channel] = []

        for channel in channels {
            guard let name = channel.group?.trimmingCharacters(in: .whitespaces),
                !name.isEmpty
            else {
                ungrouped.append(channel)
                continue
            }

            if buckets[name] == nil {
                buckets[name] = []
                order.append(name)
            }
            buckets[name]?.append(channel)
        }

        var result = order.map { name in
            Group(id: name, name: name, channels: buckets[name] ?? [])
        }

        if !ungrouped.isEmpty {
            result.append(Group(id: "", name: "", channels: ungrouped))
        }
        return result
    }

    /// Takes out what is not a channel at all.
    ///
    /// Group headings are removed here a second time, although the
    /// Xtream parsing already sorts them out. The reason is the other source: In
    /// an M3U list the same rows appear — for the test provider 113 of 5389 —,
    /// and the parser there does not know them. This spot is the only one through
    /// which **every** list passes. Whoever lets them pass gets entries that,
    /// on a button press, play a black picture.
    public static func usable(_ channels: [Channel]) -> [Channel] {
        channels.filter { !$0.isSectionMarker }
    }

    /// What the viewer may see according to their settings.
    ///
    /// **One place for both conditions**, and the order is irrelevant,
    /// because ``LivePreferences/allows(group:isAdult:)`` checks them together. Applied
    /// separately, the error would be preprogrammed: One view applies the
    /// group selection, the search only the adult block — and a channel that
    /// shows up in the search but is in no list looks like an error of the
    /// app.
    ///
    /// Deliberately here and not at loading: What is loaded stays loaded. If
    /// the viewer changes the setting, the view must filter anew and not
    /// fetch the list again — with 5389 channels over a narrow line that is the
    /// difference between instant and half a minute.
    public static func visible(
        _ channels: [Channel],
        preferences: LivePreferences
    ) -> [Channel] {
        channels.filter { preferences.allows(group: $0.group, isAdult: $0.isAdult) }
    }

    /// The favorites across all lists, as a group of their own.
    ///
    /// At the very top, because they are the reason one sets favorites: With
    /// four hundred channels one does not want to search for one's ten.
    public static func favorites(from channels: [Channel]) -> Group? {
        let marked = channels.filter(\.isFavorite)
        guard !marked.isEmpty else { return nil }

        return Group(id: "favorites", name: "", channels: marked)
    }
}
