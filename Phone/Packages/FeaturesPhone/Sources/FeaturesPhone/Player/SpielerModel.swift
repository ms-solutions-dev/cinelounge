import Core
import DesignSystemPhone
import Diagnose
import Flows
import Foundation
import NetworkStatus
import Observation
import Playback

/// What the player shows, what it reports — and **the one place that writes the
/// history.**
///
/// **The engine is the shared one.** `Packages/Playback` carries both apps: of 3,319
/// lines, twenty-six places sit behind a TV switch, and what is behind it is honestly
/// TV-only — the display manager for frame rate and HDR, which a phone does not have.
/// `PlaybackRules`, `EngineHost`, `NowPlayingBridge` and the engine itself carry over
/// unchanged.
///
/// **Writing happens during playback and nowhere else.** The finding of 2026-09-02 in the
/// TV app stands as the warning for this: the channel reminder was written in **four**
/// places, all four sat **before** the player — and anyone who switched inside the
/// player got past none of them. That is why ``recordHistory()`` is the only call
/// site of ``History/note(_:)`` in the whole source, and a test suite counts it.
@MainActor
@Observable
public final class PlayerModel {

    public enum Situation: Sendable, Equatable {
        case isLoading
        case isPlaying
        case disrupted(PlaybackPhase)
    }

    public private(set) var state: Situation = .isLoading
    /// **Settable internally for the test** of the parity rules (AP58 G1): otherwise it is
    /// only filled in ``start()``, and that starts the engine.
    public internal(set) var job: PlaybackRequest?

    /// The host of the engine — the UI does not create one itself.
    ///
    /// Otherwise every view would have to rebuild the choice from `PlaybackDecision`, and
    /// when the target changes the old engine would keep running: you would hear two audio
    /// tracks on top of each other.
    public let host = EngineHost()

    /// Whether the control bar is visible.
    ///
    /// **It fades out, but never from under the finger.** The most serious finding of the
    /// usability review was here: "after three seconds the player hides everything".
    /// The timer therefore runs only while nothing is touched — every touch resets it.
    public var isBarVisible = true

    public private(set) var location: TimeInterval = 0
    public private(set) var duration: TimeInterval = 0

    /// The aspect ratio of the running picture — `nil` as long as nobody knows it.
    ///
    /// **Sampled and not observed** (AP4). `presentationSize` is only set once the player
    /// knows its first frame, and does not change afterwards; carrying it along on the tick
    /// costs nothing and spares the shared package an observation that only the phone
    /// needs — the reasoning is at ``Playback/EngineHost/imageFormat``.
    ///
    /// **With the direct renderer it stays `nil`**, and that is the statement: a channel
    /// runs there, there is nothing to choose, and a guessed number would be a crop into
    /// the picture that nobody ordered.
    public private(set) var imageFormat: Double?
    public private(set) var isRunning = false

    /// The next episode, as soon as it is known.
    ///
    /// **Settable internally for the test** of ``playNext()``: otherwise it is only
    /// filled in ``start()``, and that starts the engine.
    public internal(set) var next: PlaybackRequest?

    /// The source choice — **the same flow as on the TV** (AP58 G1, A9,
    /// ``Flows/SourcePickerFlow``). Since then it applies per title: after the next
    /// episode the sheet used to show the host list of the previous one.
    public let sourceChoice = SourcePickerFlow()

    /// What this title offers in hosts, tiers and versions.
    ///
    /// **Empty until somebody asks.** Fetching costs a request to the portal, and nobody
    /// needs the choice while the picture is up — it is fetched when the sheet opens.
    public var choice: PortalSourceChoice { sourceChoice.choice }

    /// Cast, details and further episodes — **new on the phone** (AP58 G1, A4), the same
    /// board as on the TV (``Flows/InfoBoard``), here as a sheet from the player.
    public let board = InfoBoard()

    /// The similar movie for the offer at the end of a film (AP58 G1, A8) — **only where
    /// there is no next episode, and only what the filter lets through.** It never starts
    /// by itself.
    public internal(set) var similarItem: MediaItem?

    /// The preview images while scrubbing (AP58 G1, A7) — from `Core.Trickplay`, as on the TV.
    public private(set) var trickplay: Trickplay?

    /// The window in the buffer while a channel with time shift is running (AP58 G1, A1) —
    /// **kept up to date on the tick**, because the engine is not observed.
    public internal(set) var timeShiftWindow: TimeShift.Window?

    /// The chosen speed — 1 is the default (AP58 G1, A6). **Settable internally for the
    /// test** of re-applying it after a rebuild.
    public internal(set) var rate: Double = 1

    /// Under which series the title runs — from the request or, where the entry point did
    /// not know it, from the catalog. For the audio choice per title and for the board.
    private var seriesID: String?

    /// Where the audio choice per title is kept (AP58 G1, A10, ``Core/AudioMemory``) —
    /// the person's compartment; in the tests a transient store.
    private let audioStore: any KeyValueStore

    /// Which row is currently playing — `nil` as long as nobody has chosen.
    public var runningSource: String? { request.source }

    /// The identifier of the title in question — **even before anything is playing.**
    ///
    /// Until 2026-09-16 ``loadSelection()`` hung on `job?.identifier`, and the request only
    /// exists after a successful start: on the error screen there was therefore no source
    /// choice, precisely where another source would be needed.
    public var identifier: String { request.identifier }

    /// **Mutable since the source choice exists.** A host switch is not a new title but
    /// the same one at a different address: anyone who opened a new player for it would
    /// lose position, session and history.
    private var request: PlaybackJob
    private let source: (any PlayerSource)?
    /// The network path, if the shell observes it. **No network takes precedence over any
    /// source question** — see ``DisruptionInterpretation``.
    private let networkMonitor: NetworkStatus.NetworkWatch?
    private var clock: Task<Void, Never>?

