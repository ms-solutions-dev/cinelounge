import Core
import Diagnose
import Downloads
import Foundation

/// A source that can say by itself whether a title is **here**.
///
/// **Why this is not in ``PlayerSource``.** The contract there answers questions about a
/// title by asking somebody — every one of its methods is `async throws`. "Is it here?" is
/// not such a question: it is asked before every forwarding, it must cost nothing, and it
/// must not throw. A source that can present a file is therefore something other than one
/// that procures an address.
///
/// **And why there is a protocol of its own at all instead of a fixed type in
/// ``CompositePlayerSource``:** so that a test can rebuild the precedence without creating a
/// folder — the same reasoning that keeps ``PlayerSource`` narrow.
public protocol DownloadsSource: PlayerSource {

    /// Whether for this identifier a **finished** file is in the downloads.
    func isHere(_ identifier: String) -> Bool

    /// The description that was written along when it was queued — `nil` if there is none.
    ///
    /// **The whole description and not only a clearance** (2026-09-25): the parental controls
    /// ask for episode and series clearance and whether the series was looked up
    /// (``ParentalControls/ProtectionRule/shows(downloads:)``).
    func description(_ identifier: String) -> DownloadDescription?
}

/// Playback from the **own downloads** — from the disk instead of the network.
///
/// **The finding of 2026-09-09, reported during testing.** A portal title was completely
/// downloaded; 466 MB lay in `Application Support/Vorrat/`. After that there was **no way to
/// watch it**: ``DownloadsView`` knows only pause and resume, and the play symbol on a finished
/// ``DownloadRow`` means "resume the download job" and not "play".
/// ``CompositePlayerSource`` answered `.downloads` expressly with `nil` — "The downloads do not
/// play yet." Downloads that cannot be played are not downloads, but occupied storage.
///
/// **The name comes from ``Downloads/Store`` and is not built here.** Since 2026-09-09 it is
/// capped: a portal identifier is `portal|key|address`, and the address of "Skiplu" has
/// over four hundred characters — every file system that iOS offers stops at 255 bytes.
/// ``Downloads/Store/fileName(forItem:)`` therefore cuts at 160 characters and appends a
/// checksum over the **raw** identifier. Anyone who assembled the name a second time here
/// would not find again exactly the titles for which the capping was built — and those
/// would be the same portal titles this finding is about.
///
/// **What a local title does not bring along, and what is therefore missing in the player.**
/// On the disk lies a video file and next to it a ``Downloads/DownloadJob`` — nothing more. So
/// the following are missing:
///
///   * **the picture** (``PlaybackRequest/image``, ``PlaybackRequest/backdrop``) — the lock
///     screen shows no poster for a downloaded title, and the history entry that arises at
///     the end of playback arrives without one in "Continue Watching". No description is
///     stored with the download; a poster would be a network request exactly where there is
///     no network.
///   * **the chapters** (``PlaybackRequest/chapters``) — the chapter bar stays empty, and
///     "Chapter forward" does not jump.
///   * **the track list** (``PlaybackRequest/audioTracks``, ``PlaybackRequest/subtitles``) —
///     the track choice in the player header stands empty. **The tracks are there all the
///     same:** they are in the file, and Apple's engine finds them itself. What is missing is
///     the list with which one names them beforehand — for a portal the version was decided
///     when queuing anyway (``Downloads/DownloadJob/version``), and choosing afterwards would
///     not work without a network.
///   * **the description** (``PlaybackRequest/description``) and
///     ``PlaybackRequest/isAnime`` — both need information that only a source knows.
///
/// Nothing of this is guessed. An invented field would be worse than an empty one: it looks
/// like information.
public struct DownloadsPlayerSource: DownloadsSource {

    /// Where the files lie — `nil` if the folder could not be created.
    private let folder: URL?

    /// The ledger from which title, second line and runtime come.
    private let ledger: DownloadLedger?

    /// - Parameter ordner: the downloads folder. The tests pass their own so that they leave
    ///   nothing in `Application Support`.
    public init(folder: URL?) {
        self.folder = folder
        self.ledger = folder.map { DownloadLedger(folder: $0) }
    }

