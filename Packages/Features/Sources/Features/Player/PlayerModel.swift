import Core
import DesignSystem
import Flows
import Foundation
import JellyfinKit
import Observation
import Playback
import PortalKit
import SwiftUI

#if canImport(UIKit)
    import UIKit
#endif

/// Where the model gets its engine from.
///
/// Explicitly the host and not the engine itself: ``EngineHost`` swaps the
/// engine as soon as a target demands a different one — after the next episode the
/// system player can become VLC because the file is a different container. A
/// once-remembered ``PlaybackController`` then points at the old, stopped
/// engine: the bar stays at zero while the film runs, and nothing in the code
/// shows it. ``EngineHost`` describes the same trap for the forwarding
/// of change notifications; here it occurs a second time.
///
/// Kept this narrow because this contract is also the attachment point for the
/// tests: a double needs nothing more than an engine and the
/// ability to start a target. Without this separation the playback UI could
/// only be tested with a running server and a connected TV — and would
/// therefore never be tested.
public protocol PlaybackHosting: AnyObject {

    var controller: any PlaybackController { get }

    func start(_ target: PlaybackTarget)
    /// Like ``start(_:)``, but with the buffer for the direct renderer — see
    /// ``EngineHost/start(_:samples:)``. Hosts without a renderer leave the buffer
    /// alone; the default below does exactly that.
    func start(_ target: PlaybackTarget, samples: SampleQueue?)
    func stop()

    /// Passes on a frame rate measured later — see
    /// ``EngineHost/adopt(contentFrameRate:)``.
    func adopt(contentFrameRate: Double)

    /// The picture currently shown as JPEG — see ``EngineHost/stillFrame()``.
    func stillFrame() -> Data?
}

/// ``EngineHost`` already fulfils the contract with its existing members.
/// The extension lives here and not there because the host need not know anything about the
/// UI — the dependency runs in one direction only.
extension EngineHost: PlaybackHosting {}

extension PlaybackHosting {
    /// The default for hosts without a renderer — the test doubles.
    public func start(_ target: PlaybackTarget, samples: SampleQueue?) { start(target) }
    public func stillFrame() -> Data? { nil }
}

/// The state of the playback UI.
///
/// Carries everything the controls need, and recomputes nothing that already lives in
/// ``Core``: the pacing of the progress reports comes from
/// ``PlaybackReporter``, the next-episode offer from ``NextUpPrompt``, the
/// skipping from ``MediaSegment``. This model connects them with the engine and
/// with the source — and it is exactly this connection that goes wrong.
@Observable
public final class PlayerModel {

    // MARK: - Target and environment

    /// What is playing right now. Changes when the next episode is taken over.
    public internal(set) var target: PlaybackTarget

    /// Whether the info area would have anything to say for this target at all.
    ///
    /// Its three index cards — cast, further episodes, audio and subtitles —
    /// all refer to a **file**. A running channel has none of them:
    /// no cast, no sibling episodes, and its tracks are in the stream and
    /// not in a media library. The area slid out there anyway and stayed empty.
    ///
    /// A trailer is the same case for a different reason: it carries no
    /// ``PlaybackTarget/itemID`` through which anything could be looked up.
    public var hasInfoPanel: Bool { target.kind == .recording }

    let engine: any PlaybackHosting
    let source: (any ContentSource)?

    /// The path to the neighbouring channel, or `nil` outside the live area.
    ///
    /// **As a question to the outside and not as a list in here.** The player knows no
    /// source — that is why a channel, a film and a trailer look the same to it.
    /// A channel list in the player would mean tearing down that separation again: it would have to know
    /// what a group is, how things are sorted and what is hidden. It asks instead "give me the next one" and gets a
    /// finished target.
    /// **The running address goes out with it, otherwise the neighbour is counted wrong.**
    /// Whoever calculates outside knows only the channel the player was opened with
    /// — the switch afterwards happens in here. Without the address you got exactly
    /// one step and after that always back to the same one.
    let neighbourChannel: (@MainActor (URL, Int) -> PlaybackTarget?)?

