import Downloads
import Foundation
import NetworkStatus
import Observation
import ParentalControls

/// What is here, what is downloading, what is missing.
///
/// **The model calculates, the view draws** (AP7). What is here are the three
/// questions the screen has to answer and that none of them should be answered in a `body`:
/// which version applies right now, which rows belong in which
/// section, and what the head says.
///
/// **The state comes from the network and not from a switch.** "No network" is not a
/// state that someone sets, but one that `NetworkStatus` reports — and that is exactly why
/// it is also right when nobody was looking.
@Observable
@MainActor
public final class DownloadsModel {

    /// Which of the three versions the screen shows.
    ///
    /// **Three and not two.** "Empty" is not a special case of "full" but a piece of information of
    /// its own with a sentence of its own; and "no network" is not an error message but the
    /// version in which this screen is the only one in the app that can do anything.
    public enum Version: Equatable {
        case full
        case empty
        case offline
    }

    /// What the list is restricted by.
    public enum Filter: String, CaseIterable, Identifiable {
        case everything = "alles", isLoading = "laedt", allSeries = "serien", movies = "filme", seen =
            "gesehen"
        public var id: String { rawValue }

        var key: String {
            switch self {
            case .everything: "stock.filter.all"
            case .isLoading: "stock.filter.loading"
            case .allSeries: "tab.series"
            case .movies: "tab.movies"
            case .seen: "stock.filter.watched"
            }
        }
    }

    /// **Read and not copied.** A copy would be stale after the first block, and
    /// the screen would show progress that stands still — the most conspicuous
    /// error a download list can have.
    public var downloads: Downloads { administration?.downloads ?? own }

    /// The catalog without management — **for checks and previews.**
    private var own = Downloads()
    private let administration: DownloadsManager?

    /// The storage state — **calculated and not fed in.**
    ///
    /// **The finding of 2026-09-09, found while building out "For the trip".** Here was
    /// a `private(set)` field that **nobody filled** in operation: it was set only
    /// by ``set(downloads:household:durations:seen:)``, and that is explicitly "only for
    /// checks and previews". The only real calculation was in
    /// ``DownloadsManager/household``, and its only caller was the trip sheet.
    /// In the downloads header "· Zero KB frei" therefore stood even earlier, and the
    /// ``StorageLegend`` below it drew an empty bar.
    ///
    /// **So read instead of remembered — the same rule as for ``downloads``.** A remembered
    /// storage state is wrong after the first finished download, and nobody notices it,
    /// because the screen looks like before.
    ///
    /// **The fetch costs nothing, that has been checked:** ``DownloadsManager/household``
    /// counts the download bytes that are in memory anyway, and asks `StorageUsage.unrestricted()`
    /// once — information from the file system about the volume, not a
    /// counting through of folders.
    public var household: StorageBudget { administration?.household ?? ownStorageBudget }

    private var ownStorageBudget = StorageBudget(items: [], unrestricted: 0)
    /// Playing time per item — for the hours figure in the header.
    public private(set) var durations: [DownloadJob.Identifier: TimeInterval] = [:]

    /// **Every filter change trims the selection.** Without that the button would count rows
    /// that nobody sees any more — and take them along on the press.
    public var filter: Filter = .everything { didSet { selection.restrictTo(visible) } }
    public var search = "" { didSet { selection.restrictTo(visible) } }

    /// What is currently ticked for bulk removal.
    ///
    /// **The state is here and not in the view**, because it depends on two things
    /// that are also here: the filter and the search. A selection in the view would survive
    /// every filter change and show a number on the button for which no row is there any more —
    /// see ``Downloads/BulkSelection``.
    public var selection = BulkSelection()

    /// Which titles count as watched here.
    ///
    /// **From the local history and not from the server**, and that is no subtlety on this
    /// screen: it is the only one that can do anything without a network. A question
    /// "have I seen this" that went to a server would be unanswerable on a plane —
    /// and "Remove watched" would be dead exactly where clearing up happens.
    public var watchedIDs: Set<DownloadJob.Identifier> { administration?.watchedIDs ?? ownWatched }

