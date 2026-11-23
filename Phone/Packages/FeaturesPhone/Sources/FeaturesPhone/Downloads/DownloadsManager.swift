import Core
import Diagnose
import Downloads
import Foundation
import NetworkStatus
import Observation
import PortalKit

/// Whoever holds, starts and pauses the jobs — **the one place where downloads live.**
///
/// **The address for loading comes from the same resolution as the one for playing.**
/// ``PlayerSource/target(zu:)`` answers the same question for all three sources and, for a
/// portal, even names the deadline. A second resolution chain next to it would be the place
/// where downloads and player drift apart — and you would only notice when a title plays and
/// cannot be downloaded.
///
/// **What this class does not do is move bytes.** That is ``BackgroundSession``, and the
/// separation keeps both testable: here it says which job runs when; there, how a block is
/// fetched.
@Observable
@MainActor
public final class DownloadsManager {

    public private(set) var downloads = Downloads()

    /// The rule under which new jobs start — **one for the app.**
    ///
    /// **It lives here and not per job**, although ``DownloadJob`` carries one. The difference is
    /// deliberate: what hangs on the job is the rule under which it was **accepted**; what stands
    /// here is the one that applies now. Anyone who switches off "Wi-Fi only" in the network sheet
    /// means everything that is running and not just the next one.
    /// Whether the app is currently visible.
    ///
    /// **Anyone who has the app open sees the downloads** — a notification about it would be a
    /// banner above the list that already shows the same thing. It is set by the shell on the
    /// scene change; the manager itself knows no scene and is not meant to learn about one.
    public var isInForeground = true

    public var rule = NetworkRule() {
        didSet { checkAll() }
    }

    /// Who is currently claiming the account's **one** connection.
    ///
    /// **`.unrestricted` by default, and that is not optimism but the only honest default.** Anyone who
    /// defaulted to `.playbackHere` would pause every download as long as nobody objects — and
    /// the objection comes from a screen that does not exist when a test is built. The same
    /// consideration as with ``route``: "not yet reported" is not "the worst case".
    ///
    /// **It is set from outside** — by the shell, which knows whether the player is open, and by
    /// the ``SecondScreen``, which knows whether something is playing on the TV. As long as nobody
    /// does that, the consideration only takes effect via ``occupiedSince``, that is, only after the
    /// provider itself has reported "busy". That is less than half the battle and still the
    /// measured difference between "does not load" and "loads": the collision of 2026-09-09 was a
    /// download against its **own** format probe, not against a player.
    public var claim: ConnectionScarcity.Claim = .unrestricted {
        didSet { checkAll() }
    }

    /// When the provider last answered "busy" — `nil` means **"never"**.
    ///
    /// **One number for the app and not one per job.** The limit hangs on the **account**; two jobs
    /// that kept it separately would know nothing about each other and would run straight into the
    /// collision this number prevents.
    @ObservationIgnored private var occupiedSince: Date?

    /// The tasks that restart a waiting job after the grace period.
    ///
    /// **They live here so that they do not multiply.** Without the table, every "busy" reply would
    /// create another sleeping task, and after ten blocks ten of them would nudge the same job —
    /// exactly the request storm the provider answers with an IP throttle.
    @ObservationIgnored private var trailingJobs: [DownloadJob.Identifier: Task<Void, Never>] = [:]

    /// Which queued titles the **local** history lists as watched.
    ///
    /// **Local, and that is the whole reasoning on this screen.** Downloads are the only area that
    /// can do anything offline; a question "have I watched this" that went to a server would be
    /// unanswerable on a plane — and "Remove watched" would thus be dead exactly where cleanup
    /// happens.
    ///
    /// **The limit comes with it:** ``History`` holds twenty entries. Anyone who watched a queued
    /// film and then played twenty other things will not find it here any more — it can still be
    /// removed individually. The alternative would be a second memory next to the history, and then
    /// there would be two truths about what someone has watched.
    public private(set) var watchedIDs: Set<DownloadJob.Identifier> = []

    /// Catches up the watch state — **when downloads appear.**
    public func readWatched() async {
        let history = await HistoryStore.shared.load()
        watchedIDs = Self.watchedSet(in: history, under: downloads.items)
    }

    /// **Origin and identifier together.** Two services can assign the same number; matching on the
    /// bare identifier would remove the wrong title — and exactly the one nobody has watched.
    nonisolated static func watchedSet(
        in history: History, under items: [DownloadJob]
    ) -> Set<DownloadJob.Identifier> {
        let finished = Set(
            history.entries
                .filter { ($0.progress ?? 0) >= PlaybackReporter.watchedFraction }
                .map { "\($0.origin.rawValue):\($0.identifier)" })
        return Set(
            items
                .filter {
                    let origin = PlaybackJob.origin(zu: $0.id.rawValue)
                    return finished.contains("\(origin.rawValue):\($0.id.rawValue)")
                }
                .map(\.id))
    }

    // MARK: - Topping up

    /// The standing orders — **at most one per series.**
    public private(set) var standingOrders: [StandingOrder] = []

    /// Whether anything has ever finished at all.
    ///
    /// **The precondition for "Queue next" being offered.** A standing order is a commitment about
    /// bandwidth and space; anyone who has never seen a finished download cannot judge it.
    public var hasLocalDownloads: Bool {
        downloads.items.contains { DownloadState.forItem($0.id, in: downloads) == .isHere }
    }

    /// Switches the standing order for a series on or off.
    ///
    /// **Off by default, and switching off throws nothing away.** Anyone who switches it off wants
    /// no new episodes any more — not to lose the ones that are already here. A switch that deletes
    /// when switched off is two actions with one name.
    public func setQueueNewEpisodes(_ on: Bool, forItem series: String, for job: DownloadJob) {
        standingOrders.removeAll { $0.series == series }
        if on {
            standingOrders.append(
                StandingOrder(
                    series: series, source: job.source, tier: job.tier,
                    rule: job.rule))
        }
        ledger?.writeReplenishment(standingOrders)
    }

    /// Runs all standing orders — **fetch and discard in one pass.**
    ///
    /// **It is triggered when downloads appear and not when a download finishes.** What is to be
    /// queued next is decided by the **watch state** and not by the download state: more is queued
    /// because someone has watched an episode. A trigger at the end of a transfer would therefore
    /// regularly hit nothing and miss exactly the case it exists for.
    ///
    /// **Without a detail source nothing happens.** A series' episode list is the only information
    /// this rule needs; guessing it would mean fetching episodes that do not exist.
    public func queueNewEpisodes() async {
        guard let detail, !standingOrders.isEmpty else { return }
        for duration in standingOrders {
            guard let content = try? await detail.detailInfo(zu: duration.series) else { continue }
            perform(duration, content: content)
        }
    }