    /// The favourite mark of the running channel, set and read from outside.
    ///
    /// **Two tasks and therefore two parameters.** The player does not keep the mark
    /// itself: it belongs to the channel list, survives a reload and hangs on
    /// an identifier that the provider does not assign. A flag in here would drift
    /// apart as soon as someone marks the same channel in the live area.
    let channelFavorite: (@MainActor () -> Bool)?
    let setChannelFavorite: (@MainActor (Bool) -> Void)?

    /// The shell's filter for every title the player offers or plays **on its own** — the offer after the end, the index card and the press on it.
    ///
    /// **The player knew no rule** (check 2026-09-25, finding 1): after a
    /// released film it offered a child the next part of a collection or a
    /// "similar film" that the funnel of ``MainView`` would never have opened — a
    /// press on "Play" played it anyway. The question comes from outside because only
    /// the shell knows profile, child mode and origin scope
    /// (``ParentalControls/ChildScope/opens(_:origin:)``).
    ///
    /// By default it lets everything through; every build path in the app passes it in via
    /// ``PlayerScreen``, and there it is mandatory.
    let mayPlay: @MainActor (MediaItem) -> Bool

    /// Whether the running channel can be remembered.
    public var canFavoriteChannel: Bool {
        target.kind == .live && channelFavorite != nil
    }

    /// Whether the running channel is remembered.
    ///
    /// **The mark lives outside** — in the channel store, not here; this model only queries
    /// it. So that the view still sees the change, ``savedPosition`` counts
    /// along: it is read and thereby makes the answer observable.
    ///
    /// **This used to be `objectWillChange.send()`** — with `@Observable` that no
    /// longer exists, and it is no loss: a hand signal to the view says "something
    /// has changed"; a read counter says **what**.
    public var isChannelFavorite: Bool {
        _ = savedPosition
        return channelFavorite?() ?? false
    }

    /// Counts every toggle of the channel mark. See ``isChannelFavorite``.
    var savedPosition = 0

    public func toggleChannelFavorite() {
        guard canFavoriteChannel else { return }
        setChannelFavorite?(!isChannelFavorite)
        // The bar stays up: the heart fills, and you are meant to see it.
        noteInteraction()
        savedPosition += 1
    }

    /// Whether the channel can be switched — only for live and only with neighbours.
    public var canSwitchChannel: Bool {
        target.kind == .live && neighbourChannel != nil
    }
    /// Needed for the **next** episode: its address only comes into being here,
    /// and without the limit it would stay valid indefinitely although the viewer is away.
    let quality: StreamQuality

    /// The UI language — fallback for the subtitles of the
    /// anime rule when no general language rule is set.
    let interfaceLanguage: String

    // MARK: - What the engine reports

    public internal(set) var status: PlaybackStatus = .opening
    public internal(set) var position: TimeInterval = 0
    public internal(set) var duration: TimeInterval = 0

    /// The tracks are fetched anew on every tick and not once at start.
    ///
    /// VLC only determines them while playback starts up — anyone who asks right after
    /// opening gets an empty list and shows the viewer "no tracks" for the rest
    /// of the film. That is how the contract of ``PlaybackController`` states it
    /// and it was noticed in the evidence from E0.
    public internal(set) var audioTracks: [PlaybackTrack] = []
    public internal(set) var subtitleTracks: [PlaybackTrack] = []
    public internal(set) var selectedAudioTrack: PlaybackTrack.ID?
    public internal(set) var selectedSubtitleTrack: PlaybackTrack.ID?

    // MARK: - What the source knows about it

    /// The sections of the title — they live in the ``core``.
    public var segments: [MediaSegment] { core.segments }
    public internal(set) var nextEpisode: MediaItem?