    /// A switch triggered by the tick — the next episode or re-fetching an expired
    /// address. **In a task of its own and not in the timer** (player review, finding S1):
    /// every switch stops the timer first. If it ran inside it, it cancelled itself, and
    /// logout and resolving arrived in a cancelled task — `URLSession` answers there with
    /// `CancellationError`, the old episode stayed open on the server, and the new one
    /// ended up on the error screen.
    ///
    /// Readable internally so that the test can wait for the switch.
    private(set) var switchObserver: Task<Void, Never>?

    /// Which startup is currently valid — **every ``start()`` counts up, and so does
    /// ``finish()``** (player review, finding S8, the same marker as `engineStartGeneration`
    /// on the TV). After every wait a startup asks whether it still applies: otherwise a
    /// superseded one would set, after the new request, the remuxer and the engine, and the
    /// late answers for the previous episode (next episode, segments, preview images) would
    /// land on the new title.
    private var startup = 0

    /// Whether the player is closed — after that nothing starts any more, not even a
    /// switch that was just under way.
    private var finished = false

    /// The engine state of the previous tick — for re-applying the speed on the
    /// transition to `.playing` (finding S6).
    private var lastStatus: PlaybackStatus?

    /// What is to be decided without the engine — reports, next episode, skipping,
    /// stall. **The same core as on the TV** (AP58 R4, ``Flows/PlaybackCore``);
    /// the guard counts here only after the first picture, because the startup is shown
    /// by ``PlaybackPhase/loadingLong``.
    public let core = PlaybackCore(step: PlayerModel.cadence, watchesDuringStartup: false)

    /// For which title the ``core`` was last set up — a source switch on the same title
    /// keeps segments and what was swiped away.
    private var coreTitle: String?

    /// What the viewer needs to know about the file — that it is truncated (AP58 R4).
    ///
    /// On the TV the sentence is in the second line; here the view fades it in once. Until
    /// R4 nobody on the phone knew it, and a Continue Watching ended after one second.
    ///
    /// **It belongs to the file and not to the player** (finding S9): it is set anew after
    /// every start, also empty — until then the note of a truncated Matroska stayed on the
    /// next episode, which ran without a remuxer. Settable internally for the test.
    public internal(set) var fileHint: String?

    /// The running remuxer, if this path needs one.
    ///
    /// **It belongs to the model and not to the view.** Anyone holding it in the view would
    /// lose it on the first rebuild — and a session that nobody ends holds on to the one
    /// allowed connection of the provider.
    public private(set) var repackager: RepackagerRun.Run?

    /// The audio session of the device — **the prerequisite for everything else.**
    ///
    /// Without the `.playback` category the sound goes silent as soon as the screen turns
    /// off, and iOS does not even offer Picture in Picture. It therefore stands right at the
    /// front of ``start()`` and not next to the other items.
    private let audioSession = AudioSession()
    /// Keeps the screen awake while a picture is running — **so far set nowhere on the
    /// phone** (2026-10-19).
    ///
    /// Films went unnoticed because `AVPlayer` keeps the screensaver away by itself
    /// (`preventsDisplaySleepDuringVideoPlayback`). Live TV runs through our own engine
    /// with `AVSampleBufferDisplayLayer`, which knows no such consideration — there the
    /// screen went off after the lock timeout. The same rule as ``PlayerModel`` on the
    /// TV: awake on `.playing`, `.opening` and `.buffering`.
    private let idleLock = IdleLock()
    /// Whether an expired address has already been re-fetched once — **once is enough.**
    private var alreadyRefetched = false

    public init(
        job: PlaybackJob, source: (any PlayerSource)?, networkMonitor: NetworkStatus.NetworkWatch? = nil,
        audioStore: any KeyValueStore = ProfileStore.playback
    ) {
        self.audioStore = audioStore
        self.request = job
        self.source = source
        self.networkMonitor = networkMonitor
    }

    /// **A failure after the start.** Until 2026-09-06 it had no screen: the startup
    /// succeeded, the engine failed afterwards, and the view stayed on `.isPlaying` —
    /// black, without a message and without a way out.
    ///
    /// **For two sources it is the only information there is** — see
    /// ``DisruptionInterpretation``: the provider rejects an occupied connection silently, and an
    /// expired portal address as well.
    public enum Dropout: Error { case motor }