    private func perform(_ duration: StandingOrder, content: DetailContent) {
        var details: [String: (EpisodeInfo, Season)] = [:]
        var episodes: [Replenishment.Episode] = []
        for season in content.seasons {
            for info in season.episodes {
                details[info.id] = (info, season)
                episodes.append(.init(identifier: info.id, seen: info.seen))
            }
        }

        let plan = Replenishment.plan(
            episodes: episodes, inDownloads: Set(downloads.items.map(\.id.rawValue)))
        for identifier in plan.discard { remove(.init(identifier)) }
        for identifier in plan.fetch {
            guard let (info, season) = details[identifier] else { continue }
            let runtime = info.duration ?? Replenishment.episodeLength
            let job = duration.job(
                identifier: identifier, title: info.title,
                beside: content.title.tile.title,
                extent: .episode(season: season.id, number: info.number ?? 0),
                bytes: TimeEstimate.bytes(
                    forItem: runtime, mbit: DownloadChoice.mbit(duration.tier ?? SelectionRule.suggestion)))
            // **The series travels along.** It is known here (the standing order hangs on it), and without
            // it ``describe(_:resolve:)`` would have to look up the series page first — for
            // information that stands one line further up.
            create(job, resolve: PlaybackJob(identifier: identifier, series: duration.series))
        }
    }

    /// The storage state — **how much lies here and how much is still free.**
    ///
    /// **Since 2026-09-09 it is also displayed.** Until then the sheet "For the trip" was the **only**
    /// caller; with it, the last real computation would have disappeared from the download path,
    /// and the storage line in the header would have kept showing "· Zero KB free" — which, as
    /// checking showed, it already did before. Now ``DownloadsModel/household`` reads through to here.
    public var household: StorageBudget {
        StorageBudget(
            items: [LineItem(kind: .downloads, bytes: downloads.bytes)],
            unrestricted: StorageUsage.unrestricted() ?? 0)
    }

    /// **After a rule change every job is judged again.** Otherwise one would keep running and the
    /// other would not, depending on when it was accepted — and the switch would look as if it
    /// sometimes works.
    /// Judges every job again — **even if not the rule but the path has changed.**
    ///
    /// **The second finding of 2026-09-08:** ``rule`` triggered this on every change, the **network
    /// path** on none. "Resuming happens by itself" is what the "Wi-Fi only" switch promises
    /// precisely for the case that the **situation** fits again — and the situation changed without
    /// anyone looking. Anyone who left the apartment and came back found their downloads paused.
    ///
    /// It is called by the shell, which observes the path anyway.
    public func recheck() { checkAll() }

    private func checkAll() {
        for job in downloads.items {
            var withNewRule = job
            withNewRule.rule = rule
            switch rule.verdict(forItem: route) {
            case .halted(let reason):
                runs[job.id]?.cancel()
                runs[job.id] = nil
                setState(job.id, .idle(reason))
            case .isRunning:
                if case .idle = DownloadState.forItem(job.id, in: downloads) {
                    // **Via ``resume(_:)`` and not via ``start(_:)``.**
                    //
                    // **The finding of 2026-09-08, caught by the check step:** After a restart the job is in the
                    // ledger, but the **resolution** is not — it is built from the identifier, and only
                    // `resume` does that. `start` found none and reported "without resolution" before anyone
                    // had pressed anything. Exactly the path that is supposed to deliver "resuming happens by
                    // itself" therefore broke at the first network change after a restart.
                    resume(job.id)
                }
            }
        }
    }

    /// The sources are **replaceable and the manager is not** — the lesson of 2026-09-09, and it
    /// cost a whole evening of downloads.
    ///
    /// **The finding, in one line:** There were **two** managers, and both wrote to the same
    /// ledger. Measured with a trace that numbers each manager:
    ///
    ///     Ledger trace: manager 1 created, 1 read
    ///     Ledger trace: manager 1 writes 2 items
    ///     Ledger trace: manager 2 created, 2 read
    ///
    /// **Where the second came from:** `ShellView` creates its model as
    /// `State(initialValue: ShellModel(…))`. SwiftUI **keeps** the first instance of it — but it
    /// **evaluates** the expression on every rebuild of the view. The second instance is thus
    /// thrown away, and its `init` has long since built a manager of its own. That one lives on,
    /// keeps its own job list and writes the shared file on every change.
    ///
    /// **What that does:** Anyone who queues a title via the visible manager is in its list and in
    /// the ledger. As soon as the invisible one notices anything — a measured size is enough — it
    /// writes **its** state over it. The title has vanished from the ledger, the half-loaded file
    /// still lies there and belongs to nobody. This is exactly the picture the product owner
    /// reported on 2026-09-09: a queued download simply vanished. On disk, `jobs.json` lay there as `[]` next
    /// to four `.part` files.
    ///
    /// **That is why ``DownloadsHolder`` holds exactly one manager**, and a rebuild of the sources
    /// swaps them in here instead of replacing the manager. A second writer on the same file is not
    /// an error you carefully work around — it is one you make impossible.
    private var source: any PlayerSource
    /// Where the suggestions come from — **`nil` as long as nothing is set up.**
    private var start: (any StartSource)?
    /// Where a series' episode list comes from — only for ``queueNewEpisodes()``.
    private var detail: (any DetailSource)?
    private var networkMonitor: NetworkStatus.NetworkWatch?
    private let folder: URL?

    /// Accepts new sources — **without touching the jobs.**
    ///
    /// **Running blocks keep running.** They hang on a ``PlaybackSourceAddress`` that was built when
    /// the job started and holds on to its source; the next job takes the new one. That is the
    /// difference from the previous build, which threw away the whole manager: there a download
    /// lost its list on every setup change — and at startup, where nothing had changed at all,
    /// too.
    ///
    /// **The network guard is not swapped** (check Shell H2, 2026-09-27). One manager, one guard —
    /// the first it received. Until then every discarded `ShellModel` replaced it with its own,
    /// never started one: ``isNetworkReported`` then stayed false forever, new jobs rested, and ``route``
    /// was always `.wifi` — "Wi-Fi only" did not take effect on cellular, while the network sheet
    /// showed the real guard.
    func adopt(
        source: any PlayerSource, start: (any StartSource)?, detail: (any DetailSource)?,
        external: (any RatingSource)?, networkMonitor: NetworkStatus.NetworkWatch?
    ) {
        self.source = source
        self.start = start
        self.detail = detail
        self.external = external
        if self.networkMonitor == nil { self.networkMonitor = networkMonitor }
    }