    /// Whether the offer shows a **similar film** instead of the next episode.
    ///
    /// Only decides the label: "Similar film in 10" instead of "Next
    /// episode in 10". The mechanics — counter, dismissal, switch — are the same,
    /// and that is exactly why both go through the same ``nextEpisode`` slot.
    public internal(set) var nextIsSimilar = false
    public internal(set) var trickplay: Trickplay?

    /// Cast, details and further episodes — **shared with the phone** (AP58 G1, A4,
    /// ``Flows/InfoBoard``). The three names below remain for the views.
    public let board = InfoBoard()
    public var cast: [Person] { board.cast }

    /// The full title for the details line of the info area —
    /// year, director, runtime exist only on the whole title, not on the target.
    public var info: MediaItem? { board.title }
    public var siblingEpisodes: [MediaItem] { board.more }
    /// Whether the board has answered — afterwards "empty" really means empty and not "loading"
    /// (player check, finding S7).
    public var isInfoLoaded: Bool { board.loaded }

    /// The source choice of a portal title — **shared with the phone** (AP58 G1, A9,
    /// ``Flows/SourcePickerFlow``). New on the TV: it sits in the track board and
    /// under the error screen.
    public let sourceChoice = SourcePickerFlow()

    /// Where the audio choice is remembered per title (AP58 G1, A10, ``Core/AudioMemory``) —
    /// passed in so the tests do not write into the real Keychain.
    let audioStore: any KeyValueStore

    // MARK: - Control state

    public internal(set) var isBarVisible = true
    public var isInfoVisible = false
    public var isChoosingTracks = false
    /// The next-episode offer — computed in the ``core``.
    public var nextUp: NextUpPrompt.State? { core.nextOffer }

    /// Whether the bar is actually drawn.
    ///
    /// ``isBarVisible`` alone is not enough: with the info area or the track
    /// choice open it deliberately stays set — auto-hide pauses there
    /// so the bar is back after closing, see
    /// ``hideBarIfIdle(now:)``. It must not be drawn meanwhile, though:
    /// the gradient of the overlays is only 86 % opaque at the top, and
    /// title line, rail and button row showed through as ghost text between the
    /// cast names. In a dark environment that looks like a
    /// rendering bug, not like intent.
    public var showsBar: Bool {
        isBarVisible && !isInfoVisible && !isChoosingTracks
    }

    /// Whether the view should close.
    ///
    /// Not `status == .ended` alone, and explicitly not "there is no next
    /// episode": someone who dismissed the offer to watch the credits **has** a
    /// next episode and still has nothing left to see. Without this distinction
    /// the view stays on a black screen with the bar standing, and the way
    /// back can only be guessed via the menu button.
    public internal(set) var shouldClose = false

    /// Set while seeking on the rail. Two values instead of one, because
    /// both hold at the same time: the engine keeps playing at its position while
    /// the display already shows the targeted one. A shared field would mean jumping immediately on every
    /// movement — with converted streams you would then wait for a new buffer
    /// after every key press.
    public internal(set) var scrubPosition: TimeInterval?

    // MARK: - Internal state

    /// What can be decided without an engine — reports, next episode, skipping,
    /// stall. **Shared with the phone** (AP58 R4, ``Flows/PlaybackCore``); the
    /// watch already counts here during startup, because the raw-stream fallback of a channel
    /// that never delivers a picture hangs on it.
    public let core = PlaybackCore(step: PlayerModel.tickSeconds, watchesDuringStartup: true)

    var ticker: Task<Void, Never>?

    /// The startup measurement of the running target — see ``StartupTiming``.
    ///
    /// Publicly readable because the playback view shows it while
    /// diagnostics are switched on: whoever measures wants to see the number without
    /// reading a report afterwards.
    public internal(set) var startupTiming: StartupTiming?

    /// The fine tick that only runs until the first picture.
    var startupProbe: Task<Void, Never>?
    var barShownAt = Date()