    /// Starts — or **tries again.**
    ///
    /// **`state` first goes back to `.isLoading`.** Without this line the error screen stayed
    /// up while loading went on in the background: pressing "Try again" was visibly without
    /// effect, and anyone who presses twice starts two fetches against an account that
    /// allows one.
    ///
    /// **The timer and the old engine stop beforehand** (player review, finding S2): until
    /// then the timer of the failed engine kept running, read `.failed` again on the next
    /// tick and put the error screen over the loading screen — with the button for a second,
    /// parallel startup. And as soon as the target was there, it logged out via the **new**
    /// counter; the retried title never reported progress afterwards.
    public func start() async {
        guard !finished else { return }
        guard let source else {
            state = .disrupted(.notSetUpYet)
            return
        }
        startup += 1
        let mine = startup
        clock?.cancel()
        clock = nil
        host.stop()
        state = .isLoading
        resetStall()
        // **The audio session first, before the first picture.** Anyone who opens it
        // afterwards has, until then, a film that goes silent when the screen is locked — and
        // iOS did not offer Picture in Picture during that time.
        audioSession.begin(
            AudioSession.Commands(
                stop: { [weak self] in self?.stopFromOutside() },
                resume: { [weak self] in self?.resumeFromOutside() }))
        do {
            let fetched = try await source.target(zu: request)
            guard mine == startup else { return }
            job = fetched
            // **A channel enters the history after 20 s** (``Flows/ChannelDwell``),
            // wherever it was started from — the same history and the same rule as on the TV.
            // The title of a live request is the channel name (``ChannelPlayerSource``).
            if fetched.kind == .live {
                let identifier = fetched.identifier
                ChannelDwell.memorize(fetched.title) { [weak self] in
                    guard let self else { return false }
                    return !self.finished && self.job?.identifier == identifier
                }
            }
            let sameTitle = coreTitle == fetched.identifier
            core.newTarget(
                reportsProgress: fetched.target.tracksProgress, isRecording: fetched.kind == .recording,
                sameTitle: sameTitle)
            coreTitle = fetched.identifier
            if !sameTitle {
                board.clear()
                trickplay = nil
                similarItem = nil
                seriesID = request.series
                rate = SpeedChoice.afterSwitch(rate, sameTitle: false)
            }
            sourceChoice.isRunning(fetched.source ?? request.source)
            duration = fetched.duration ?? 0
            location = fetched.startAt
            // **The wish follows the source that carries.** If the server took another one
            // (see ``PlaybackRequest/source``), ``runningSource`` should name it — otherwise the
            // source sheet marks a row that is not currently playing, and "Resolve again" would
            // ask for the dead one once more.
            if let carries = fetched.source, carries != request.source {
                request = request.at(source: carries, from: fetched.startAt)
            }

            // **The remuxer, if this path needs one** (AP2). Neither a raw transport stream nor
            // a Matroska gets past Apple's engine — it plays MPEG-TS only inside an HLS playlist
            // and Matroska not at all. ``RepackagerRun`` decides by the delivery path and returns
            // either a playlist or a sample queue.
            //
            // **An old run is torn down beforehand.** With an account that has exactly one
            // allowed connection, a session left lying around holds it, and the next channel gets
            // "occupied" instead of a picture — the lesson of 2026-08-16.
            tearDownRepackager()
            var target = fetched.target
            let run: RepackagerRun.Run?
            do {
                let built = try await RepackagerRun.start(target)
                guard mine == startup else {
                    built?.finish()
                    return
                }
                run = built
            } catch {
                guard mine == startup else { return }
                // Into the ledger before the decision, not after — otherwise exactly the case
                // disappears that one would most urgently want to see.
                Diagnose.hint(.playback, "Repackaging not possible", error)
                // **The same chain as on the TV** (AP58 R4,
                // ``Flows/RemuxStart/fallback(after:target:sourceIsChunked:)``).
                // The server chunks only for the media server and only once — the
                // ``PlaybackJob`` carries the marker, a second attempt no longer comes through.
                switch RemuxStart.fallback(
                    after: error, target: target,
                    sourceIsChunked: fetched.origin == .jellyfin && !request.withoutRepackager)
                {
                case .serverChunks:
                    Diagnose.step(.playback, "Second attempt — the server chunks")
                    request = request.withoutOwnRepackager(from: fetched.startAt)
                    await start()
                    return
                case .lastAttempt(let raw):
                    // **New on the phone since R4:** Apple's engine on the raw address, instead of
                    // showing the error screen right away. If it fails, the interpretation says so
                    // from the engine (``Dropout/motor``).
                    Diagnose.step(.playback, "Last attempt — the engine on the raw address")
                    target = target.rerouted(to: target.url, decision: raw)
                    run = nil
                // **A refusal stays a refusal** — on the phone the error screen shows the
                // interpretation of the error; a raw attempt to look past it would yield only a
                // blurrier answer.
                case .rejection, .superseded:
                    throw error
                }
            }
            repackager = run

            if let run {
                // **The address of the engine is not that of the channel.** On the playlist path it
                // points to `127.0.0.1`; ``PlaybackTarget/origin`` remembers which channel it
                // actually is — otherwise nobody would find the neighbour any more when switching.
                var redirected = target.redirected(to: run.address)
                // **A truncated file starts from the beginning** — the engine would otherwise jump to
                // the end and report `ended` after one second.
                if let fresh = run.startAt {
                    redirected = redirected.rerouted(to: run.address, startAt: fresh)
                    location = fresh
                }
                host.start(redirected, samples: run.samples)
            } else {
                host.start(target)
            }
            fileHint = run?.hint
            isRunning = true
            chooseStartTrack(forItem: fetched)
            // **`state` stays `.isLoading` until the timer really runs.**
            //
            // Until 2026-09-06 this said `.isPlaying` as soon as the engine had **started** — not as
            // soon as it **ran**. Measured in the simulator on 2026-09-06: an HEVC title needs 9.8
            // seconds until the first picture is up, because the server transcodes it. During
            // that time a black picture lay under a control bar that fades out after four
            // seconds, and the app said **nothing**.
            //
            // ``LoadingState`` says it by itself: after four seconds it shows the second
            // sentence. On the tunnel with 0.31 Mbit/s this is not the exception but the normal
            // case. It is advanced in ``tick()``.
            Diagnose.step(
                .playback,
                "Player: \(fetched.title) (\(fetched.origin.rawValue), \(fetched.kind.rawValue)), "
                    + "Start at \(Int(fetched.startAt)) s, \(fetched.audioTracks.count) audio tracks")
            // **The first tick with a picture opens the session** (AP58 R4): the
            // ``Flows/PlaybackCore`` logs in on the first `.playing` and logs out on
            // `.ended`, `.failed` and on closing — also without a login, because on the
            // server the session already comes into being with the fetch. Until then the phone
            // logged in before the first picture and did not log out at all after `.ended`.
            // **The lock screen gets what it needs** — and the commands go in
            // as closures, so that the bridge does not have to know this model.
            // A channel gets **no** skip commands: `PlaybackTarget.isSeekable`
            // says the same, and a button that jumps back ten seconds while the
            // programme is running is one without effect.
            LockScreen.notify(
                fetched,
                commands: NowPlayingBridge.Commands(
                    play: { [weak self] in self?.resumeFromOutside() },
                    pause: { [weak self] in self?.stopFromOutside() },
                    toggle: { [weak self] in self?.togglePlayback() },
                    skip: fetched.kind == .recording
                        ? { [weak self] span in self?.jump(span) } : nil))
            startClock()
            // **The next episode in advance**, so that the button at the end does not first
            // have to think — and so that it does not appear at all where there is none.
            let episode = try? await source.nextEpisode(after: request)
            guard mine == startup else { return }
            next = episode
            // **Segments for skipping and for the trigger point of the offer** — only
            // a recording has any; a failure just means "no button".
            if fetched.kind == .recording {
                let segments = (try? await source.segments(zu: request)) ?? []
                guard mine == startup else { return }
                core.setSegments(segments)
                // **The profile decides whether intro and recap go by themselves** (AP85).
                let binge = BingePreferences.load(from: ProfileStore.playback)
                core.autoSkipKinds = binge.autoSkipKinds
                core.stillWatchingAfter = binge.stillWatchingAfter
                await loadExtra(zu: fetched, from: source)
                guard mine == startup else { return }
            }
            core.setNext(
                available: next != nil || similarItem != nil,
                similar: next == nil && similarItem != nil, location: location, duration: duration)
        } catch {
            guard mine == startup else { return }
            Diagnose.error(.playback, "Playback not started", error)
            state = .disrupted(
                DisruptionInterpretation.state(
                    forItem: error, origin: request.origin, network: networkMonitor?.route,
                    certificateTrustedByAppOnly: Self.trustedByAppOnly(job?.address)))
        }
    }