    private var ownWatched: Set<DownloadJob.Identifier> = []

    /// What was stored for the download — **one description per download job.**
    ///
    /// **The contract is ``Downloads/DownloadDescription`` and not the ledger that holds it.**
    /// It is built against the fields because they are fixed; the `DescriptionLedger` comes into being
    /// in parallel, and the **one** line that connects both is the call of
    /// ``set(descriptions:folder:)`` when the model is built. As long as it is missing,
    /// this dictionary is empty — and that is exactly the case the screen has to
    /// carry anyway: old downloads and portals without details.
    ///
    /// **A dictionary and not a list.** The grouping looks up once per item;
    /// searching a list would, with eighteen episodes, be eighteen passes over
    /// eighteen entries — for nothing.
    public private(set) var descriptions: [DownloadJob.Identifier: DownloadDescription] = [:]

    /// What the poster file names hang on — `nil` means: no images, only titles.
    ///
    /// **The folder is here and not in the description.** The stored names are
    /// file names and not paths (see ``Downloads/DownloadDescription/poster``); where the
    /// folder is, ``Downloads/Store`` knows and not the description — and a
    /// path that was written along would be wrong after the next app update, because iOS
    /// moves the container.
    public private(set) var downloadsFolder: URL?

    private let networkMonitor: NetworkStatus.NetworkWatch?

    /// The parental controls, **through which the downloads are also seen** (tvOS roadmap AP45,
    /// 2026-09-25).
    ///
    /// Tabs, shelves, search and favorites left out portals, providers and channels in
    /// kids mode — the downloads did not: a downloaded portal title stood here as a
    /// poster and played from disk. It is filtered by the same rule
    /// (``ParentalControls/ProtectionRule/delivers(_:)``), by the origin of the ID.
    ///
    /// **And since 2026-09-25 also by the age limit** (strand G). The origin
    /// alone let every **Jellyfin** title through — which keeps delivering in kids mode,
    /// but filtered. The approval is in the ``Downloads/DownloadDescription``, which is
    /// written along when adding.
    ///
    /// **Read and not frozen** (check shell H8, 2026-09-27): the view holds
    /// this model in `@State`. With a rule copied at build time, a child who was chosen after
    /// a cold start without a network saw the downloads with the adult's rule.
    private var rule: ProtectionRule { ruleSource() }
    private let ruleSource: @MainActor () -> ProtectionRule

    public convenience init(
        administration: DownloadsManager? = nil, networkMonitor: NetworkStatus.NetworkWatch? = nil,
        rule: ProtectionRule = .pending
    ) {
        self.init(administration: administration, networkMonitor: networkMonitor, ruleSource: { rule })
    }

    /// With the shell's parental controls — **the rule follows the active profile.**
    public convenience init(
        administration: DownloadsManager?, networkMonitor: NetworkStatus.NetworkWatch?,
        parentalControls: ParentalControlsState
    ) {
        self.init(
            administration: administration, networkMonitor: networkMonitor,
            ruleSource: { [parentalControls] in parentalControls.rule })
    }

    private init(
        administration: DownloadsManager?, networkMonitor: NetworkStatus.NetworkWatch?,
        ruleSource: @escaping @MainActor () -> ProtectionRule
    ) {
        self.administration = administration
        self.networkMonitor = networkMonitor
        self.ruleSource = ruleSource
    }

    /// The downloads, **as this profile sees them** — items and running transfers
    /// without what the rule filters (check shell H10). Header and version are calculated from that:
    /// a child with three posters read "18 · 21 h" and "Currently downloading 2" above them.
    public var shownDownloads: Downloads {
        Downloads(
            items: downloads.items.filter { isAllowed($0.id) },
            isRunning: downloads.isRunning.filter { isAllowed($0.id) })
    }