    /// Where the ratings come from — **`nil` as long as none is set up.**
    ///
    /// **Nothing is broken without it.** The media server's ratings sit on the ``DetailContent``
    /// anyway and are stored along with it; this source buys the more precise information (IMDb,
    /// Metacritic), not the information itself — the same rule as at
    /// ``SourceAssembly/ratingsSource()``.
    private var external: (any RatingSource)?

    /// What lies next to the file — ledger and images.
    @ObservationIgnored private let descriptions: DescriptionLedger?
    @ObservationIgnored private let frames: DownloadImages?
    /// The series already looked up — **one query per series and session.**
    @ObservationIgnored private let seriesApprovals = SeriesClearances()

    /// Backfills the series approval of old episode downloads — see ``SeriesClearanceBackfill``.
    /// Nothing without a media server or without a ledger.
    public func backfillSeriesClearances() async {
        guard let descriptions, let server = SourceAssembly.jellyfin() else { return }
        await SeriesClearanceBackfill.backfill(
            in: descriptions, approvals: seriesApprovals,
            fetch: SeriesClearanceBackfill.fetch(about: server))
    }

    /// The running tasks — at most one per job.
    @ObservationIgnored private var runs: [DownloadJob.Identifier: Task<Void, Never>] = [:]
    /// The playback job with which a download job is resolved.
    @ObservationIgnored private var resolutions: [DownloadJob.Identifier: PlaybackJob] = [:]

    /// The ledger in which the jobs survive a restart.
    @ObservationIgnored private let ledger: DownloadLedger?

    public init(
        source: any PlayerSource, start: (any StartSource)? = nil,
        detail: (any DetailSource)? = nil, external: (any RatingSource)? = nil,
        networkMonitor: NetworkStatus.NetworkWatch? = nil
    ) {
        self.source = source
        self.start = start
        self.detail = detail
        self.external = external
        self.networkMonitor = networkMonitor
        let folder = try? Store.folder()
        self.folder = folder
        self.ledger = folder.map { DownloadLedger(folder: $0) }
        self.descriptions = folder.map { DescriptionLedger(folder: $0) }
        self.frames = folder.map { DownloadImages(folder: $0) }
        Self.counted += 1
        self.number = Self.counted
        fetch()
        Diagnose.step(
            .downloads, "Ledger trace: manager \(number) created, \(downloads.items.count) read")
    }

    /// How many managers this program run has built so far — **for the trace only.**
    private static var counted = 0
    /// The own number, so that a line in the ledger says WHO wrote.
    private let number: Int

    /// **What comes out of the ledger at startup — and what follows from it.**
    ///
    /// Every job whose file is not finished is then set to `idle` and is **not** started by itself.
    /// That is deliberate: "Resuming happens by itself" is what the "Wi-Fi only" switch promises
    /// for the case that the **rule** applies again — not that the app takes bandwidth on every
    /// start without anyone having looked. Anyone who opens downloads sees them and presses once;
    /// and ``rule`` nudges them as soon as the situation changes.
    private func fetch() {
        guard let ledger, let folder else { return }
        downloads.items = ledger.read()
        standingOrders = ledger.readReplenishment()
        for job in downloads.items {
            let writer = PartialWriter(folder: folder, identifier: job.id)
            guard !writer.isFinished else { continue }
            setState(job.id, .idle(nil))
        }
    }

    private func memorize() {
        Diagnose.step(
            .downloads, "Ledger trace: manager \(number) writes \(downloads.items.count) entries")
        ledger?.write(downloads.items)
    }

    /// The network path under which judging currently happens.
    ///
    /// **"Not yet measured" counts as Wi-Fi and not as airplane mode** — the finding of 2026-09-08, and
    /// it cost the whole download path. `NetworkWatch.route` starts at `.none`, and `NWPathMonitor`
    /// only reports a moment after startup. Anyone who queued a title in that gap got "Paused — no
    /// network" immediately, although the library next to it was loading just fine.
    ///
    /// **The default without a guard was always `.wifi`** — with a guard and no report it was the
    /// opposite. Two answers to the same question, and the pessimistic one applied in operation, of
    /// all places.
    private var route: NetworkPath {
        guard let networkMonitor, networkMonitor.reported else { return NetworkPath(kind: .wifi) }
        return networkMonitor.route
    }

    /// Whether the network guard has spoken at all yet.
    ///
    /// **The startup race, found on 2026-09-09** In the simulator, under "Floupruk Saisjo piki beflund
    /// Skausehaum'm Cosler", `network("CancellationError()")` stood in red at "720 MB · 0 KB" — zero
    /// bytes, because it was cancelled while still resolving.
    ///
    /// The sequence, step by step: ``route`` returns `.wifi` as long as `NetworkWatch.reported` is false
    /// (with good reason — see there). The job starts. Milliseconds later `NWPathMonitor` reports,
    /// the shell calls ``recheck()``, the verdict is now `.halted` — and the still-open
    /// address resolution is cancelled. The viewer sees an error where a rule took effect.
    ///
    /// **The decision: in this gap nothing is started, it waits.** The job is set to `.idle(nil)`,
    /// and the first report nudges it. That costs a fraction of a second and only for the very
    /// first job after startup; the opposite direction — starting off and cancelling at the
    /// verdict — costs a failed attempt, a red line and the information why it was paused.
    ///
    /// **Without a guard there is no gap.** Tests and previews pass none; the default `.wifi` still
    /// applies to them, and they start immediately.
    private var isNetworkReported: Bool { networkMonitor?.reported ?? true }

    /// Wakes the jobs as soon as the guard speaks for the first time.
    ///
    /// **`withObservationTracking` and not a loop that checks.** The callback comes exactly once
    /// and exactly then; polling at fifty-times-a-second would be busy work without a reason — and
    /// it would keep running if nobody ever answers.
    ///
    /// **The hop via `Task { @MainActor }` is necessary**: The callback comes **before** the new
    /// value is set (`willSet`); anyone reading `reported` inside it would still read `false`.
    @ObservationIgnored private var isWaitingForWake = false