    /// Whether **only the app** trusts this address: `https`, and the certificate store
    /// holds a digest for its host. A digest is there exactly when the system rejected the
    /// certificate and the viewer accepted it in the sheet — the system player does not
    /// know this sheet.
    nonisolated static func trustedByAppOnly(_ address: URL?) -> Bool {
        guard let address, address.scheme?.lowercased() == "https", let calculator = address.host()
        else { return false }
        return CertificateTrustStore().fingerprint(for: calculator) != nil
    }

    /// Paused from outside — by a call, by unplugged headphones, by the lock screen.
    ///
    /// **Not ``togglePlayback()``**, because that toggles: anyone who is called twice
    /// while already paused would otherwise have started the film again.
    func stopFromOutside() {
        guard isRunning else { return }
        isRunning = false
        host.controller.pause()
    }

    /// And resumed — **only if the system has allowed it.** ``AudioSession`` checks the
    /// permission; here is only the carrying out.
    func resumeFromOutside() {
        guard !isRunning else { return }
        isRunning = true
        host.controller.play()
        applySpeed()
    }

    /// Ends playback — **and writes the history.**
    public func finish() async {
        finished = true
        startup += 1
        switchObserver?.cancel()
        switchObserver = nil
        clock?.cancel()
        clock = nil
        // **Take back both, and do it here.** A title left standing in Control Center
        // accepts commands for an engine that no longer exists; an open audio session keeps
        // the sound of other apps down.
        LockScreen.finish()
        audioSession.finish()
        idleLock.hold(false)
        await recordHistory()
        await signOut()
        host.stop()
        // **The remuxer last and never forgotten.** It holds the one allowed connection of
        // the provider; a session left lying around answers the next channel with "occupied"
        // instead of a picture — the lesson of 2026-08-16.
        tearDownRepackager()
        isRunning = false
    }

    /// Logs the running title out at the server — **with the last known position.**
    ///
    /// With an account that has one allowed connection, a session left open is the next
    /// refusal; therefore before every source, episode and channel switch.
    private func signOut() async {
        guard let deregistration = core.finish(at: location) else { return }
        await send(deregistration)
    }

    /// Sends a report about the source — the mapping is in the ``core``, the same as on
    /// the TV. The request is captured **now**: after a switch the logout still belongs to
    /// the previous one.
    private func send(_ report: PlaybackReporter.Report) async {
        guard let source else { return }
        let forItem = request
        await PlaybackCore.send(
            report, duration: duration,
            about: PlaybackCore.ProgressRoute(
                begin: { try await source.begin(forItem) },
                notify: { state, isPaused in
                    try await source.notify(
                        location: state.position, duration: state.duration, zu: forItem, isPaused: isPaused)
                },
                finish: { location in try await source.finish(forItem, at: location) }))
    }

    public func togglePlayback() {
        isRunning.toggle()
        if isRunning {
            host.controller.play()
            applySpeed()
        } else {
            host.controller.pause()
        }
    }

    /// Jumps by a span — **–10 forward, +30 back.**
    ///
    /// The two numbers are not symmetric, and that is intentional: you jump back because
    /// you missed something (a sentence, ten seconds), forward because something is not
    /// interesting (an intro, thirty seconds).
    ///
    /// **For a channel in the buffer, within its limits** (AP58 G1, A1): before the oldest
    /// piece there is nothing any more, beyond the edge not yet. A channel without a buffer
    /// does not jump — until then a jump there set the position to zero.
    public func jump(_ span: TimeInterval) {
        if let timeShiftWindow {
            set(location: timeShiftWindow.target(location + span))
            return
        }
        guard job?.kind != .live else { return }
        set(location: max(0, min(duration, location + span)))
    }

    public func set(location incoming: TimeInterval) {
        location = incoming
        host.controller.seek(to: incoming)
    }