    private func isAllowed(_ identifier: DownloadJob.Identifier) -> Bool {
        rule.scope.delivers(PlaybackJob.origin(zu: identifier.rawValue).rawValue)
            && rule.shows(downloads: descriptions[identifier])
    }

    /// **The network path is asked and not remembered.** A remembered path is wrong after
    /// leaving the flat, and nobody notices, because the screen then
    /// looks like before.
    public var route: NetworkPath { networkMonitor?.route ?? NetworkPath(kind: .wifi) }

    public var version: Version {
        if !route.carries { return .offline }
        return shownDownloads.hasContent ? .full : .empty
    }

    // MARK: - The header

    /// "18 titles · 21 h 40 min".
    ///
    /// **Hours before gigabytes, and that is the whole change relative to the design.** Whoever
    /// is packing for a flight calculates in hours; "14.8 GB" does not answer whether the
    /// return flight is covered.
    public var headerCount: String {
        let shown = shownDownloads
        let hours = Self.hours(shown.playingTime(durations))
        return "\(shown.items.count) · \(hours)"
    }

    /// „14,8 GB · 41,2 GB frei".
    public var headerSpace: String {
        "\(Self.members(shownDownloads.bytes)) · \(Self.members(household.unrestricted))"
    }

    /// "Currently downloading 2 · 3.1 GB to go" — `nil` if nothing is running.
    ///
    /// **What is counted is what really runs.** A waiting and a paused job
    /// are two states with two sentences; adding them up into "downloading 4" would be the number
    /// nobody asked for.
    public var downloadLine: String? {
        let shown = shownDownloads
        guard shown.runningCount > 0 else { return nil }
        return "\(shown.runningCount) · \(Self.members(shown.remainingBytes))"
    }

    // MARK: - The bulk path

    /// The rows that are currently there — **what every bulk action refers to.**
    public var visible: [DownloadJob] { rows(forItem: filter) }

    /// What "Remove watched" would take.
    public var watchedJobs: [DownloadJob] {
        BulkSelection.watchedJobs(
            from: visible, watchedIDs: watchedIDs, isRunning: downloads.isRunning)
    }

    /// "Remove · 3 titles · 4.1 GB" — `nil` as long as nothing is ticked.
    public var bulkText: String? {
        guard selection.count > 0 else { return nil }
        return message("stock.removeCount %lld", selection.count, selection.approval(from: visible))
    }

    /// „Gesehene entfernen · 3 Titel · 4,1 GB" — `nil`, wo nichts Gesehenes liegt.
    public var watchedText: String? {
        guard !watchedJobs.isEmpty else { return nil }
        return message(
            "stock.removeWatched %lld", watchedJobs.count,
            watchedJobs.reduce(0) { $0 + $1.estimatedSize })
    }

    /// **Number and amount are in one text and not in two side by side.** Two `Text`
    /// with a middle dot between them wrap at the wrong place with large type —
    /// the same reasoning as at ``CaptionLabel/readable``.
    private func message(_ key: String, _ count: Int, _ bytes: Int64) -> String {
        "\(SettingsModel.text(key, count)) · \(Self.members(bytes))"
    }

    // MARK: - The list