    var isAdvancing = false

    // MARK: - Screen saver

    /// Whether this state must keep the device awake.
    ///
    /// tvOS counts only **inputs** as activity — a bare video surface without
    /// a key press counts as idle, and after the configured timeout the
    /// screensaver slides into the middle of the film. The device is therefore kept awake
    /// while a picture is running or about to run; "buffering" counts, because there
    /// the viewer is waiting for the continuation. A pause does not: whoever
    /// pauses and leaves should get the screensaver — that is its purpose.
    static func keepsDeviceAwake(_ status: PlaybackStatus) -> Bool {
        switch status {
        case .playing, .buffering, .opening: true
        case .idle, .paused, .ended, .failed: false
        }
    }

    /// Writes the idle lock to the system.
    ///
    /// As a default value of the setup and not as hard wiring: the tests
    /// pass in their own version and see what would be set — without UIKit
    /// and without shared state that would become a race
    /// when tests run in parallel.
    public static let systemIdleGuard: @MainActor (_ disabled: Bool) -> Void = { disabled in
        #if canImport(UIKit)
            UIApplication.shared.isIdleTimerDisabled = disabled
        #endif
    }

    let idleGuard: @MainActor (_ disabled: Bool) -> Void

    /// The value written last, so the system is not written to
    /// on every tick — and so ``finish()`` knows whether it has to clean up.
    var isHoldingIdleGuard = false

    func updateIdleGuard() {
        let wanted = Self.keepsDeviceAwake(status)
        guard wanted != isHoldingIdleGuard else { return }
        isHoldingIdleGuard = wanted
        idleGuard(wanted)
    }

    /// Releases the lock unconditionally — the path for the end of the view.
    ///
    /// Standalone instead of through ``updateIdleGuard()``: when closing, what counts is not
    /// the engine's state but that nobody is watching any more. A lock that
    /// survives the view's disappearance would keep the TV awake all night
    /// — and nobody would see from the app that it was the cause.
    func releaseIdleGuard() {
        guard isHoldingIdleGuard else { return }
        isHoldingIdleGuard = false
        idleGuard(false)
    }

    /// Measures stalls and jumps of the running playback — only with
    /// verbose recording (``DebugMode``).
    ///
    /// The tick here is exactly the sample ``PlaybackTrace`` was built for:
    /// position, state and clock are all already at hand. The finding goes into the diagnostics trace
    /// as a measurement on finishing and thereby into the report — where it
    /// then says "14 dropouts, 23 seconds in total" instead of "did not run smoothly".
    let playbackTrace = PlaybackTrace()

    /// Writes the finding of the recording — as a defect, if it is one.
    ///
    /// The one place where that happens: both callers (the end of
    /// playback and the title change) had the same guard and the same
    /// gap.
    func reportTrack() {
        let finding = playbackTrace.finding(at: Date())
        Diagnostics.probe(finding.text, verdict: finding.isDefect ? .problem : .plain)
    }