    /// The audio track to start with — **the rule "anime in the original audio".**
    ///
    /// **The switch was dead until 2026-09-07** It lived in
    /// `@AppStorage(`player.originalAudio`)`, and in the whole source nobody read it except
    /// the settings screen itself. Now it lives in the shared
    /// ``Core/AudioPreference`` — the same store the TV reads from — and is applied here.
    ///
    /// **Why the rule at all:** the audio-track automation takes the first matching one, and
    /// for a dubbed anime the first is the German one. Anyone who ordered original audio
    /// would otherwise get exactly what they cancelled.
    ///
    /// **Only for anime, and the source answers the question** — see
    /// ``PlaybackRequest/isAnime``. For channels and portals it says `false`: without genres
    /// and without an AniList identifier "maybe anime" would be no basis for switching an
    /// audio track.
    ///
    /// **If no Japanese track is found, everything stays at the file's default.** A rule
    /// that finds nothing must not silently land on some track — the same consideration as
    /// in ``Core/StartingTracks/select(for:isAnime:preference:interfaceLanguage:)``.
    private func chooseStartTrack(forItem job: PlaybackRequest) {
        // **The player applies, it does not choose** (E45, 2026-09-10). Until then half the rule
        // was rebuilt here: only the audio, only the anime case, and the subtitle tier
        // ("never / forced only / always") was left lying — it had been stored since E45 and
        // was never applied. The whole rule is in
        // ``Core/StartingTracks/select(for:isAnime:preference:interfaceLanguage:)`` and
        // needs a `MediaSource`; only the source has that, and it is now called there
        // (``JellyfinPlayerSource``).
        //
        // **Audio and subtitles belong together.** "Anime in the original audio" means
        // Japanese audio **and** subtitles in the interface language; anyone who switched only
        // the audio track delivered Japanese audio without text — exactly the state up to
        // today.
        if let audio = job.startAudio {
            host.controller.selectAudioTrack(audio)
        }
        if let subtitle = job.startSubtitle {
            host.controller.selectSubtitleTrack(subtitle)
        }
        // **The nothing is reported too.** A rule that finds nothing leaves the file's
        // default in place — and then the ledger should say that it ran and found
        // nothing, rather than that nothing is there at all.
        Diagnose.step(
            .playback,
            "Start tracks: audio \(job.startAudio.map(String.init) ?? "default"), "
                + "subtitles \(job.startSubtitle.map(String.init) ?? "default")")
    }

    public func select(audioTrack: PlaybackTrack.ID) {
        host.controller.selectAudioTrack(audioTrack)
        rememberAudio(audioTrack)
    }

    /// Remembers the language of the chosen audio track for this title (AP58 G1, A10) —
    /// **the same store as on the TV** (``Core/AudioMemory``), read at the next start in
    /// ``Core/PlaybackPlan``. Only for a recording, and only if the track names a language.
    func rememberAudio(_ track: PlaybackTrack.ID) {
        guard let job, job.kind == .recording,
            let language = job.audioTracks.first(where: { $0.id == track })?.language,
            !language.isEmpty
        else { return }
        AudioMemory.memorize(
            language, identifier: job.identifier, series: seriesID ?? request.series, in: audioStore)
    }

    public func select(subtitles: PlaybackTrack.ID?) {
        host.controller.selectSubtitleTrack(subtitles)
    }

    // MARK: - The source choice

    /// Fetches what is up for choice — **when the sheet opens and not before.**
    ///
    /// A second call does not fetch again: which hosts an episode lists does not change
    /// while you look at it, and every request goes against a third-party site.
    public func loadSelection() async {
        guard let source else { return }
        let forItem = request
        await sourceChoice.load(forItem: forItem.identifier) { try await source.host(zu: forItem) }
    }

    /// Continue playing on another host — **at the same position.**
    ///
    /// The position carries over, and the session is closed beforehand: with an account
    /// that has one allowed connection, a session left open is the next refusal.
    ///
    /// **And the one-time marker is reset.** It guards the re-fetching of an expired
    /// address; after a manual switch the address is a different one, and its expiry is a
    /// new one.
    public func switchTo(zu target: PortalHost) async {
        await signOut()
        host.stop()
        request = request.at(source: target.id, from: location)
        alreadyRefetched = false
        Diagnose.step(.playback, "Source switched: \(target.name) from \(Int(location)) s")
        await start()
    }

    /// Plays the next episode — **in the same player, from the position the server names.**
    ///
    /// **Until 2026-09-26 the button only closed the player** (AP58, finding S1): the view
    /// called `back()` there, and anyone who pressed "Next episode" was back on the
    /// detail page.
    ///
    /// **The running episode is ended cleanly beforehand**: position reported, history
    /// noted, session closed. Otherwise, with an account that has one allowed connection, an
    /// open session would stay behind, and the new episode would end in "occupied".
    ///
    /// **The request is resolved anew and not carried over.** The address fetched in
    /// advance may have expired in the meantime; `startAt` stays `nil` so that the server
    /// names the progress. Host choice and remuxer marker belong to the previous episode
    /// and do not travel along, series and series name do.
    public func playNext() async {
        if next == nil, let film = similarItem {
            await matches(film)
            return
        }
        guard let episode = next else { return }
        next = nil
        clock?.cancel()
        clock = nil
        await recordHistory()
        await signOut()
        host.stop()
        tearDownRepackager()
        request = PlaybackJob(
            identifier: episode.identifier, origin: request.origin, series: request.series,
            seriesTitle: request.seriesTitle)
        job = nil
        location = 0
        duration = 0
        alreadyRefetched = false
        Diagnose.step(.playback, "Next episode: \(episode.title)")
        await start()
    }

    /// Plays a title from the board or the similar movie — **in the same player.**
    ///
    /// **The filter asks here too** (``PlayerSource/mayPlay(_:zu:)``) — not only when
    /// filling the lists: the switch is the last place before the engine. The same clean
    /// ending as with the next episode.
    public func matches(_ title: MediaItem) async {
        guard let source, source.mayPlay(title, zu: request) else { return }
        next = nil
        similarItem = nil
        clock?.cancel()
        clock = nil
        await recordHistory()
        await signOut()
        host.stop()
        tearDownRepackager()
        let series = title.seriesID
        request = PlaybackJob(
            identifier: title.id, origin: request.origin, series: series,
            seriesTitle: series == nil ? nil : (title.parentTitle ?? request.seriesTitle))
        job = nil
        location = 0
        duration = 0
        alreadyRefetched = false
        Diagnose.step(.playback, "Chosen from the player: \(title.title)")
        await start()
    }

    /// Switch to another channel — **without leaving the player.**
    ///
    /// **The same path as a source switch and not a second one.** The session is closed,
    /// the engine stopped, the remuxer cleared away; ``start()`` already does all of
    /// that, and a separate path here would be the second place where an open connection
    /// can stay behind. With an account that has **one** allowed connection, that is
    /// exactly the next refusal.
    ///
    /// **Without a position.** A channel has none; `startAt` stays at zero, because a
    /// channel starts where it currently is.
    public func switchTo(toChannel identifier: String) async {
        guard identifier != request.identifier else { return }
        await signOut()
        host.stop()
        request = PlaybackJob(identifier: identifier, origin: .channelList)
        alreadyRefetched = false
        Diagnose.step(.playback, "Channel switched")
        await start()
    }