    public func rows(forItem filter: Filter) -> [DownloadJob] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        return downloads.items.filter { job in
            guard isAllowed(job.id) else { return false }
            guard matches(job, zu: filter) else { return false }
            guard !needle.isEmpty else { return true }
            // **What is searched is everything that is here anyway** — title, second line and
            // the season or episode information. No fetch, no waiting time, no
            // failure case; that is the reason why this search works without a network and
            // the one in the tab next to it does not.
            //
            // **Why the scope information belongs:** the title of an added episode is
            // the **episode title**, the series is in the second line — "S2" and "Season 2"
            // are in neither of the two. But whoever added a series in seasons searches
            // for exactly that, and without this line would find nothing.
            return Self.hits(needle, in: job)
        }
    }

    /// Whether this job matches an input.
    ///
    /// **`nonisolated`, like ``members(_:)``** — the function touches no state, and
    /// a check should be able to call it without the main actor.
    nonisolated static func hits(_ needle: String, in job: DownloadJob) -> Bool {
        let fields = [job.title, job.beside ?? "", job.extent.searchText]
        return fields.contains { $0.lowercased().contains(needle) }
    }

    private func matches(_ job: DownloadJob, zu filter: Filter) -> Bool {
        switch filter {
        case .everything: true
        case .isLoading: downloads.isRunning.contains { $0.id == job.id }
        case .allSeries: job.extent.episodeCount > 0
        case .movies: job.extent.episodeCount == 0
        case .seen: watchedIDs.contains(job.id)
        }
    }

    // MARK: - The posters

    /// The list as posters — **a series is one, a film is one.**
    ///
    /// **New on 2026-09-09**, from the requirement of a poster that leads to a detail view with the
    /// downloaded episodes. The reasoning why grouping is by
    /// ``Downloads/DownloadDescription/series`` and not by title is at
    /// ``DownloadGroup``.
    func groups(forItem filter: Filter) -> [DownloadGroup] {
        DownloadGroup.groups(
            from: rows(forItem: filter), descriptions: descriptions, folder: downloadsFolder,
            seen: watchedIDs)
    }

    /// What is **still on its way** — and therefore keeps a row.
    ///
    /// **A poster with a bar says less than "218.1 MB / 465.6 MB · done about 17:25".**
    /// All three known errors of the competition are transport errors, and a bar shows
    /// the same for all three: nothing (the long version is at
    /// ``DownloadRow/stateRow``). That is why the running download keeps its row,
    /// and only the finished one becomes a poster.
    ///
    /// **What is asked is ``Downloads/Vorrat/isRunning`` and not the state.** A finished
    /// transfer removes itself from this list (see
    /// ``DownloadsManager``); whoever checked for `.isLoading` instead would let the paused
    /// and the failed slip into the grid — exactly what needs its sentence
    /// most.
    public func running(forItem filter: Filter) -> [DownloadJob] {
        rows(forItem: filter).filter { job in downloads.isRunning.contains { $0.id == job.id } }
    }

    /// What lies here finished, as posters.
    ///
    /// **A series can be in both sections** if one of its episodes is still downloading —
    /// above the running one with its megabytes, below the poster with what is already there.
    /// That is no duplication but the only honest split: the one episode is
    /// on its way, the others are not.
    func finishedGroups(forItem filter: Filter) -> [DownloadGroup] {
        let finished = rows(forItem: filter).filter { job in
            !downloads.isRunning.contains { $0.id == job.id }
        }
        return DownloadGroup.groups(
            from: finished, descriptions: descriptions, folder: downloadsFolder,
            seen: watchedIDs)
    }

    /// "Remove · 5 titles · 4.1 GB" — what a poster would take along.
    ///
    /// **The same line as on the bulk button** (``bulkText``), and that is intentional: a
    /// poster hides how much is behind it. The confirmation has to name both, otherwise
    /// the viewer stands before "Remove" and does not know whether they are throwing away an episode or a
    /// season.
    func groupText(_ group: DownloadGroup) -> String {
        message("stock.removeCount %lld", group.count, group.bytes)
    }

    /// How many **posters** a filter would have — for the number on the chip.
    ///
    /// **The number is on the chip and not in a footnote.** A filter that you have to tap
    /// to see whether it is empty is one too many.
    ///
    /// **Since 2026-09-09 groups are counted and not rows.** With posters instead of
    /// rows, "Series 5" with a single added series would be the number for which five
    /// tiles are missing — the chip counted something that you no longer see.
    public func count(_ filter: Filter) -> Int { groups(forItem: filter).count }

    // MARK: - Feeding in

    /// **Only for checks and previews.** In operation ``downloads`` reads the management;
    /// whoever feeds in here without having passed one in gets exactly what they
    /// fed in.
    public func set(
        downloads: Downloads, household: StorageBudget,
        durations: [DownloadJob.Identifier: TimeInterval] = [:],
        seen: Set<DownloadJob.Identifier> = []
    ) {
        self.own = downloads
        self.ownStorageBudget = household
        self.durations = durations
        self.ownWatched = seen
    }

    /// Hands over what was stored for the downloads.
    ///
    /// **This is the one line to the `DescriptionLedger`** — it reads the store, this
    /// model draws from it. Separate, because the ledger belongs to the downloads package and the
    /// view must not know which file it is in; and handed over afterwards instead of in
    /// `init`, because the downloads change while the screen is open — a list
    /// frozen at build time would be incomplete after the first finished download.
    ///
    /// **Without this call the screen still works:** then every item stands for
    /// itself, with title and second line in a poster slot without a poster — see
    /// ``DownloadGroup``.
    public func set(descriptions: [DownloadDescription], folder: URL? = nil) {
        self.descriptions = Dictionary(
            descriptions.map { (DownloadJob.Identifier($0.id), $0) },
            uniquingKeysWith: { _, later in later })
        self.downloadsFolder = folder ?? downloadsFolder
    }

    /// Catches up the watched state from the local history.
    ///
    /// **On appearing and not on building.** Whoever watches an added episode in between
    /// comes back here and wants to find it under "Watched"; a state from
    /// creating the model would then be an hour old.
    public func readWatched() async {
        await administration?.readWatched()
    }

    /// Fetches from the store what was written along for the downloads.
    ///
    /// **This is the one line to the `DescriptionLedger`** — `DescriptionLedger(folder:)`
    /// via `Store.folder()`, both public in the downloads package. The file is read
    /// and not a second catalog beside it: the management **writes** the ledger when
    /// adding and cleans up in it when removing; this screen reads it. A
    /// passed-through dictionary would be a copy, and copies drift apart.
    ///
    /// **On appearing and not on building** — the same reasoning as for
    /// ``readWatched()``. Whoever adds an episode, comes back and wants to see its poster
    /// would get an empty frame with a state from creating the model.
    ///
    /// **Only in operation, and therefore the guard.** Without a management this model is a
    /// preview or a check; an `Store.folder()` would create a real folder in the
    /// application area there to read a file that does not exist. What was fed in
    /// would also fall by the wayside.
    ///
    /// **It costs one file access per appearing.** The ledger holds a few hundred
    /// bytes per item — the same order of magnitude as ``Downloads/DownloadLedger``, which the
    /// management reads at every start just the same.
    public func readDescriptions() {
        guard administration != nil, let folder = try? Store.folder() else { return }
        set(descriptions: DescriptionLedger(folder: folder).read(), folder: folder)
    }

    /// Runs the standing orders — see ``DownloadsManager/queueNewEpisodes()``.
    public func queueNewEpisodes() async {
        await administration?.queueNewEpisodes()
    }

    // MARK: - Numbers into words

    /// **Counted in decimal like on every data sheet.** Whoever counted in binary showed a smaller number
    /// for the same file than the Finder and Settings — and the
    /// viewer would take the app for imprecise.
    ///
    /// **`nonisolated`, like ``hours(_:)`` below.** Both touch no state; they
    /// are here because they belong here, and not because they need the main actor.
    /// Without the annotation they inherited it from the class — and ``DownloadRow/message(forItem:)``
    /// crashed when called from outside. The check found it, with
    /// a crash report instead of a failure: `_swift_task_checkIsolatedSwift`.
    nonisolated static func members(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB, .useGB]
        return formatter.string(fromByteCount: bytes)
    }

    /// "21 h 40 min" — and with less than an hour only the minutes.
    nonisolated static func hours(_ duration: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = duration >= 3600 ? [.hour, .minute] : [.minute]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: duration) ?? ""
    }
}