    public init(
        target: PlaybackTarget,
        engine: any PlaybackHosting,
        source: (any ContentSource)?,
        quality: StreamQuality = .unlimited,
        interfaceLanguage: String = "en",
        neighbourChannel: (@MainActor (URL, Int) -> PlaybackTarget?)? = nil,
        channelFavorite: (@MainActor () -> Bool)? = nil,
        setChannelFavorite: (@MainActor (Bool) -> Void)? = nil,
        mayPlay: @escaping @MainActor (MediaItem) -> Bool = { _ in true },
        idleGuard: @escaping @MainActor (_ disabled: Bool) -> Void = PlayerModel.systemIdleGuard,
        /// Who builds the remuxer. The default is the real one via
        /// ``rawStreamStore`` — see ``PlayerModel/liveOrFileRemux(store:)``.
        remux: RemuxBuilder? = nil,
        /// Where the memo of the raw streams lives.
        ///
        /// **Passed in since 2026-09-11, and the trigger was a check run.**
        /// ``RawStreamMemory`` used to be fetched here hard-wired via `SecureStore()` — that is, from
        /// the **real** Keychain of the device it runs on. Three tests of
        /// live playback therefore had to use it and heal it afterwards,
        /// and because Swift Testing runs concurrently, that is a read-modify-write
        /// on **process-wide shared** state: the `save` of one test
        /// overwrites the entry of another.
        ///
        /// **It carries two things, and the second was the actual reason.** Besides the
        /// memo per address (``RawStreamMemory``) it holds the **rule** per
        /// peer and title (``RawStreamRule``, see ``learnRawStream(_:)``). The
        /// first attempt on 2026-09-11 only passed in the memo — and the test kept
        /// failing: the three live tests use the **same** host and the
        /// **same** title, so the same rule key. Once the rule said "raw" after two
        /// runs, the model went straight to the raw stream and never built up
        /// again.
        ///
        /// It showed up sometimes in the debug build, sometimes in the release build, never alone — the
        /// kind of bug you look for in the wrong place.
        rawStreamStore: any KeyValueStore = SecureStore(),
        /// Where the audio choice per title lives — the person's compartment (``Core/ProfileStore``).
        audioStore: any KeyValueStore = ProfileStore.playback
    ) {
        self.audioStore = audioStore
        self.target = target
        self.engine = engine
        self.interfaceLanguage = interfaceLanguage
        self.idleGuard = idleGuard
        self.remux = remux ?? Self.liveOrFileRemux(store: rawStreamStore)
        self.neighbourChannel = neighbourChannel
        self.channelFavorite = channelFavorite
        self.setChannelFavorite = setChannelFavorite
        self.mayPlay = mayPlay
        self.source = source
        self.quality = quality
        self.duration = target.duration ?? 0
        self.position = target.startAt
        core.newTarget(
            reportsProgress: target.tracksProgress, isRecording: target.kind == .recording,
            sameTitle: false)
        self.rawStreamStore = rawStreamStore
    }

    // MARK: - What the extensions hold on to
    //
    // **Since AP58 R4 the model spans several files** (report C, giant file no. 2):
    // setup, tick, controls, channels, stall, tracks and next episode each as
    // `PlayerModel+….swift`. Stored properties may only live here — the
    // extensions read and write them, so they are visible module-wide instead of
    // `private`.

    /// Where the memo of the raw streams lives — see the parameter in the initialiser.
    let rawStreamStore: any KeyValueStore

    let remux: RemuxBuilder

    /// The in-app remuxer while it runs.
    ///
    /// **It must be held on to.** It keeps the server on `127.0.0.1` alive, which
    /// serves the engine; if it went away, playback would lose
    /// its source in the middle of the film — and with an error message that points at the network.
    var remuxHandle: AnyObject?
    var stopRemux: (@Sendable () -> Void)?

    /// Counts the engine starts so only the most recent one gets its turn.
    ///
    /// **Because the remuxer needs time.** Between "channel chosen" and "remuxer
    /// up" lie several seconds for a running stream; whoever switches during that
    /// time would otherwise have two remuxers on the network and two engines on the
    /// audio — at the provider also two connections, and it allows only one.
    var engineStartGeneration = 0

    /// The running setup while it lasts.
    ///
    /// Held on to so the tests can await it instead of letting the event loop
    /// run on the off chance — a test that relies on `Task.yield()`
    /// is one that turns red for no reason at some point. ``finish()`` also
    /// cancels it.
    var engineStartTask: Task<Void, Never>?

    /// Set by the holder: the view gets a running engine back
    /// and must not restart it (F-040, 2026-09-04: "back to full screen"
    /// meant a restart — balance sheet, a second connection at the provider, which
    /// allows only one, and a hang lasting minutes).
    var resumesFromPictureInPicture = false