    /// Resolve the same source once more — **for an expired address.**
    ///
    /// The same path as the silent re-fetch in ``tick()``, only triggered by hand: anyone
    /// who puts the app away for a quarter of an hour comes back to a sheet that says
    /// "Address expired", and presses there instead of waiting behind a black picture.
    ///
    /// **The same request, only from the position** (player review, finding S3): until
    /// then the position here built a new request from identifier, origin and source —
    /// series, series name and the remuxer marker were dropped. "Continue watching" then
    /// opened the episode instead of the series (the finding of 2026-09-07 once more), and the
    /// remuxer failed a second time. **And the session closes beforehand**, as with
    /// ``switchTo(zu:)``.
    public func resolveAgain() async {
        await signOut()
        host.stop()
        alreadyRefetched = false
        request = request.from(location)
        await start()
    }

    // MARK: - Stillstand (Konzept Stillstand, Stufe 4 — Entscheidung 13)

    /// Whether the picture is currently standing although it should be running — **the same
    /// timeout as on the TV**, counted in the ``core`` (ticks times ``cadence``).
    public var settled: Bool { core.settled }

    /// What is behind the stall — `nil` without a remuxer of its own.
    public var stallFinding: StallInterpretation.Finding? { core.stallFinding }
    /// What the line delivers, measured by the engine — for "Line is tight" (AP75).
    public var lineFinding: LineFinding? { host.controller.lineFinding }

    /// The lines that went into the error trace for this target — the tap of the test.
    var stallLines: [String] { core.stallLines }

    /// Starts the guard over — **on every start, also on a source switch.**
    ///
    /// The interpretation starts anew only for a **different title**; the grip drops on
    /// every start (finding H1) — see ``Flows/PlaybackCore/newStartup(target:)``.
    func resetStall() {
        core.newStartup(target: request.identifier)
    }

    /// Tears down the remuxer — **and with it the interpretation's run** (finding H1).
    private func tearDownRepackager() {
        core.remuxerTornDown()
        repackager?.finish()
        repackager = nil
    }

    // MARK: - Skipping and next episode (AP58 R4)

    /// The segment for which a button is currently shown — only within its window.
    public var skipOffer: MediaSegment? { core.skipOffer(at: location) }

    /// Jumps to the end of the offered segment; it is not offered again afterwards.
    public func skip() {
        guard let end = core.skip(at: location) else { return }
        set(location: end)
    }

    // MARK: - Sleep timer (AP85)

    public var sleepChoice: PlaybackCore.SleepChoice { core.sleepChoice }

    public func setSleep(_ choice: PlaybackCore.SleepChoice) {
        core.setSleep(choice)
        noteViewer()
    }

    public var sleepMinutesLeft: Int? { core.sleepMinutesLeft() }

    // MARK: - Still watching? (AP85)

    public var asksStillWatching: Bool { core.asksStillWatching }

    /// A touch of the viewer — resets the count.
    public func noteViewer() { core.noteViewerPresent() }

    /// "Keep watching".
    public func keepWatching() {
        core.confirmStillWatching()
        if !isRunning { togglePlayback() }
    }

    /// The section just skipped by itself — for "Intro skipped · Back" (AP85).
    public var autoSkipHint: MediaSegment? { core.autoSkipHint() }

    /// "Back": to the start of the section skipped by itself; it then runs.
    public func undoAutoSkip() {
        guard let start = core.undoAutoSkip() else { return }
        set(location: start)
    }

    /// The offer of the next episode — or of the similar movie — with the seconds until
    /// the switch.
    ///
    /// **The phone now counts down like the TV** (AP58 R4, report A S1): until then the
    /// button stood fixed ninety seconds before the end, without a counter and without
    /// dismissing, on the grounds that skipping ahead had already cost some people their
    /// sleep. The answer to that is ``stay()`` — one press, and the credits run.
    public var nextOffer: NextUpPrompt.State? {
        next == nil && similarItem == nil ? nil : core.nextOffer
    }

    /// What the offer is called — the next episode or the similar movie.
    public var offerTitle: String? { next?.title ?? similarItem?.title }
    /// The picture of the offer card — the episode's own image where the source sets one,
    /// otherwise its backdrop; a similar film shows the placeholder.
    public var offerImage: URL? { next.flatMap { $0.image ?? $0.backdrop } }

    /// Dismisses the offer — for this title.
    public func stay() {
        core.dismissNext()
    }

    // MARK: - Uhr und Meldung

    /// How long a tick of the timer is.
    ///
    /// **One number, used in two places:** the timer sleeps that long, and the stall guard
    /// keeps counting its time with it. Anyone who changes the tick changes both — otherwise
    /// the timeout would run in ticks instead of seconds.
    static let cadence: TimeInterval = 1