    private func awaitFirstReport() {
        guard let networkMonitor, !isWaitingForWake else { return }
        isWaitingForWake = true
        withObservationTracking {
            _ = networkMonitor.reported
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.isWaitingForWake = false
                self?.checkAll()
            }
        }
    }

    // MARK: - The four actions

    /// **Queueing means: register and start.** A job that first sits in a list and then waits for a
    /// press is two actions for one intent.
    public func create(_ job: DownloadJob, resolve using: PlaybackJob) {
        // **Asked at the first download job and not at program start** (AP8). A prompt that appears
        // the first time the app is opened answers a question nobody asked — and is therefore tapped
        // away. Anyone who has just pressed "Download" understands it. The same consideration as with
        // the camera in the handoff.
        DownloadsNotice.askOnce()
        guard !downloads.items.contains(where: { $0.id == job.id }) else { return }
        downloads.items.append(job)
        resolutions[job.id] = using
        memorize()
        start(job)
        describe(job, resolve: using)
    }

    /// **Pausing does not cancel.** The partial file stays, and resuming continues there — that is
    /// the whole difference from "cancel", and at fourteen gigabytes it is the difference between a
    /// pause and a lost evening.
    public func stop(_ id: DownloadJob.Identifier) {
        runs[id]?.cancel()
        runs[id] = nil
        // **The grace period goes along too** (2026-09-09). Anyone who pauses by hand also means the
        // waiting for access; a sleeping task that restarts five seconds later would turn "Paused" into
        // flicker.
        trailingJobs[id]?.cancel()
        trailingJobs[id] = nil
        setState(id, .idle(nil))
    }

    public func resume(_ id: DownloadJob.Identifier) {
        guard let job = downloads.items.first(where: { $0.id == id }) else { return }
        // **After a restart nobody knows any more what was resolved with.** The playback job is not in
        // the ledger — it can be built from the identifier, and that is exactly what the call sites
        // do. Storing it would mean keeping the same information twice.
        if resolutions[id] == nil {
            // **A season identifier must never become a playback job** (E61). It is invented —
            // ``DownloadDescriber/seasonID(series:season:)`` builds it, because a season has no
            // identifier of its own on the server — and therefore resolves for **no** source. Until 2026-09-10
            // it still went out from here, and the failure came back as `network(…)`: the screen said
            // "Connection lost" above a job that never lacked a connection, and a better network never
            // helped.
            //
            // **The right thing would be to split the season back into episode jobs on resuming** — that is
            // a package of its own and stands as such in the roadmap. What stands here is the honest
            // refusal: ``notReady`` means "cannot be started at all", and that is exactly the case.
            guard DownloadDescriber.seriesID(from: id.rawValue) == nil else {
                Diagnose.error(
                    .network,
                    "Downloads: \(job.title) is a season — it has no identifier on the "
                        + "server and cannot be resumed")
                setState(id, .failed(.notReady))
                return
            }
            resolutions[id] = PlaybackJob(identifier: id.rawValue)
        }
        start(job)
    }

    /// **Removing takes the file along.** An entry without a file would be a list that lies; a file
    /// without an entry would only be found later by ``Cleanup/orphaned(files:known:)``.
    public func remove(_ id: DownloadJob.Identifier) {
        Diagnose.step(.downloads, "Ledger trace: manager \(number) removed \(id.rawValue)")
        stop(id)
        if let folder {
            let writer = PartialWriter(folder: folder, identifier: id)
            try? writer.discard()
            try? FileManager.default.removeItem(at: writer.done)
            // **And the segment slip** (2026-09-09). Next to the `.part` file of an HLS delivery lies the
            // state in segments; if it stays, the next download job with the same identifier takes it for
            // its own progress and resumes at segment 143 of a file that no longer exists.
            StreamProgress(beside: writer.part).discard()
        }
        // **The description goes along, and only its own images go along.** Which those are is decided
        // by ``DescriptionLedger/remove(_:)``: A series' poster stands on each of its episodes, and
        // anyone who deleted it with the third would take it away from the other nine.
        if let descriptions, let frames {
            frames.remove(descriptions.remove(id.rawValue))
        }
        downloads.items.removeAll { $0.id == id }
        downloads.isRunning.removeAll { $0.id == id }
        resolutions[id] = nil
        memorize()
    }

    /// **One button, three meanings — and which one applies is decided by the state.**
    ///
    /// That is the flip side of the button also being the display: anyone who presses it means
    /// "whatever is next now". Not queued → queue. Loading → pause. Resting → resume. Available
    /// here → **not** delete: taking away fourteen gigabytes must not be the same gesture as
    /// pausing, and it asks anyway. That is why the press there leads into the title menu, where
    /// "Remove from downloads" stands.
    @discardableResult
    public func setEnabled(
        identifier: String, job: @autoclosure () -> DownloadJob,
        resolve using: @autoclosure () -> PlaybackJob
    ) -> Bool {
        let id = DownloadJob.Identifier(identifier)
        switch DownloadState.forItem(id, in: downloads) {
        case .notQueued:
            create(job(), resolve: using())
        case .isLoading:
            stop(id)
        case .idle:
            resume(id)
        case .isHere:
            // Removing lives in the title menu and not here — see above.
            return false
        }
        return true
    }

    // MARK: - What lies next to the file

    /// Stores title, images, ratings and cast next to the download.
    ///
    /// **Requirement of 2026-09-09:** even when only 1 episode is downloaded, navigation in
    /// Downloads is poster → detail view with the downloaded episodes, and all of it is stored
    /// with OMDb, TMDb etc. ratings.
    ///
    /// **Here and nowhere else, because all four ways of queueing pass through here** — detail
    /// page, download sheet, long press and standing order. Four places would be three places where
    /// it gets forgotten next time.
    ///
    /// **Concurrent to the download and not before it.** A download job that first waits for a
    /// detail response and twelve images starts loading seconds later — for an extra. The bytes are
    /// the main thing; if the description is missing, a poster is missing and not a film.
    ///
    /// **And this moment is the only one at which it works.** Later there is no source: anyone who
    /// opens downloads does so on a plane — the full reasoning is at ``DownloadDescription``.
    private func describe(_ job: DownloadJob, resolve using: PlaybackJob) {
        guard let detail, let ledger = descriptions, let frames,
            ledger.description(zu: job.id.rawValue) == nil
        else { return }

        Task { [weak self] in
            guard let self else { return }
            do {
                let (content, series) = try await self.fetch(job, series: using.series, about: detail)
                // **Only here is it known what the rating services are to be asked for.** The IMDb identifier
                // is on the detail content and nowhere else.
                let info = await self.external?.info(zu: content.title.identifier) ?? .empty
                let result = DownloadDescriber.compose(
                    job, from: content, info: info, series: series)

                // **Whoever has removed in the meantime has removed.** Between queueing and the answer, at
                // 0.31 Mbit/s, lie several seconds; a ledger that then creates a line about a deleted download
                // would be exactly the orphan that ``remove(_:)`` cleans up.
                guard self.downloads.items.contains(where: { $0.id == job.id }) else { return }

                for (name, address) in result.frames {
                    await frames.fetch(address, under: name)
                }
                guard self.downloads.items.contains(where: { $0.id == job.id }) else {
                    frames.remove(Array(result.frames.keys))
                    return
                }
                ledger.create(result.description)
                Diagnose.step(
                    .downloads,
                    "Downloads: \(job.title) described — \(result.frames.count) frames")
            } catch {
                // **The download keeps running anyway.** It is written down because a title without a poster
                // on a plane would otherwise look like a fault of the view.
                Diagnose.hint(.downloads, "Downloads: \(job.title) without description", error)
            }
        }
    }

    /// The page the details come from — **and the series with it.**
    ///
    /// **For an episode it is the series page and not the episode's.** That is where the series
    /// poster, background, cast, year **and** the episode itself with its title, its text and its
    /// still frame stand — all in one response. The episode page would have none of that, and the
    /// tile on the downloads screen would be an episode image in a poster frame (the same finding as
    /// on 2026-09-09 in the "Continue Watching" shelf).
    ///
    /// **It is asked at most twice, and mostly once.** Anyone who passes the series identifier
    /// (``PlaybackJob/series``) gets exactly one request. Anyone who does not pays for a second —
    /// the first response names it in ``TileContent/series``, and from the identifier alone it
    /// cannot be derived for a portal.
    ///
    /// **A season has no identifier on the server.** Sending it there would produce no hit;
    /// ``DownloadDescriber/seriesID(from:)`` reads the series back out of the identifier that
    /// ``DetailView`` built itself.
    private func fetch(
        _ job: DownloadJob, series: String?, about detail: any DetailSource
    ) async throws -> (DetailContent, String?) {
        if let series {
            return (try await detail.detailInfo(zu: series), series)
        }
        if let fromSeason = DownloadDescriber.seriesID(from: job.id.rawValue) {
            return (try await detail.detailInfo(zu: fromSeason), fromSeason)
        }

        let first = try await detail.detailInfo(zu: job.id.rawValue)
        guard let fromTile = first.title.tile.series,
            fromTile != job.id.rawValue
        else { return (first, nil) }

        // **If the second query fails, the first answer stays** — with the series. An episode's tile
        // already carries the title and poster of its series
        // (``TileArtwork/seriesPoster(_:source:width:)``); that is less than the series page and
        // enough to group.
        guard let seriesPage = try? await detail.detailInfo(zu: fromTile) else {
            return (first, fromTile)
        }
        return (seriesPage, fromTile)
    }

    // MARK: - The run

    private func start(_ job: DownloadJob) {
        guard runs[job.id] == nil else {
            Diagnose.step(.network, "Downloads: \(job.title) is already running")
            return
        }
        guard let folder, let playbackJob = resolutions[job.id] else {
            Diagnose.error(
                .network,
                "Downloads: \(job.title) without \(folder == nil ? "folder" : "resolution")")
            setState(job.id, .failed(.notReady))
            return
        }

        // **In the gap before the first network report it waits and does not start** — the reasoning
        // is at ``isNetworkReported``.
        guard isNetworkReported else {
            Diagnose.step(
                .network, "Downloads: \(job.title) waits for the first network report")
            setState(job.id, .idle(nil))
            awaitFirstReport()
            return
        }

        // **Asked before the first byte and not only on failure.** "Paused — you are on cellular" is
        // information; a cancelled job with the same cause would be an error nobody ordered.
        if case .halted(let reason) = job.rule.verdict(forItem: route) {
            setState(job.id, .idle(reason))
            return
        }

        // **And the same question to the account, for the same reason** (2026-09-09). A job that sets
        // off while the one connection is busy gets `509` and is then broken instead of paused —
        // measured at exactly this spot. That ``mayContinue(_:)`` asks the same question again before
        // every block is not a duplicate: the first block is the one for which there is none here yet.
        if case .waiting(let reason) = ConnectionScarcity.verdict(
            claim: claim, occupiedSince: occupiedSince)
        {
            Diagnose.step(
                .network, "Downloads: \(job.title) waits for access (\(reason.rawValue))")
            awaitAccess(job.id)
            return
        }

        setState(job.id, .isLoading)
        Diagnose.step(.network, "Downloads: \(job.title) starts")

        let session = BackgroundSession(
            job: PortalJob(
                // **The portal identifier and not the origin** (2026-09-09). This used to hold
                // `playbackJob.origin.rawValue`, that is, the string `"portals"` — the same for all four
                // portals. Nobody noticed because the field was never read anywhere; since 2026-09-09 it appears
                // in the diagnostic line of every block (``PortalJob/shortForm``) and therefore has to be
                // right.
                portal: PortalJob.portal(from: playbackJob.identifier) ?? "",
                key: playbackJob.identifier,
                host: job.host ?? "", version: job.version ?? "",
                // **The measured length travels along — otherwise every resume is a fresh start** (2026-09-09,
                // noticed in the own grace-period check).
                //
                // ``BackgroundSession/init(job:fetcher:addresses:writer:stream:tier:clock:)`` discards a
                // partial state about which nothing is known — rightly so: whether the same file lies at the
                // other end could otherwise never be established. But nothing was ever stored here, so the
                // rule applied to **every** restart. Measured on the device, provider catalog, 2.5 GB: 92 MB
                // loaded, a busy access, five seconds of grace period — and then "fetch block 0–8388607". A
                // file of this size never finishes that way.
                //
                // **The provider keeps neither `ETag` nor `Last-Modified`** (measured: the block header
                // carries neither), so the length is the only feature that
                // ``Resumability/sameFile(length:tag:changed:likeLength:likeTag:likeModified:)``
                // can compare here. It comes from the first block and not from the estimate of the download
                // sheet — ``Downloads/DownloadJob/sizeIsCertain`` says which of the two currently stands in the
                // item.
                length: Self.measuredLength(job)),
            // **The fetcher knows where its blocks belong.** After a restart no resume is waiting for them
            // any more; the bridge then writes them into the right partial file by this identifier instead
            // of throwing them away.
            fetcher: URLBlockFetcher(partialState: job.id),
            addresses: PlaybackSourceAddress(
                source: source, job: Self.withHost(playbackJob, job)),
            writer: PartialWriter(folder: folder, identifier: job.id),
            // **Which resolution tier an HLS playlist gets** (2026-09-09). Without a specification it would
            // take the highest — at the ARD that is 1080p at 6 Mbit, so around 2.2 GB for forty-eight
            // minutes, unasked, through the tunnel. `tier` is never set for portals (only the media
            // server transcodes), which is why the house default stands behind it and not "as much as
            // possible".
            tier: job.tier ?? SelectionRule.suggestion)

        // **The task inherits the main thread, and that is why there is no `await` before its own
        // calls.** It is created in a main-thread-bound context and keeps running there;
        // `await self?.setState(…)` would be a hop onto the same thread you are already on — the
        // compiler says so as a warning, and this project leaves none standing. The two callbacks to
        // ``BackgroundSession`` carry one because the session is an actor of its own.
        runs[job.id] = Task { [weak self] in
            do {
                _ = try await session.load(
                    mbit: nil,
                    mayContinue: { [weak self] in await self?.mayContinue(job) ?? false },
                    progress: { [weak self] reached, total, mbit in
                        await self?.notify(
                            job.id, reached: reached, total: total, mbit: mbit)
                    })
                self?.setState(job.id, .done)
            } catch is CancellationError {
                // bewusst still: pausing is not an error — the state is already set to "ruht", set by
                // ``stop(_:)``, and a line in the ledger would claim an incident where there was an intent.
            } catch LoadError.wasCancelled {
                // bewusst still: pausing is not a fault on this path either.
                //
                // **The second path to the same intent** (2026-09-09). ``mayContinue(_:)`` sets `.idle(reason)` and
                // answers `false`; the session then throws ``LoadError/wasCancelled``. Without this branch that
                // fell into the general one below and overwrote the just-set "Paused — you are on cellular"
                // with a red warning triangle — the same mix-up as with `CancellationError`, only one error
                // type further.
            } catch LoadError.notLoadable(.accessBusy) {
                Diagnose.step(
                    .network, "Downloads: \(job.title) — provider reports busy, trailing run in progress")
                // **The third path to the same intent, and the only one that comes from outside** (2026-09-09).
                // Pausing is a decision of this app; here the **provider** decided — `429`, `509`, `512` or
                // `551` on a range request, because the account allows exactly one connection. Without this
                // branch that fell into the general one below and became "Connection lost": a sentence that
                // makes the viewer wait for a better network while their own player holds the one connection.
                //
                // **The time is noted before waiting.** ``mayContinue(_:)`` and ``start(_:)`` ask for it;
                // without it the grace period would expire and the next startup would run into the same busy
                // connection.
                self?.occupiedSince = Date()
                self?.awaitAccess(job.id)
            } catch {
                Diagnose.error(.network, "Download failed: \(job.title)", error)
                // **The cause comes first and the title last** (2026-09-09, learned while searching): The error
                // ledger shortens long sentences, and a portal title carries its whole host address in its
                // name. The other way round, the end held exactly what you look for when reading — cut off.
                //
                // **And `error` instead of `step`.** A failed download job is not an intermediate step; as
                // `step` it only landed in the ledger with diagnostics switched on, so never for the one
                // who reports it.
                // **A foreign error becomes one of our own and not its raw text.** What arrives here and is
                // not a ``LoadError`` comes over the network — the resolution, `URLSession`, a certificate.
                // The wording is in the diagnostics above it; the screen shows one sentence.
                self?.setState(
                    job.id, .failed((error as? LoadError) ?? .network("\(error)")))
            }
            self?.finish(job.id)
        }
    }

    /// The playback job with the **host choice from the download sheet** — the smallest effective
    /// wiring for portal downloads (2026-09-09).
    ///
    /// **The finding:** downloading from portal content did not work. The download sheet asks for host and language version (``DownloadChoice``) and stores
    /// them in ``DownloadJob/host`` — but the path to the resolver went via
    /// `PlaybackJob(identifier:)`, and its ``PlaybackJob/source`` stayed `nil`.
    /// `PortalSource.stream(forItem:source:)` then takes "the first usable one".
    ///
    /// **What that costs:** With Animehub there are four hosts times three language versions to
    /// choose from — "the first usable one" is there with high probability the wrong audio track.
    /// And worse: on the next resolution in the middle of the download it can be a different
    /// encode, whereupon ``PortalJob/mayResume(length:tag:changed:)`` aborts with
    /// ``LoadError/differentFile`` — after hours and with the partial state thrown away.
    ///
    /// **Here and not at the call sites.** Four ways create jobs — the sheet, the standing order,
    /// resuming after a restart, the button in the row. This spot is the one that all four pass
    /// through.
    ///
    /// **A choice already made wins.** If the playback job already holds a host, it comes from the
    /// source choice in the player — that is, from someone who saw what was on offer.
    ///
    /// **`nonisolated static`, so that a test can call it without a manager.** It touches no state;
    /// binding it here would mean creating a whole manager including its store on the file system
    /// for its test.
    nonisolated static func withHost(
        _ playbackJob: PlaybackJob, _ job: DownloadJob
    )
        -> PlaybackJob
    {
        guard playbackJob.source == nil, let host = job.host, !host.isEmpty else {
            return playbackJob
        }
        return PlaybackJob(
            identifier: playbackJob.identifier, origin: playbackJob.origin,
            startAt: playbackJob.startAt, source: host,
            withoutRepackager: playbackJob.withoutRepackager, series: playbackJob.series,
            seriesTitle: playbackJob.seriesTitle)
    }

    /// The length a resume can rely on — **`nil` as long as it is estimated.**
    ///
    /// **An estimated number must not stand here**, and that is the whole purpose of these four
    /// lines.
    /// ``Downloads/Resumability/sameFile(length:tag:changed:likeLength:likeTag:likeModified:)``
    /// compares it with what the host says; an estimate from the download sheet never hits the real
    /// number (measured on 2026-09-09: 720 MB estimated against 561 MB measured), and the comparison
    /// would come out negative at **every** first block. The result would not be "starts over" but
    /// ``Downloads/LoadError/differentFile`` — an abort instead of a fresh start.
    ///
    /// **`nonisolated static`, so that a test can call it without a manager** — the same reasoning
    /// as at ``withHost(_:_:)``.
    nonisolated static func measuredLength(_ job: DownloadJob) -> Int64? {
        guard job.sizeIsCertain, job.estimatedSize > 0 else { return nil }
        return job.estimatedSize
    }

    /// **Asked before every block.** A phone leaves the Wi-Fi in the middle of a job, and the Apple
    /// TV starts playing in the middle of a job.
    ///
    /// **Two rules and no longer one** (2026-09-09). Until then only the ``NetworkRule`` stood here;
    /// ``ConnectionScarcity`` existed, but was used exclusively in
    /// ``Downloads/Vorrat/state(forItem:rule:route:claim:)`` — that is, for the **display** and not for
    /// the decision. Measured on the device, that cost the whole provider catalog: the download path
    /// ran into the account's one connection, which its own format probe had occupied 220 ms
    /// earlier, got `509` and ended red. The full trace is at ``Downloads/ConnectionScarcity``.
    ///
    /// **The order is the same as over there and for the same reason:** Without a network, the
    /// question about the account is moot. Anyone who asked about the account first would get
    /// "waiting for the connection" in airplane mode instead of "no network" — a sentence that
    /// waits for someone who stops looking, while in reality nobody is looking.
    ///
    /// **And "waiting" is not a manual pause.** It sets
    /// ``Downloads/Transfer/Situation/waitingForConnection`` and puts a task next to it that lifts it
    /// again — see ``awaitAccess(_:)``. A wait that nobody ends would be an error with friendlier
    /// wording.
    private func mayContinue(_ job: DownloadJob) -> Bool {
        if case .halted(let reason) = job.rule.verdict(forItem: route) {
            setState(job.id, .idle(reason))
            return false
        }
        if case .waiting(let reason) = ConnectionScarcity.verdict(
            claim: claim, occupiedSince: occupiedSince)
        {
            Diagnose.step(
                .network, "Downloads: \(job.title) waits for access (\(reason.rawValue))")
            awaitAccess(job.id)
            return false
        }
        return true
    }

    /// **Waiting means: set it down and come back.**
    ///
    /// **The difference from ``stop(_:)`` is exactly this task.** "Paused — you are on cellular"
    /// is lifted again by the ``NetworkWatch``, because it reports the change; for a busy account
    /// nobody reports anything. The limit goes away by itself after
    /// ``Downloads/ConnectionScarcity/trailing`` seconds — so someone has to look again by
    /// themselves, otherwise "Waiting — the one connection is busy" stands there until the next
    /// finger press and is thus an error with better wording.
    ///
    /// **One task per job, and the previous one is cleared away.** Otherwise every "busy" reply
    /// creates another, and after ten blocks ten tasks nudge the same job — the request storm that
    /// this provider answers with an IP throttle.
    private func awaitAccess(_ id: DownloadJob.Identifier) {
        setState(id, .waitingForConnection)
        trailingJobs[id]?.cancel()
        trailingJobs[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(ConnectionScarcity.trailing))
            guard !Task.isCancelled else { return }
            self?.trailingJobs[id] = nil
            // **Only if the row is still waiting.** In between it may have been paused or removed by hand;
            // a grace period that overwrote that would start a job that someone has just put away.
            guard
                case .waitingForConnection = self?.downloads.isRunning.first(where: { $0.id == id })?
                    .state
            else { return }
            self?.resume(id)
        }
    }

    private func notify(
        _ id: DownloadJob.Identifier, reached: Int64, total: Int64?, mbit: Double?
    ) {
        guard let slot = downloads.isRunning.firstIndex(where: { $0.id == id }) else { return }
        downloads.isRunning[slot].loaded = reached
        if let total {
            downloads.isRunning[slot].total = total
            rememberSize(id, total)
        }
        // **Only overwrite if something was really measured.** A block that is too short yields `nil`;
        // the last usable number is then still better than none.
        if let mbit { downloads.isRunning[slot].mbit = mbit }
    }

    /// The **measured** size on the items — so that a resume is one.
    ///
    /// **``Downloads/DownloadJob/sizeIsCertain`` was `true` nowhere until 2026-09-09.** The field has
    /// existed as long as the type has, and it always meant "estimated" — the host's first answer
    /// knew the real number and dropped it. Two things hung on it, and both looked like something
    /// else: the download sheet kept showing an estimate although it had long been measured, and a
    /// resumed download job started again at zero because without a length there was nothing to
    /// compare.
    ///
    /// **It is written only on change.** A ledger write per block would be three hundred writes at
    /// 2.5 GB for a number that changes once.
    private func rememberSize(_ id: DownloadJob.Identifier, _ bytes: Int64) {
        guard bytes > 0, let slot = downloads.items.firstIndex(where: { $0.id == id }),
            !downloads.items[slot].sizeIsCertain || downloads.items[slot].estimatedSize != bytes
        else { return }
        downloads.items[slot].estimatedSize = bytes
        downloads.items[slot].sizeIsCertain = true
        memorize()
    }

    private func setState(_ id: DownloadJob.Identifier, _ state: Transfer.Situation) {
        if let slot = downloads.isRunning.firstIndex(where: { $0.id == id }) {
            downloads.isRunning[slot].state = state
        } else {
            downloads.isRunning.append(Transfer(id: id, state: state))
        }
    }

    private func finish(_ id: DownloadJob.Identifier) {
        runs[id] = nil
        // **The notification for exactly one occasion** (AP8): A film loads for ten minutes, the app is
        // in the pocket, and then it is there. Everything else — a failure, a paused job — is in the
        // downloads screen and is read when you look.
        if let items = downloads.items.first(where: { $0.id == id }),
            downloads.isRunning.first(where: { $0.id == id })?.state == .done
        {
            DownloadsNotice.notifyDone(title: items.title, isInForeground: isInForeground)
        }
        // **A finished transfer disappears from the list of running ones.** It then stands as an item,
        // and that is the information: "available here" and not "finished loading" — the viewer cares
        // about the state, not the process.
        if let slot = downloads.isRunning.firstIndex(where: { $0.id == id }),
            downloads.isRunning[slot].state == .done
        {
            downloads.isRunning.remove(at: slot)
        }
    }
}