    /// The sign-off on leaving — awaitable for the tests, instead of hoping for a
    /// pass of the event loop.
    var deregistration: Task<Void, Never>?

    /// The running observation of the live supply: source and
    /// buffering messages of the current target.
    var supplyWatch: (source: URL, dips: Int)?
    /// Whether the interim status "no picture after five seconds" has already been
    /// written — once per **startup**.
    ///
    /// **And that is why it must be reset.** The first version only set
    /// it, never reset it — "once per startup" thereby became "once per
    /// player session", and whoever zaps through twenty channels would have got at most a
    /// single line. In the diagnosis of 2026-08-23 it went unnoticed only because the two cases
    /// sat in different player instances.
    var reportedSlowStart = false

    var wasPlayingBeforeBackground = false

    var lastToggleAt = Date.distantPast

    /// The chosen speed. 1 is the default.
    public internal(set) var rate: Double = 1

    /// Switches to the neighbouring channel.
    ///
    /// **Via ``adopt(_:)`` and not via a new screen.** A second
    /// player above the first would mean two engines and two audio tracks at the same time —
    /// the same rationale as for the episode change. At the provider there is also the fact that
    /// it allows only one connection: two open streams are not a cosmetic
    /// flaw there but the end of playback.
    /// For which live address the TS fallback has already run — once per address.
    var liveFallbackAttempted: URL?

    /// For how many ticks audio has already been running without a picture.
    var blindTicks = 0

    /// How many ticks the running startup has already been waiting.
    var startTicks = 0

    /// Whether the engine has actually played since the last start.
    ///
    /// **This decides what a failure means.** A channel that
    /// never delivered a picture is on the wrong path — fallback. A channel
    /// that played and then broke off was on the **right** path, and the cause
    /// is temporary: the feed stood still for longer than one and a half
    /// segment lengths (`-12888`), the connection broke, the provider cut over.
    /// Answering that with a path switch turns three seconds
    /// of broadcast pause into a permanently wrong memory.
    var hasPlayedSinceLoad = false
    /// Whether this startup has already been counted as a success of the playlist — see
    /// ``noteListUsed()``.
    var isListInUse = false

    /// Whether the button may appear in the bar — tracked from the window
    /// controller, in the tick.
    public internal(set) var canPictureInPicture = false
    /// The view should leave: the window is up, the holder has taken over.
    public internal(set) var leavesForPictureInPicture = false

    /// How often this channel was up in this session.
    var liveStalls = 0

    var lastSeenStatus: PlaybackStatus = .idle

    /// Whether a jump through the server is running.
    ///
    /// As long as that holds, the tick does not take over the engine's position — the old one
    /// still reports from the abandoned position, and the bar would otherwise jerk back.
    var isRestarting = false

    /// Counts the jumps through the server so only the last one counts.
    ///
    /// **The protection against fast scrubbing.** Every long jump fetches the title
    /// anew from the server; two of them in parallel would mean two encodes and two
    /// engine starts whose order nobody knows any more. A new jump therefore
    /// cancels the running one, and whatever a cancelled one would still have done after its
    /// wait points is recognised by its number and discarded.
    var restartGeneration = 0
    /// The running jump through the server — awaitable for the same reason
    /// as ``engineStartTask``.
    var restartTask: Task<Void, Never>?

    /// The delayed rebuild after a live break-off with a running picture — a separate
    /// slot next to ``restartTask``, because it does something different (restart the engine,
    /// not jump through the server) and the two could otherwise cancel each other.
    ///
    /// **Until 2026-09-27 this task was attached to nobody** (remuxer check,
    /// finding 7): if the viewer closed the view or switched the channel in the
    /// 400 ms during which ``noteEngineFailure()`` waits for the mark from the error log,
    /// it reconnected anyway — and occupied the only provider connection
    /// for a screen nobody was looking at any more.
    var dropRestartTask: Task<Void, Never>?