    /// The usual place.
    ///
    /// **Resolved once and then held.** ``Downloads/Store/folder()`` creates the folder and
    /// excludes it from the backup; that belongs in a setup and not in a question that is asked
    /// before every forwarding.
    public init() {
        self.init(folder: try? Store.folder())
    }

    /// Whether anything finished lies here at all.
    ///
    /// **What for, finding of 2026-09-09:** ``SourceAssembly/playerSource(width:rule:)`` returned
    /// `nil` as soon as **no** source was set up — and thereby on a device without a reachable
    /// server also built no player for the finished download. The downloads, however, are the
    /// one catalog that carries without any setup; that is what they are for.
    ///
    /// **The ledger is asked and not the folder.** A directory walk over a folder of fourteen
    /// gigabytes does not belong in a setup that can occur on every redraw. The ledger knows what
    /// was queued; whether an individual file has arrived is still decided by ``isHere(_:)``
    /// on the disk.
    public var hasContent: Bool {
        !(ledger?.read().isEmpty ?? true)
    }

    /// Whether for this identifier a **finished** file lies here.
    ///
    /// **The finished one and expressly not the `.part`.** The partial state carries a name of
    /// its own, because a half-loaded file looks playable and stops in the middle of the film —
    /// the reasoning is at ``Downloads/Store/partialName(forItem:)``. Anyone who let the partial state
    /// count here would turn the protection into a detour: on the plane the viewer would get
    /// exactly the abort that the separate name is meant to prevent.
    ///
    /// **The file system is asked and not the ledger.** The ledger says what was queued; whether
    /// it has arrived is told only by the disk. The two can drift apart —
    /// ``Downloads/Cleanup/orphaned(files:known:)`` exists for exactly that reason.
    public func isHere(_ identifier: String) -> Bool {
        guard let file = file(zu: identifier) else { return false }
        return FileManager.default.fileExists(atPath: file.path)
    }

    /// From the ``Downloads/DescriptionLedger`` — **only read once the file lies here**
    /// (``CompositePlayerSource`` asks for it), so once per playback and not per forwarding.
    public func description(_ identifier: String) -> DownloadDescription? {
        guard let folder else { return nil }
        return DescriptionLedger(folder: folder).description(zu: identifier)
    }

    public func target(zu job: PlaybackJob) async throws -> PlaybackRequest {
        guard let file = file(zu: job.identifier),
            FileManager.default.fileExists(atPath: file.path)
        else { throw Missing.file }

        let items = ledger?.read().first { $0.id.rawValue == job.identifier }
        Diagnose.step(.playback, "Downloads play locally, without network")
        return PlaybackRequest(
            // **Title and second line from the ledger.** They are there because the detail page knew
            // them when the button was pressed — the same place that ``Downloads/DownloadRequest/title``
            // comes from, and for the same reason.
            identifier: job.identifier,
            title: items?.title ?? job.identifier,
            beside: items?.beside,
            address: file,
            // **Without a server `nil` is a zero.** ``PlaybackJob/startAt`` is `nil` otherwise
            // meaning "the server should say where" — here there is none to ask. The local history
            // keeps a **share** and no second (``HistoryEntry/progress``); calculating a position
            // from it would be an estimate that looks like a resume.
            startAt: job.startAt ?? 0,
            duration: items?.runtime,
            origin: origin(zu: job),
            // **Unchanged from the disk, and that is no estimate.** The file is the same one the server
            // handed over; it is neither transcoded nor chunked on playback. What
            // ``PlaybackRequest/deliveryRoute`` otherwise uses — "native via hls" — would be, for a file on
            // the own disk, a claim about a server that does not appear here at all.
            decision: Self.direct,
            approval: description(job.identifier).map(Self.approval))
    }

    /// The clearance of a download for the history — from its description.
    static func approval(_ description: DownloadDescription) -> HistoryClearance {
        HistoryClearance(
            ageRating: description.ageRating, series: description.series,
            seriesClearance: description.seriesClearance,
            seriesClearanceChecked: description.seriesClearanceChecked)
    }