    /// Starts the timer.
    ///
    /// - Parameters:
    ///   - takt: how long it sleeps between two ticks.
    ///   - abgriff: where it takes engine and pulse from — `nil` means: from the host and
    ///     from the remuxer. **The seam of the test** (finding S1): the trap lay in the
    ///     timer itself, not in the tick, and a test that calls ``tick(controller:pulse:)``
    ///     directly does not see it.
    ///
    /// **After the sleep it asks once more**: a cancellation wakes the sleep, and without
    /// this check another tick would run afterwards — against an engine that ``start()``
    /// has just torn down.
    func startClock(
        cadence: Duration = .seconds(PlayerModel.cadence),
        tap: (@MainActor () -> (any PlaybackController, (any RepackerPulse)?))? = nil
    ) {
        clock?.cancel()
        clock = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: cadence)
                guard !Task.isCancelled, let self else { return }
                let (controller, pulse) = tap?() ?? (self.host.controller, self.repackager?.pulse)
                await self.tick(controller: controller, pulse: pulse)
            }
        }
    }

    /// Starts a switch from the tick — **outside the timer** (finding S1).
    private func switchOffBeat(_ step: @escaping @MainActor (PlayerModel) async -> Void) {
        guard switchObserver == nil else { return }
        switchObserver = Task { [weak self] in
            guard let self else { return }
            await step(self)
            self.switchObserver = nil
        }
    }

    /// One tick of the timer: state, position, stall, report to the server.
    ///
    /// **Engine and pulse are passed in and not fetched itself** (stall tier 4,
    /// 2026-09-25). Until then `tick()` read `host.controller` — a real
    /// ``Playback/EngineHost`` — and was therefore not testable without an engine. But this
    /// is exactly where the connection between remuxer, interpretation and board sits.
    func tick(controller: any PlaybackController, pulse: (any RepackerPulse)?) async {
        // **Before the switch and not inside it.** It bails out early on `.failed`, and
        // there the case belongs to the error and not to the stall.
        if core.observeStall(
            status: controller.status, location: controller.position,
            loadedUntil: controller.bufferedRange?.upperBound, pulse: pulse)
        {
            // **The bar comes with the board.** Anyone looking at a standing picture is looking
            // for the way out or for the other source — the bar carries both.
            isBarVisible = true
            Diagnose.step(
                .playback, "Picture frozen for \(Int(Double(core.silentTicks) * Self.cadence)) s")
            // **Dried-up supply is requested anew** — the same rule as on the TV, reasoning at
            // ``Flows/PlaybackCore/resupplyLimit``. The path is that of "Resolve again":
            // the same request from the position where it stood.
            let here = controller.position
            if core.restartAfterSupplyRanDry(
                title: request.identifier, location: here,
                loadedUntil: controller.bufferedRange?.upperBound,
                live: job?.kind == .live)
            {
                Diagnose.step(
                    .playback,
                    "Supply dried up at \(Int(here)) s — new request "
                        + "(\(core.resupplyAttempts) of \(PlaybackCore.resupplyLimit))")
                request = request.from(here)
                switchOffBeat { await $0.start() }
                return
            }
        }
        // **The engine says when it starts — not the startup.** `.playing` and `.paused`
        // both mean that a picture is up; `.opening` and `.buffering` mean that the spinner
        // stays. A `.failed` is a failure **after** the start, and that had no screen at all
        // up to here.
        let previous = lastStatus
        lastStatus = controller.status
        if controller.status == .playing, previous != .playing { reapplySpeed(on: controller) }
        idleLock.hold(IdleLock.keepsAwake(controller.status))
        switch controller.status {
        case .playing, .paused, .ended:
            if state != .isPlaying { state = .isPlaying }
        case .failed:
            // **A failure logs out too** — otherwise the server carries the session on, and with
            // an account that has one connection that is the next refusal.
            if let deregistration = core.episode(status: .failed, location: location, duration: duration)
                .report
            {
                await send(deregistration)
            }
            // **An expired portal address is re-fetched, not reported.**
            //
            // It is valid for five minutes (`Strom.gueltig_bis` in the bridge, since 2026-09-06 also in
            // the contract to the outside), and five minutes are shorter than any interruption —
            // on the phone the case occurs constantly. Without the expiry, the only possible answer
            // would be to resolve anew on **every** playback error; with it, only what has really
            // expired is fetched.
            //
            // **Exactly once.** A second failure on a fresh address is no longer an expiry but a
            // host that does not hand over the film — and re-fetching in a loop would be a request
            // storm against a third-party site.
            if job?.isExpired() == true, !alreadyRefetched {
                alreadyRefetched = true
                Diagnose.step(.playback, "Portal address expired — fetching it again")
                switchOffBeat { await $0.start() }
                return
            }
            state = .disrupted(
                DisruptionInterpretation.state(
                    forItem: Dropout.motor, origin: request.origin, network: networkMonitor?.route,
                    address: job?.address,
                    certificateTrustedByAppOnly: Self.trustedByAppOnly(job?.address)))
            return
        case .idle, .opening, .buffering:
            break
        }
        location = controller.position
        if controller.duration > 0 { duration = controller.duration }
        let window = hasTimeShift ? TimeShift.Window(controller.timeShiftWindow) : nil
        if window != timeShiftWindow { timeShiftWindow = window }
        // **Only set when something is there.** An intermediate `nil` — on a source switch
        // the player knows no size for one tick — would take the gesture away from the view in
        // the middle of the film.
        if let format = host.imageFormat { imageFormat = format }
        // **The lock screen is kept up to date on the same tick.** The bridge writes only when
        // something visible has changed — one call per second therefore costs nothing.
        LockScreen.advance(location: location, duration: duration, isRunning: isRunning)

        // **Report and next episode from the core** (AP58 R4): every ten seconds of distance
        // in absolute value, pause and resume immediately, and at the end of the counter the
        // next episode. An end without a successor does **not** close the player on the phone —
        // the still frame with the bar is the usual ending here, and the swipe path leads out.
        // **"Still watching?" holds the picture** (AP85).
        if core.asksStillWatching, isRunning { togglePlayback() }
        // **Intro and recap by themselves**, when the profile wants it (AP85 binge package).
        if let end = core.autoSkip(at: location) { set(location: end) }
        let episode = core.episode(status: controller.status, location: location, duration: duration)
        if let report = episode.report { await send(report) }
        if episode.step == .sleep {
            // **The sleep timer** (AP85): the phone stops; the still frame is its ending.
            if isRunning { togglePlayback() }
        }
        if episode.step == .next, next != nil {
            // **Counted only here** — the counter switched, nobody touched (AP85).
            core.noteAutoAdvance()
            switchOffBeat { await $0.playNext() }
        }
    }

    /// **The one write place of the history.**
    ///
    /// It sits at the end of playback and not before — exactly that was the error of the TV
    /// app: four write places, all **before** the player, and anyone who switched inside it
    /// got past none of them. Here everyone who stops gets past it.
    private func recordHistory() async {
        guard let job, job.belongsInHistory else { return }
        var history = await HistoryStore.shared.load()
        history.note(
            job.entry(at: location, series: request.series, seriesTitle: request.seriesTitle))
        await HistoryStore.shared.save(history)
        Diagnose.step(.playback, "History noted: \(job.title)")
    }
}