    /// The viewer's choice, as the server's track numbers. `nil` means: their
    /// default choice (audio) or none (subtitles).
    ///
    /// Starts with what the decision has already chosen — for example the
    /// preferred audio track from the settings. Without this carry-over the
    /// menu showed the default track while the desired one is long audible.
    ///
    /// **`@ObservationIgnored`, because `lazy` and `@Observable` exclude each other**
    /// (AP32, 2026-09-11): the macro turns stored properties into computed ones,
    /// and a computed one cannot be `lazy`. Nothing needs to be observed here anyway
    /// — the choice lives in ``selectedAudioTrack`` and is drawn from there.
    @ObservationIgnored lazy var chosenAudioIndex: Int? = target.decision
        .audioStreamIndex
    @ObservationIgnored lazy var chosenSubtitleIndex: Int? = target.decision
        .subtitleStreamIndex

    /// Whether the language preferences have already been applied to the engine's tracks.
    ///
    /// Exactly once per target: VLC and the unchanged delivery report their
    /// tracks only after the start, and whoever chose again on every tick would
    /// immediately take away every switch the viewer made themselves.
    var didApplyLanguagePreference = false

    /// The lines of the selected subtitle track — fetched and drawn by the app itself.
    /// `nil` means: no subtitle chosen or still on its way.
    ///
    /// **Why the app draws:** the server path via the main list is proven broken on
    /// Dolby Vision (see ``WebVTTSubtitles``). A side effect with
    /// weight: a subtitle switch needs **no rebuild** any more — playback
    /// keeps running undisturbed.
    var subtitleCues: [SubtitleCue]?

    /// The subtitle tracks of the running portal stream, and which target they belong to.
    ///
    /// **Remembered and not fetched per tick**: they live in an actor, this place
    /// runs five times a second, and within one target they do not change.
    var portalSubtitles: [PortalSubtitle] = []
    var portalSubtitleTarget: String?

    /// The line for the current position — tracked by the tick, drawn by the
    /// playback view.
    public internal(set) var subtitleLine: String?

    /// The line above the picture — signs and captions from ASS tracks.
    public internal(set) var subtitleTopLine: String?

    /// The images of a PGS track, decoded by ``PGSSubtitles``.
    var subtitleImageCues: [SubtitleImageCue]?

    /// The subtitle images currently showing, together with the finished drawing image —
    /// tracked by the tick, laid on by the playback view.
    public internal(set) var subtitleBitmaps: [SubtitleBitmap] = []

    /// Finished drawing images per window start: an image is built the first
    /// time it shows and reused afterwards — the tick asks every half
    /// second, and the RGBA conversion should not run every time.
    var bitmapCache: [TimeInterval: CGImage] = [:]

    /// Whether the selected track is still on its way.
    ///
    /// On the very first access per file the server first pulls the track out of the
    /// container — measured on our own catalog 5.5 to 9.5 **minutes** for
    /// large films. Without this flag a running preparation looks exactly
    /// like a broken track, and that is exactly how it was reported ("all other
    /// subtitles do not work").
    public internal(set) var isPreparingSubtitle = false

    /// Whether the selected track could not be fetched for good — the display says so
    /// then, instead of showing "being prepared" forever.
    public internal(set) var subtitleUnavailable = false

    /// Counts the subtitle fetches so only the last one counts: whoever switches quickly
    /// through the tracks would otherwise get the lines of an earlier choice
    /// laid over the picture.
    var subtitleFetchGeneration = 0

    /// For which target the server tracks were last computed.
    var serverTracksTarget: String?

    /// Which press of the running chain was just counted.
    var scrubPressCount = 0
    var lastScrub = Date.distantPast
    /// Which direction the running chain goes in. A change of direction resets
    /// it — whoever reverses wants to aim precisely and not keep racing on.
    var scrubDirection = 0
}