/// The bridge from the playback resolution to ``AddressProvider``.
///
/// **It is deliberately thin.** What it does is pass a question on — and precisely thereby
/// downloads use the same chain as the player, including the certificate fallback, the host
/// choice and the deadline that only a portal names.
///
/// **An actor and no longer a `struct`** (2026-09-09). Since the host fallback it carries a state —
/// which host is up now and which have already failed — and the session queries it from its own
/// actor. A `struct` could not update it; a class with a lock would be the same thing, heavier.
actor PlaybackSourceAddress: AddressProvider {

    private let source: any PlayerSource
    private var job: PlaybackJob

    /// Which hosts have already had their turn — **identifiers and not counters.**
    ///
    /// The bridge's list is not stably sorted; a pointer into it might point to a different host
    /// after the second fetch.
    private var tried: Set<String> = []
    /// The list, fetched once. **`nil` means "not asked yet"** and `[]` means "there are none" — the
    /// difference decides whether it is fetched again.
    private var hostList: [PortalHost]?

    init(source: any PlayerSource, job: PlaybackJob) {
        self.source = source
        self.job = job
        if let chosen = job.source { tried.insert(chosen) }
    }

    func address() async throws -> TargetAddress {
        // **The download address and not the playback address** — see
        // ``PlayerSource/loadTarget(zu:)``. For the media server these are two different endpoints, and
        // only one answers range requests.
        let target: PlaybackRequest
        do {
            target = try await source.loadTarget(zu: job)
        } catch let error as PortalBridge.TestError {
            // bewusst still: **The error is not swallowed but translated.** ``Self.rejection(_:)`` turns
            // the bridge reply into a named refusal (`accessBusy`, `noAddress`); it is written down
            // where the job fails — with title and reason in one line. Writing it here as well would mean
            // putting the same incident into the ledger twice, and the incomplete part first.
            throw Self.rejection(error)
        }
        // **And the headers travel along** (2026-09-09, added the same day). They come from `/play` via
        // ``PlaybackRequest/headers``; for the ARD they are empty (`passedThrough: true`, the bridge
        // sets them itself there), and for a host that demands a `Referer` they are the difference
        // between a file and a 403 before the first byte.
        return TargetAddress(
            target.address, validUntil: target.validUntil, headers: target.headers)
    }

    /// What the bridge reported — **as a named refusal and not as a network error.**
    ///
    /// **The finding of 2026-09-09, documented at the bridge.** Four titles from
    /// `flatone › Clips` answered `/play` with **502**, and the log said
    /// `could not find the video on the page` — the reader can no longer get at the
    /// address because the site rebuilt its player. On the screen, however, it said "Connection
    /// lost. Tap Resume as soon as there is a network again."
    ///
    /// **Three statements, all wrong:** The network was fine, resuming never helped, and the viewer
    /// looked for the fault in themselves. ``Downloads/DeliveryKind`` is built against exactly this — it
    /// just never came into play here because the delivery never came about. This switch is the
    /// missing half: **failing BEFORE the delivery has a name too.**
    ///
    /// **The bridge's reason travels along verbatim**, because it is the only thing that tells
    /// tomorrow's case from today's — it goes in the diagnostic line, not on the screen.
    ///
    /// **And the translation lives here and not in the ``Downloads`` package.** `PortalKit` must not
    /// appear there: the portals have to stay switchable off at build time (roadmap A1), and a
    /// download layer that knew the portal contract would be the bolt in front of that.
    private static func rejection(_ error: PortalBridge.TestError) -> LoadError {
        switch error {
        case .rejected(let status, let reason):
            // **A busy access is something other than a missing address** — the one goes away by itself,
            // the other never does. The same separation as in ``Downloads/DeliveryKind``, and for the same
            // reason.
            DeliveryKind.busyStatuses.contains(status)
                ? .notLoadable(.accessBusy) : .notLoadable(.noAddress(reason))
        case .unreachable:
            // **The bridge itself is silent** — that really is a network question, and the sentence for it
            // is right: It stands in the house, and anyone on the move cannot reach it.
            .network("Die Portale-Brücke antwortet nicht")
        case .cancelled(let status, let code, _):
            // **The server refuses with a code, not with a sentence** (2026-09-12). The same separation as
            // one line above, only on a different detail: A busy access goes away by itself, everything
            // else does not. The code travels along verbatim because — just like the bridge's reason above
            // — it is the only thing that tells tomorrow's case from today's.
            //
            // **It is not translated here.** A code without a sentence belongs on screen as a code, so that
            // a gap stands out instead of silently disappearing; the sentence is built by the UI, in `de`,
            // `en` or `tr`.
            DeliveryKind.busyStatuses.contains(status)
                ? .notLoadable(.accessBusy) : .notLoadable(.noAddress(code))
        case .unreadable:
            .notLoadable(.noAddress(nil))
        }
    }

    /// Take the next host — **without asking back, as ``DownloadChoice`` promises.**
    ///
    /// **Only portals have a choice.** The media server holds one file, the provider one stream per
    /// title; "take another one" would have no target there.
    ///
    /// **Blocked ones drop out, here as in the download sheet.** The server has marked them as
    /// not usable; `/play` would give no address for them, and trying would cost a request for an
    /// answer that is already there.
    func fallBack() async -> Bool {
        guard job.origin == .portals else { return false }

        if hostList == nil {
            hostList = (try? await source.host(zu: job)) ?? []
            // **Whoever started without a host choice got one anyway.** The bridge takes "the first usable
            // one" (`PortalSource.stream`); not recording it as tried would mean trying it a second time as
            // a fallback.
            if job.source == nil, let first = hostList?.first(where: { !$0.locked }) {
                tried.insert(first.id)
            }
        }

        // **Secondary versions drop out when falling back** (E61). At the ARD the "hosts" are
        // resolution tiers, and the next tier can be the audio description — so a different film, not
        // the same file in worse quality. Anyone who wants it chooses it in the download sheet; they
        // just must not get it without wanting it. See ``AudioVersion``.
        guard
            let next = hostList?.first(where: {
                !$0.locked && !tried.contains($0.id)
                    && !AudioVersion.isSecondaryVersion($0.name)
            })
        else { return false }

        tried.insert(next.id)
        // **From zero and not from the position.** ``PlaybackJob/at(source:from:)`` is built for the
        // player, where a host change continues in the middle of the film; a download starts over at
        // the new host — see ``BackgroundSession`` — and `startAt` has no meaning for a range request
        // anyway.
        job = job.at(source: next.id, from: 0)
        Diagnose.step(.network, "Downloads: switching to host \(next.name)")
        return true
    }
}