// MARK: - Gleichstand mit dem Fernseher (AP58 G1, Entscheidung 27)

extension PlayerModel {

    /// Fetches what the player shows beyond the title — **after the start and not before.**
    ///
    /// Preview images (A7) and the similar movie (A8) come from the same content source as
    /// on the TV. **The similar movie only without a next episode and only for a film** —
    /// the entry point does not always know the series, so the title is looked up once for
    /// that.
    ///
    /// **The series is also looked up when there is a next episode** (player review,
    /// finding S4): the audio choice per title remembers under it, and ``Core/PlaybackPlan``
    /// reads there. If the question stood behind "is there a next episode?", the phone
    /// remembered under the episode, and the next one began again in the general language —
    /// unlike the TV, which remembers under `target.seriesID`.
    ///
    /// **Every answer applies only to its own startup** (finding S8).
    func loadExtra(zu fetched: PlaybackRequest, from source: any PlayerSource) async {
        guard let contents = source.contents(zu: request) else { return }
        let forItem = request
        let mine = startup
        let frames = (try? await contents.trickplay(for: fetched.identifier)) ?? nil
        guard mine == startup else { return }
        trickplay = frames
        if seriesID == nil, let title = try? await contents.item(id: fetched.identifier) {
            guard mine == startup else { return }
            seriesID = title.seriesID
        }
        guard next == nil, seriesID == nil else { return }
        let related = await InfoBoard.allowedRelated(
            zu: fetched.identifier, from: contents, mayPlay: { source.mayPlay($0, zu: forItem) })
        guard mine == startup else { return }
        similarItem = related
    }

    /// Loads the board — **only when the sheet opens** (A4).
    public func loadBoard() async {
        guard let source, let contents = source.contents(zu: request), let identifier = job?.identifier,
            job?.kind == .recording
        else { return }
        let forItem = request
        await board.load(
            source: contents, identifier: identifier, series: seriesID ?? request.series, next: nil,
            mayPlay: { source.mayPlay($0, zu: forItem) },
            applies: { [weak self] in self?.job?.identifier == identifier })
    }

    /// Whether there is a board — only for a recording with a catalog.
    public var hasBoard: Bool {
        job?.kind == .recording && source?.contents(zu: request) != nil
    }

    // MARK: Zeitversatz (A1)

    /// **The shared switch** (``Flows/TimeShift/applies(kind:deliveryRoute:session:)``).
    public var hasTimeShift: Bool {
        guard let job else { return false }
        return TimeShift.applies(
            kind: job.kind, deliveryRoute: job.target.decision.delivery, session: repackager?.session)
    }

    /// Whether jumping is possible — a recording, or a channel with a buffer.
    public var isSeekable: Bool {
        job?.kind == .recording || timeShiftWindow != nil
    }

    /// Whether the position lies behind the running programme.
    public var isBehindLive: Bool {
        guard let timeShiftWindow else { return false }
        return !timeShiftWindow.atEdge(at: location)
    }

    /// Back to the running programme.
    public func backToLive() {
        guard hasTimeShift else { return }
        Diagnose.step(.playback, "Back to live")
        host.controller.seekToLiveEdge()
        if let margin = timeShiftWindow?.margin { location = margin }
    }

    // MARK: Kapitel (A5)

    public var hasChapters: Bool {
        ChapterJump.hasChapters(kind: job?.kind ?? .recording, chapters: job?.chapters ?? [])
    }

    public func skipChapter(forward: Bool) {
        guard let job,
            let target = ChapterJump.target(
                kind: job.kind, chapters: job.chapters, location: location, forward: forward)
        else { return }
        set(location: target)
    }

    // MARK: Tempo (A6)

    /// Whether the tiers are offered — the engine says so, and never for a channel.
    public var speedOffered: Bool {
        SpeedChoice.isOffered(
            supportsSpeed: host.controller.supportsSpeed, kind: job?.kind ?? .live)
    }

    public func setRate(_ fresh: Double) {
        guard speedOffered, fresh != rate else { return }
        rate = fresh
        host.controller.setRate(fresh)
        Diagnose.step(.playback, "Playback speed: \(fresh)x")
    }

    /// The hold gesture — **in addition to the choice**: pressed it doubles, released it is
    /// again the chosen speed and not 1 (``Flows/SpeedChoice/afterHold(chosen:)``).
    /// **The chosen speed survives a pause** — the system player sets the rate to 1 on
    /// resume, and the display would otherwise claim a speed that does not apply. The same
    /// move as `applySpeed()` on the TV.
    func applySpeed() {
        guard rate != 1, speedOffered else { return }
        host.controller.setRate(rate)
    }

    /// Applies the chosen speed to an engine that is just starting to play (player review,
    /// finding S6). **This was missing on the phone:** after a source switch or re-fetching
    /// the same title the display stayed at 1.5×, but the new engine ran at 1× until the
    /// next pause. The same rule as in the tick on the TV — only on the transition to
    /// `.playing`, because with the system player the rate is also the start switch.
    func reapplySpeed(on controller: any PlaybackController) {
        guard rate != 1,
            SpeedChoice.isOffered(supportsSpeed: controller.supportsSpeed, kind: job?.kind ?? .live)
        else { return }
        controller.setRate(rate)
    }

    public func holdSpeed(_ pressed: Bool) {
        host.controller.setRate(
            pressed ? SpeedChoice.holdSpeed : SpeedChoice.afterHold(chosen: rate))
    }
}

/// **A teardown in the engine means: the server has answered** — the shared
/// interpretation reads it as ``EngineDropout``, just as the TV reports its marker
/// `fromPlayer`.
extension PlayerModel.Dropout: EngineDropout {}