    /// **What lies here is not fetched again.**
    ///
    /// The error is the right answer and no emergency exit: this question is asked solely by
    /// ``DownloadsManager``, and it asks it to begin a download run. For a title whose finished
    /// file already lies there is none — it is there.
    ///
    /// **Returning a `file://` address would be worse than the error.** The download run fetches
    /// block by block and demands a `206` for every range request (see
    /// ``PlayerSource/loadTarget(zu:)``); `URLSession` does not answer ranges on `file://`. The
    /// run would fail at the first block, and the screen would say "Loading · 0 KB" over a file
    /// that is completely present.
    public func loadTarget(zu job: PlaybackJob) async throws -> PlaybackRequest {
        throw Missing.nothingToLoad
    }

    /// The progress of a downloaded title — **and why it is not reported here.**
    ///
    /// **The question arises because without a network it does not exist.** A progress that is
    /// supposed to go to Jellyfin cannot get there on the plane; and a download is played
    /// precisely **because** there is no network. A call against the media server would here be
    /// the normal case of a failure and not the exception.
    ///
    /// **The local history covers it, and covers it completely.**
    /// ``PlayerModel/recordHistory()`` writes at the end of every playback into the
    /// ``HistoryStore`` — to the disk, without a network, the same for every origin. That is the
    /// **one** write place of the history, and a test suite counts it
    /// (`HistoryTests.singleWriter`). Opening a second one here would mean giving up the
    /// rule that prevented four faulty write places in the TV app — for an intermediate state that
    /// the same file gets ten seconds later anyway.
    ///
    /// **The price is stated, so that nobody has to look for it:** anyone who kills the app in the
    /// **middle** of the film loses the position. For a title from the media server the server
    /// would have had it; for a downloaded title nobody has it. That is the one thing an
    /// intermediate report could do — and it is too little for a second write place.
    public func notify(
        location: TimeInterval, duration: TimeInterval, zu job: PlaybackJob, isPaused: Bool
    ) async throws {
        // **Written down and not concealed — but only on stopping.** One line per report tick
        // would be dozens per film and thereby an error book in which one no longer finds the rest.
        // On stopping it stands once and says what happens to the progress.
        guard isPaused else { return }
        Diagnose.step(
            .downloads, "Downloads: progress stays local, the history is written at the end")
    }

    /// Where the title **comes from** — not where it lies.
    ///
    /// **The downloads are a place of storage and no origin.** Anyone who starts from
    /// ``DownloadsView`` sends ``Catalog/Origin/downloads`` along; if that were in the
    /// ``PlaybackRequest``, the history entry that arises from it at the end would carry it too —
    /// and ``History/validOnes(at:allowed:)`` throws it out again, because
    /// ``CatalogState/hasKey(_:)`` does not list the downloads. "Continue Watching" would stay
    /// empty although something had just been watched to the end.
    ///
    /// **It is read from the identifier**, with the same rule as in
    /// ``PlaybackJob/origin(zu:)``: a portal identifier and a provider identifier can be read
    /// back, everything else is the media server. A channel does not occur here — it cannot be
    /// downloaded (``Downloads/SourceKind/init(_:)``).
    private func origin(zu job: PlaybackJob) -> Catalog.Origin {
        job.origin == .downloads
            ? PlaybackJob.origin(zu: job.identifier) : job.origin
    }

    /// The location of the **finished** file for an identifier.
    private func file(zu identifier: String) -> URL? {
        folder?.appendingPathComponent(Store.fileName(forItem: .init(identifier)))
    }

    /// **Unchanged and native.** The same decision that ``JellyfinPlayerSource/loadTarget(zu:)``
    /// makes for the file that landed here.
    ///
    /// **What is still open on the device:** ``Downloads/Store/fileName(forItem:)`` always ends in
    /// `.mp4`, whatever is in the file — for the media server the download address is
    /// `stream?static=true`, so the **raw** container, and that can be a Matroska. Apple's engine
    /// does not open that (`AVFoundationErrorDomain -11828`), and ``RepackagerRun`` does not help
    /// here: its file path reads via `HTTPByteRangeSource`, so via HTTP, and not from the disk.
    /// For the portals — the case of this finding — the file is a finished MP4, and the path
    /// carries.
    private static let direct = PlaybackDecision(
        engine: .native, delivery: .directPlay, reason: .nativeContainer)

    /// **Own errors and no silent null case.** "The file is gone" and "this cannot be downloaded
    /// here" are two statements, and the screen says them differently — see
    /// ``CompositePlayerSource/Missing``.
    enum Missing: Error {
        case file
        case nothingToLoad
    }
}
