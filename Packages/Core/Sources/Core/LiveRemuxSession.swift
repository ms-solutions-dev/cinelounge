import CoreMedia
import Foundation

/// Taps a running channel and turns it into an address for the player.
///
/// **This is the bracket around everything.** Outside lies an address pointing to a raw
/// transport stream — the `.ts` ending that an Xtream provider offers next to the
/// playlist. Coming in is an address to the own server,
/// which an `AVURLAsset` accepts. In between: load, read, remux,
/// deliver, and that without end.
///
/// ## What has behaviour of its own here
///
/// **The connection drops, and that is not an exception.** A channel runs for
/// hours; providers disconnect in between, Wi-Fi stutters, the server restarts.
/// A drop here does not end playback but leads to a
/// new fetch — the remuxer keeps running, the buffer stays, and the
/// time computation survives the break because ``StreamClock`` flattens it.
///
/// **Waiting is for buffer, not for time.** The player gets the address
/// only when enough segments are there — a playlist that
/// points to content that does not exist yet leads to an abort without a reason.
public final class LiveRemuxSession: NSObject, URLSessionDataDelegate, @unchecked Sendable {

    /// How many segments must be present before the player may begin.
    ///
    /// **Three**, and that is not a picked number: With a running stream a player does not begin at the newest segment, but three
    /// segment lengths before it — that much buffer it needs to
    /// bridge a dropout. If less is there, it waits silently.
    ///
    /// **Since 2026-09-03 the segments are half a second long** — the own
    /// writer (``CMAFWriter``) no longer cuts at the keyframe. Three
    /// segments are thus one and a half seconds of broadcast instead of twenty, and the
    /// provider burst delivers them in under a second. The broadcast-time rule
    /// below has practically never applied since; it remains as a safety net for
    /// a stream whose segments turn out long for some reason.
    public static let defaultReadySegments = 2

    /// From how much broadcast in the buffer it may start with fewer segments.
    ///
    /// **The adjusting screw was the wrong one, and the capture showed it**
    /// (2026-08-11, Telve 1 HEVC run through the own remuxer): How long a
    /// segment becomes is determined not by ``FragmentWriter/segmentDuration`` but by
    /// the **channel** — cutting happens at the keyframe. On this channel
    /// there is one every five seconds, so the segments are five seconds long,
    /// whatever we set. "Three segments" thus meant fifteen seconds of
    /// buffer; measured on the device were 7.2 s and 8.1 s until the picture, while
    /// VLC needs 376–678 ms.
    ///
    /// That is why the **broadcast time** now counts and not the number: Eight seconds
    /// are two dropouts wide and on this channel reached after two segments.
    /// Where the segments are short, the count still applies — both rules
    /// side by side, and whichever finishes first starts. It can therefore never become slower than
    /// before.
    ///
    /// **From eight to seven seconds** (on-device finding 2026-08-23: opening live broadcast
    /// DE Sport Digital Fussball HQ takes forever). Re-measured on
    /// 14 startups of the same run: median 1763 ms — this channel **11 939 ms**,
    /// so almost seven times as much. The cause hides in 0.4 seconds: Its segments
    /// are 3.8 s long, two of them 7.6 s — just under eight. So a
    /// **third** one had to come, and because this provider delivers exactly this channel in
    /// **real time** (measured: 35 s of broadcast in 35 s of clock time, while
    /// other channels in the same run deliver 28 s of broadcast in 5 s), that cost
    /// one full further keyframe period.
    ///
    /// Seven seconds are not a computing game but backed up: Eight channels
    /// regularly start today with exactly two segments of 8.0 s (Telve 1 UHD,
    /// Ayaz UHD, MERCAN TV UHD, KANAL DERE UHD, LODOS TV UHD, KANAL KAYA UHD, NOKTA TV UHD,
    /// BEYAZ TV UHD) and report throughout "0 dropouts, played through". 7.6 s instead of
    /// 8.0 s is the same operation.
    ///
    /// **From seven to three — and "or" becomes "and"** (probe on the Mac,
    /// 2026-09-04, evening): Since the segments are half a second long, the
    /// segment rule let the player start with two segments, i.e. **one second** of lead
    /// before the live edge. With a channel that delivers in real time
    /// (TELE MOOS, SELA 1: no burst ahead), it ran into the edge — on the
    /// device "player at 0.9 s, loaded to 1.1 s, 3.5 s of buffer in the remuxer":
    /// the remuxer was not starving, the player fetched the playlist at the
    /// pace of the target duration and saw the new segments too late. AVPlayer itself
    /// warns about it ("restarting 1.24 s from end of live playlist … stall
    /// danger"), and the HLS specification demands three target durations of distance.
    /// Measured (PCR-clocked probe, three runs each of TELE MOOS and SELA 1): with
    /// 1 s of lead a stall of 3 s in every second run, with 3 s of
    /// lead six of six runs without a stall and without a jump.
    ///
    /// The channels with burst (the Turkish ones: 28 s of broadcast in 5 s) notice
    /// nothing of this — three seconds of broadcast are there after the first
    /// grab. Anyone delivering in real time pays two seconds of startup — and
    /// gets a channel that does not stall every twenty seconds in return.
    public static let defaultReadySeconds: TimeInterval = 3

    /// How long the first buffer is waited for before giving up.
    public static let defaultReadyTimeout: TimeInterval = 20

    /// From how much broadcast the **direct renderer** may start.
    ///
    /// **One second, and that is the rule "start lean, then fatten up".**
    /// VLC begins with one second of network buffer, ExoPlayer on live with half
    /// to a full one; both grow afterwards. The provider pushes at the start
    /// at three to four times real time — the buffer that the HLS path demanded BEFORE the
    /// first picture arises here DURING the first seconds of picture.
    /// The renderer stops the engine itself when it runs out of broadcast;
    /// this second is only the startup aid.
    public static let defaultRendererReadySeconds: TimeInterval = 1

    /// How long to wait after a drop before fetching again —
    /// the **first** attempt; each further one doubles up to the upper limit.
    ///
    /// Half a second as the start: A single dropout should not become a
    /// still frame for the viewer. **But never stubbornly at a half-second rhythm**
    /// (on-device finding 2026-08-15, third evening test): A panel that rejects connections
    /// immediately got ~120 attempts per minute that way — per session, multiplied when
    /// zapping. Xtream panels answer exactly that with an
    /// IP throttle, and then EVERYTHING is dead, even what was just running. Whoever is
    /// rejected must get quieter, not louder.
    static let reconnectDelay: TimeInterval = 0.5

    /// The upper limit of the backoff. Ten seconds is a lot for a running
    /// channel — but less than a provider block that holds for minutes.
    static let reconnectDelayCeiling: TimeInterval = 10

    /// How long a connection may stay silent before it counts as dead.
    ///
    /// **Eight seconds, and the number hangs on the buffer** (on-device finding 2026-08-15,
    /// fifth evening test): A reconnection got through, but never delivered
    /// a byte — the provider sometimes accepts a surplus connection
    /// and simply lets it starve. The old limit of thirty seconds
    /// noticed that only when the buffer (~10–20 s) had long since run dry
    /// and playback had dropped. Eight seconds are far above
    /// any burst pause (under one second) and below the smallest
    /// buffer — the line dies before the picture does, and the backoff
    /// takes over.
    ///
    /// **From eight to six, because the start buffer has dropped** (2026-08-23): The
    /// rule is "the line dies before the picture does" — it therefore hangs
    /// on ``defaultReadySeconds``, and when the value there went to seven,
    /// the eight suddenly was the longer of the two. The test suite caught it
    /// before a device did.
    ///
    /// **From six to three** (2026-09-04, evening), for the same reason: The
    /// start buffer went to three seconds (``defaultReadySeconds``),
    /// and three seconds of silence are with a real-time channel exactly the
    /// moment in which the picture would be standing. The providers' burst pauses are
    /// under one second, the distance remains.
    static let silenceTimeout: TimeInterval = 3

    /// The same limit, **as long as no buffer stands yet at all**.
    ///
    /// **At startup there is no buffer to protect** (on-device finding 2026-08-23):
    /// The eight seconds above aim at running operation — the line
    /// should die before the buffer runs dry. Before the first segment there is
    /// nothing that could run dry; there patience is only waiting time.
    ///
    /// Measured in the same run: "TR: Ayaz HQ" needed **9678 ms** to open,
    /// of which about eight seconds were pure waiting for a connection that was
    /// accepted and then starved (`-1001` at +9 s). After that came
    /// 20.2 s of buffer in about a second — the reconnection was there immediately,
    /// only the giving up had taken long.
    ///
    /// Three seconds still lie far above any burst pause (under one
    /// second).
    ///
    /// **From three to two** (2026-09-04, evening), in step with
    /// ``silenceTimeout``: At startup there is no buffer to protect, so
    /// the limit may be shorter there than in operation — and the startup
    /// itself lies under one second at the median.
    static let startupSilenceTimeout: TimeInterval = 2

    /// How long a connection may stay silent **at most**, however much lead there is.
    static let silenceUpperLimit: TimeInterval = 10

    /// How long the line may stay silent, measured against the lead before real time.
    ///
    /// **Three seconds were the same for every case, and that was the mistake** (AP64,
    /// F-018, 2026-10-03): seven drops in 35 minutes, all `-1001` after three
    /// seconds of silence — with 20–40 s of buffer. The probe on the same channel measured
    /// delivery pauses of up to **3.0 s**, always at a good 21 s of lead: The edge delivers ahead
    /// and then stops briefly. Every drop cost a seam with 18–23 s of overlap.
    ///
    /// The rule from ``silenceTimeout`` still applies — the line dies before the picture
    /// does. Only the buffer it hangs on is now the measured one: what lay ahead of real time
    /// at the last byte, minus three seconds of distance. Without lead it stays
    /// at three seconds, and it never becomes more than ``silenceUpperLimit``.
    ///
    /// - Parameter vorsprung: Broadcast minus running time at the last byte, in seconds;
    ///   `nil` if there is nothing to measure yet.
    static func silenceDeadline(lead: Double?) -> TimeInterval {
        guard let lead else { return silenceTimeout }
        return min(silenceUpperLimit, max(silenceTimeout, lead - 3))
    }

    public enum SessionFailure: Error, Equatable {
        case noContentInTime
        /// The provider answered the fetch with an error head — not a
        /// drop, but a refusal (on-device finding 2026-08-16, "KOPRU HABER HD":
        /// `403` on ALL paths, proven by a control test — the channel was
        /// blocked on the provider side, and the app ran anyway into the
        /// buffer timeout and the pointless fallback).
        case refused(status: Int)
    }

    private let source: URL
    /// How many segments of this session suffice. See ``defaultReadySegments``.
    private let readySegments: Int
    /// Siehe ``defaultReadySeconds``.
    private let readySeconds: TimeInterval
    private let readyTimeout: TimeInterval
    /// The segment store of the HLS path — `nil` in renderer operation.
    private let store: SegmentStore?
    private let remuxer: TransportRemuxer
    /// Server and playlist of the HLS path — `nil` in renderer operation.
    private let stream: RemuxStream?
    /// The buffer of the direct renderer — `nil` in HLS operation.
    ///
    /// **Two outputs, one session** (2026-09-03): Everything this class has learned about
    /// the provider — the identifier, the bursts, the backoff, the
    /// refusals, the zombie teardown — applies regardless of what comes out at the back of the
    /// remuxer. A second fetcher would have been a second collection of the same
    /// lessons, only without the checks.
    private let samples: SampleQueue?
    /// The name in the log lines — with the channel, if one is known.
    /// The rationale is at the field of the same name in ``SegmentStore``.
    private let tag: String

    private let lock = NSLock()
    private var task: URLSessionDataTask?
    /// When a byte last came, and how much lead there was — for the silence watch.
    private var lastReception: Date?
    private var leadAtReception: Double?
    /// When the early-start rule would first have applied — see ``isEarlyStartPossible(downloads:lead:)``.
    private var earlyStartFrom: (time: Date, downloads: Double, lead: Double)?
    /// The silence watch of the running connection — see ``silenceDeadline(lead:)``.
    private var silenceWatch: Task<Void, Never>?
    private var isStopped = false
    private var reconnects = 0
    private var received = 0
    /// What the running connection brought, and since when — for the drop line.
    private var burstBytes = 0
    private var burstSince: Date?
    /// See ``ReportBeat`` — in burst operation it drops every 10–20 s.
    private var dropoutPulse = ReportBeat()
    /// When the first byte came — the zero point for the delivery verdict.
    private var firstDataAt: Date?
    /// The marks of this startup — see ``StartupMarks``.
    private var _marks = StartupMarks()
    /// Whether the running grab went past the panel to the remembered edge.
    private var warmEdgeInUse = false
    /// Whether the next abort should immediately grab anew cold (via the panel).
    private var coldRetryPending = false
    /// The current wait time of the backoff — grows with each failure, falls back to
    /// the initial value as soon as data flows again.
    private var currentReconnectDelay: TimeInterval = LiveRemuxSession.reconnectDelay
    /// The last error head of the remote end — `nil` as soon as data flows
    /// again. Distinguishes the refusal from the drop, see
    /// ``SessionFailure/refused(status:)``.
    private var lastRefusal: Int?

    /// Synchronous behind the lock — `NSLock` must not be taken
    /// directly in async contexts.
    private func noteRefusal(_ status: Int) {
        lock.lock()
        defer { lock.unlock() }
        lastRefusal = status
    }

    /// Whether this refusal is to be reported — and how often the same one has already been swallowed.
    ///
    /// **The finding** (AP1, noise table): `answer 407` stands 18 times among
    /// 30 error lines of the recording of 2026-08-23 — the same refusal from the same
    /// remote end, once per reconnection. Four SOLA channels thereby fill
    /// half of all defects and hide the other twelve.
    ///
    /// **An earlier attempt failed here** and the lesson from it stands
    /// in the design: It wanted to report the repetitions after the fact in the tally
    /// line — which, however, stands behind `bytes > 0`, and with a refusal
    /// no byte ever flows. None of the four channels had a tally
    /// line in the log. Counting is therefore done here, and output happens at a
    /// place that also reaches the refusal: at the halt of the session
    /// (``stop()``), without any condition above it.
    private func admitRefusal(_ status: Int, from host: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        // A different status or a different remote end is a new
        // piece of information; the gate then resets its counter itself.
        return refusalGate.admit("\(status)@\(host)")
    }

    /// The gate over the refusals — it counts what it swallows, and ``stop()``
    /// reads the number out.
    private var refusalGate = CountingGate<String>()

    private var currentRefusal: Int? {
        lock.lock()
        defer { lock.unlock() }
        return lastRefusal
    }

    /// How often the connection was rebuilt — for diagnostics.
    public var reconnectCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return reconnects
    }

    /// The wait time of the next reconnection — for diagnostics and checks.
    public var reconnectBackoff: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return currentReconnectDelay
    }

    /// How many bytes the fetch has delivered in total — for diagnostics:
    /// Growing bytes with a standing segment count mean "the cutter is stuck,
    /// not the connection" (the difference on which 2026-08-15 hung).
    public var receivedBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return received
    }

    /// When how much last arrived — for the congestion report.
    private var receptionTrail: [(Date, Int)] = []

    /// **The congestion report** (requirement 2026-09-04: build in more diagnostic
    /// lines): What the remuxer has at the moment when the player
    /// stalls or drops — buffer, last reception, reception rate of the
    /// last five seconds, reconnections, the pairing of the fields.
    /// From it one can read whether the provider, the remuxer or the player
    /// is the cause.
    public var state: String {
        lock.lock()
        let now = Date()
        let last = receptionTrail.last?.0
        let lastFiveSeconds = receptionTrail.filter { now.timeIntervalSince($0.0) <= 5 }.reduce(0) {
            $0 + $1.1
        }
        let reconnectCount = reconnects
        lock.unlock()
        var split: [String] = []
        if let store {
            split.append("downloads \(store.count) pieces (\(String(format: "%.1f", store.seconds)) s)")
        }
        if let last {
            split.append("letzter Empfang vor \(Int(now.timeIntervalSince(last) * 1000)) ms")
        } else {
            split.append("noch kein Empfang")
        }
        split.append(
            String(
                format: "letzte 5 s: %d KB (%.1f Mbit/s)", lastFiveSeconds >> 10,
                Double(lastFiveSeconds) * 8 / 5 / 1_000_000))
        if reconnectCount > 0 { split.append("\(reconnectCount) Wiederverbindungen") }
        let pairing = remuxer.pairingTally
        if pairing.pairs > 0 || pairing.orphans > 0 {
            split.append(
                "Paarung \(pairing.pairs) Paare, \(pairing.orphans) Waisen, \(pairing.wholePictures) ganze Bilder"
            )
        }
        split.append(remuxer.timestampReport)
        return split.joined(separator: ", ")
    }

    /// What the stream contains according to its tables.
    public var inventory: TransportStream.Inventory { remuxer.inventory }

    /// The writer's error, if it has one — see
    /// ``TransportRemuxer/writerFailure``.
    public var writerFailure: Error? { remuxer.writerFailure }

    /// The measured frame cadence of the channel — see ``TransportRemuxer/frameRate``.
    ///
    /// Stands once the buffer suffices for the start: By then several
    /// seconds of broadcast have run through the remuxer, and with every
    /// channel that is over a hundred pictures.
    public var frameRate: Double? { remuxer.frameRate }

    /// How often the audio clock was re-anchored — see ``TransportRemuxer/audioReanchors``.
    public var audioReanchors: Int { remuxer.audioReanchors }

    /// The identifier with which the stream is fetched.
    ///
    /// **The provider filters by it** (proven 2026-08-15, fourth evening test,
    /// by control test: the same address answers with the VLC identifier with the
    /// 302 redirect to the token edge — with an unknown identifier the
    /// connection drops without a word, HTTP 000). The CFNetwork default identifier was
    /// sometimes tolerated, sometimes rejected — exactly the pattern "starts briefly, dies
    /// then": first connection through, reconnection refused at the edge. The
    /// VLC identifier is the one under which this provider saw the app for years;
    /// after the VLC teardown it remains only a string.
    /// Public, because the partial file fetches (``HTTPByteRangeSource``)
    /// need the same identifier: The provider's filter applies to films
    /// just as it does to channels.
    public static let userAgent = "VLC/3.0.18 LibVLC/3.0.18"

    /// The session for the HLS path: segments, server, playlist.
    ///
    /// - Parameter zeitversatz: How large the disk ring may become — **per device**
    ///   (AP58 G1): both at least five minutes at high bitrate; the number stands in
    ///   `Flows.TimeShift`.
    public convenience init(
        source: URL,
        label: String? = nil,
        readySegments: Int = LiveRemuxSession.defaultReadySegments,
        readySeconds: TimeInterval = LiveRemuxSession.defaultReadySeconds,
        readyTimeout: TimeInterval = LiveRemuxSession.defaultReadyTimeout,
        timeOffset: Int64 = TimeShiftRing.defaultCapacity
    ) throws {
        let store = SegmentStore(label: label)
        // **Time-shifted TV** (AP9): What falls out of the window goes
        // to disk, and the player can pause and go back.
        store.enableTimeShift(TimeShiftRing(capacity: timeOffset))
        // **Ohne Teile, wo AVPlayer sie abgelehnt hat** — siehe ``LowLatencyMemory``.
        if LowLatencyMemory.shared.isRejected(source) {
            store.lowLatency = false
            Diagnostics.playbackStep(
                "\(label ?? "Remuxer"): playlist without part promise — AVPlayer rejected the part path "
                    + "for this channel (-15410)", since: nil)
        }
        try self.init(
            source: source, label: label, store: store,
            stream: RemuxStream(store: store, isLive: true), samples: nil,
            // **The own writer** (2026-09-03): Segments of half a
            // second instead of a whole group of pictures — see ``CMAFWriter``.
            remuxer: TransportRemuxer(store: store, writer: .own),
            readySegments: readySegments, readySeconds: readySeconds,
            readyTimeout: readyTimeout)
    }

    /// The session for the **direct renderer**: The packets go into the buffer,
    /// an engine picks them up there. No server, no playlist, no segments.
    public convenience init(
        source: URL,
        label: String? = nil,
        samples: SampleQueue,
        readySeconds: TimeInterval = LiveRemuxSession.defaultRendererReadySeconds,
        readyTimeout: TimeInterval = LiveRemuxSession.defaultReadyTimeout
    ) throws {
        try self.init(
            source: source, label: label, store: nil, stream: nil, samples: samples,
            remuxer: TransportRemuxer(sink: samples),
            readySegments: Self.defaultReadySegments, readySeconds: readySeconds,
            readyTimeout: readyTimeout)
    }

    private init(
        source: URL,
        label: String?,
        store: SegmentStore?,
        stream: RemuxStream?,
        samples: SampleQueue?,
        remuxer: TransportRemuxer,
        readySegments: Int,
        readySeconds: TimeInterval,
        readyTimeout: TimeInterval
    ) throws {
        self.store = store
        self.stream = stream
        self.samples = samples
        self.remuxer = remuxer
        tag = label.map { "Umpacker „\($0)“" } ?? "Umpacker"
        self.source = source
        self.readySegments = readySegments
        self.readySeconds = readySeconds
        self.readyTimeout = readyTimeout
        super.init()
    }

    /// **One `URLSession` for all channels** (F-004, 2026-09-03) — so that the
    /// connection to the panel stays warm between two channel switches.
    ///
    /// Before, every session built its own `URLSession` and tore it down at the halt;
    /// every channel switch began with a new handshake with the
    /// panel, and this provider's panel already needs about 0.8 s
    /// until the redirect. The fetch now gets its delegate **per
    /// task** (`task.delegate`, tvOS 15+); the session stays.
    ///
    /// The provider's identifier and the cookie ban stand here because they
    /// apply to every channel — the rationale at ``userAgent`` and in the
    /// cookie comment below.
    ///
    /// **No cookies.** The panel redirects every fetch with a
    /// one-time token to an edge; with a cookie session it binds the
    /// token to the session and on reconnecting hands out an already
    /// burned one — the edge then delivers nothing. Without cookies
    /// every fetch is new to the panel, and the token fresh (control test
    /// 2026-08-15: three consecutive fetches without cookie handling ran
    /// cleanly, the same sequence with a managed session stayed empty).
    private static let sharedSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpAdditionalHeaders = ["User-Agent": userAgent]
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        // A thread of its own for delivery: Remuxing must not hold up the
        // UI, and the chunks arrive densely.
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return URLSession(configuration: configuration, delegate: nil, delegateQueue: queue)
    }()

    /// The address for the `AVURLAsset` — usable only after ``start()``.
    ///
    /// In renderer operation there is no local address; then the
    /// source itself stands here, and the engine gets the buffer instead of an address.
    public var assetURL: URL { stream?.assetURL ?? source }

    /// Whether this session works for the direct renderer.
    public var feedsRenderer: Bool { samples != nil }

    /// Starts fetch and server and returns as soon as enough buffer is there.
    ///
    /// **If it throws, it has already torn itself down** — and that is the
    /// zombie lock of 2026-08-15: The caller drops a thrown session,
    /// but the `URLSession` holds on to its delegate. Without the
    /// self-teardown the session would live on forever and reconnect at the
    /// pace of its backoff — the diagnostics showed three such counters
    /// side by side, and the zombies stole from the running channel the one
    /// connection slot of the provider. Both gates are covered: the
    /// buffer failure and the cancellation of the waiting caller
    /// (`CancellationError` from sleeping).
    @discardableResult
    public func start() async throws -> URL {
        try await startUp()
        return assetURL
    }

    /// Starts fetch (and server, where there is one) and returns as soon as
    /// enough buffer is there — the same waiting logic for both outputs.
    public func startUp() async throws {
        do {
            try await stream?.start()
            connect()

            let deadline = Date().addingTimeInterval(readyTimeout)
            waiting: while true {
                if isFinished { break }
                switch Self.waitState(
                    ready: hasEnoughToStart, rejection: currentRefusal, now: Date(),
                    deadline: deadline)
                {
                case .next:
                    rememberEarlyStart()
                    try await Task.sleep(for: .milliseconds(25))
                case .ready, .expired, .cancelled: break waiting
                }
            }
            guard downloadsReady else {
                // If nothing came during the whole wait time AND the last answer
                // was a refusal, then the error is named so: The provider WILL NOT
                // deliver this channel, and every further attempt — even
                // a fallback via another engine — runs against the same
                // refusal.
                if let refusal = currentRefusal {
                    throw SessionFailure.refused(status: refusal)
                }
                throw SessionFailure.noContentInTime
            }
        } catch {
            stop()
            throw error
        }
        lock.withLock { _marks.downloadsReady = Date() }
        Diagnostics.verbose(downloadsLine)
        offerAudioTracks()
    }

    /// Passes the audio tracks of the program table to the buffer — for the menu
    /// of the renderer. On the HLS path there is nothing to offer: There the
    /// switch is a restart, and the UI does not offer it.
    /// The audio tracks of the program table — for the menu, on both paths.
    public var audioOptions: [SampleQueue.AudioOption] {
        inventory.audioStreams.map {
            SampleQueue.AudioOption(pid: $0.pid, codec: $0.kind.name, language: $0.language)
        }
    }

    /// The identifier of the audio stream that is currently passing through.
    public var selectedAudioPID: UInt16? { remuxer.selectedAudioPID ?? audioOptions.first?.pid }

    /// Selects an audio track — with the buffer a change in the stream, with the
    /// segment writer a new section in the playlist (AP7 · 4).
    public func selectAudio(pid: UInt16) {
        remuxer.selectAudio(pid: pid)
        samples?.selectedAudioPID = pid
    }

    private func offerAudioTracks() {
        guard let samples else { return }
        let options = audioOptions
        samples.audioOptions = options
        samples.selectedAudioPID = remuxer.selectedAudioPID ?? options.first?.pid
        samples.onSelectAudio = { [weak self] pid in
            guard let self else { return }
            self.remuxer.selectAudio(pid: pid)
            self.samples?.selectedAudioPID = pid
        }
        if options.count > 1 {
            Diagnostics.playbackStep(
                "\(tag): \(options.count) Tonspuren — "
                    + options.map { "\($0.language ?? "?")/\($0.codec)" }.joined(separator: ", "),
                since: nil)
        }
    }

    /// Whether anything playable is there yet — header and a segment, or
    /// a first picture in the buffer.
    private var downloadsReady: Bool {
        if let samples { return samples.isReady }
        return store?.isReady ?? false
    }

    /// Whether something is there yet — for the fetch deadline, see ``connect()``.
    private var hasDownloads: Bool {
        if let samples { return samples.receivedVideo > 0 }
        return (store?.count ?? 0) > 0
    }

    /// The line after startup: what stands, in the language of the output.
    private var downloadsLine: String {
        if let samples {
            return "\(tag): \(String(format: "%.1f", samples.bufferedSeconds)) s buffered "
                + "in the renderer (\(samples.receivedVideo) pictures, \(samples.receivedAudio) audio packets)"
        }
        guard let store else { return "\(tag): no downloads" }
        let earlyStart = lock.withLock { earlyStartFrom }
        let measurement: String
        if let earlyStart {
            measurement = String(
                format: " — early start would have gone %.1f s sooner (%.1f s buffered, %.1f s lead)",
                Date().timeIntervalSince(earlyStart.time), earlyStart.downloads, earlyStart.lead)
        } else {
            measurement = " — early-start rule did not apply"
        }
        return "\(tag): \(store.count) pieces, \(String(format: "%.1f", store.seconds)) s buffered"
            + measurement
    }

    /// From how much buffer the early-start rule applies, and from how much measured lead.
    ///
    /// **Measure first, then build** (AP73, 2026-10-11). Three seconds of start buffer
    /// (``defaultReadySeconds``) are flat: A channel that delivers faster than it
    /// plays has, after one and a half seconds of buffer, a lead that no longer
    /// shrinks — for it the viewer waits one and a half seconds for nothing. The rule is
    /// only **computed** here, not applied: The buffer line states how much earlier it
    /// would have gone. It is switched over after the on-device test with the PCR probe, not before.
    static let earlyStartSeconds: TimeInterval = 1.5
    static let earlyStartLead: Double = 1.0

    /// Whether the early-start rule would apply at this buffer and lead.
    static func isEarlyStartPossible(downloads: Double, lead: Double?) -> Bool {
        guard let lead else { return false }
        return downloads >= earlyStartSeconds && lead >= earlyStartLead
    }

    /// Records when the early-start rule would first have applied — only on the
    /// path via the buffer; the direct renderer starts after one second anyway.
    private func rememberEarlyStart() {
        guard samples == nil, let store else { return }
        let lead = lock.withLock { leadAtReception }
        let downloads = store.seconds
        guard Self.isEarlyStartPossible(downloads: downloads, lead: lead) else { return }
        lock.withLock {
            if earlyStartFrom == nil { earlyStartFrom = (Date(), downloads, lead ?? 0) }
        }
    }

    // MARK: - Warten, und wann es sinnlos ist

    /// Whether a status is information about the **authorisation**.
    ///
    /// 401, 402, 403 and 407 say: "You may not." That does not change in the
    /// next twenty seconds, and every further request in that time
    /// goes to the same account — with a provider that has **one**
    /// connection slot, to that of the channel the viewer is just
    /// trying to watch.
    ///
    /// Other error statuses are **not** a refusal in this sense: A 500 or
    /// a redirect chain may carry on the next attempt, and that is what the
    /// deadline is for.
    public static func isPermissionDenial(_ status: Int) -> Bool {
        ErrorSummary.isPermissionDenial(status)
    }

    /// How the wait for the first buffer stands.
    enum WaitState: Equatable {
        case next
        case ready
        case cancelled(Int)
        case expired
    }

    /// **The finding** (AP3 · V2, expert review 2026-08-24): `grep "verweigert
    /// diesen Sender"` over the whole diagnostics yields **0 hits** — with 18
    /// logged refusals. The message hangs behind the deadline of twenty
    /// seconds, and after eighteen one switches on. The viewer sees a
    /// black picture and never learns that the provider turned them away.
    ///
    /// The deadline is there for a **slow** delivery. A refusal is
    /// not a slow delivery.
    static func waitState(ready: Bool, rejection: Int?, now: Date, deadline: Date) -> WaitState {
        if ready { return .ready }
        if let rejection, isPermissionDenial(rejection) { return .cancelled(rejection) }
        return now < deadline ? .next : .expired
    }

    /// Whether enough is in the buffer — by count **or** by broadcast time.
    ///
    /// The rationale for the "or" is at ``defaultReadySeconds``.
    var hasEnoughToStart: Bool {
        if let samples {
            return Self.rendererHasEnough(seconds: samples.bufferedSeconds, wanted: readySeconds)
        }
        guard let store else { return false }
        return Self.hasEnough(
            pieces: store.count, seconds: store.seconds,
            wantedPieces: readySegments, wantedSeconds: readySeconds)
    }

    /// The same question for the direct renderer: **only** the broadcast time counts.
    ///
    /// No segment rule, because there are no segments — and no lower bound of
    /// two, because that one stood there against starving at the segment end. A
    /// renderer does not starve at a segment end; it stops when nothing is left,
    /// and starts again when something is there again.
    static func rendererHasEnough(seconds: Double, wanted: TimeInterval) -> Bool {
        seconds >= wanted
    }

    /// The same question as pure computation — so that it can be checked without a server.
    ///
    /// **Whoever finishes first starts — but never with a single
    /// segment** (on-device finding 2026-08-15, seventh evening test): A UHD channel puts
    /// a keyframe every ten seconds, its first segment met the
    /// broadcast-time rule alone — the player started with zero margin at the
    /// production edge and starved precisely at the segment end (dropout
    /// at 0:00, buffer level at 0:09, 0:29 — three times the same signature).
    /// The second segment follows from the startup burst within seconds and buys
    /// a whole keyframe period of lead.
    static func hasEnough(
        pieces: Int, seconds: Double, wantedPieces: Int, wantedSeconds: TimeInterval
    ) -> Bool {
        guard pieces >= 2 else { return false }
        return pieces >= wantedPieces && seconds >= wantedSeconds
    }

    public func stop() {
        lock.lock()
        let wasStopped = isStopped
        isStopped = true
        let running = task
        task = nil
        silenceWatch?.cancel()
        silenceWatch = nil
        let attempts = reconnects
        let bytes = received
        let swallowed = refusalGate.swallowed
        let rejection = lastRefusal
        let since = firstDataAt
        lock.unlock()

        // **The swallowed refusals are accounted for** (AP1, 2026-09-02), and
        // without any condition above it: With a refusal no byte ever flows,
        // and the tally line below would never see this session. Without this line
        // the swallowing would be an assertion without evidence.
        if !wasStopped, swallowed > 0 {
            Diagnostics.playbackProblem(
                "\(tag): response \(rejection.map(String.init) ?? "?") came another "
                    + "\(swallowed) times — same refusal, not reported again",
                since: nil)
        }

        // **The tally as a bundle** (requirement 2026-08-15: bundles instead of a
        // flood of lines): A session leaves ONE line with the totals —
        // what was cut, how often reconnected, how much received.
        // Only for sessions that ever saw anything; the zombie teardown
        // of a never-connected session needs no tombstone.
        if !wasStopped, bytes > 0 {
            Diagnostics.verbose(
                "\(tag) Bilanz: \(tallyHeader), "
                    + "\(attempts) Wiederverbindungen, "
                    + "\(String(format: "%.1f", Double(bytes) / 1_000_000)) MB empfangen")
            Diagnostics.playbackStep(remuxer.timestampReport, since: nil)
            // **The verdict on delivery** (F-009, 2026-09-03, "DE: Rendal 2
            // HQ"): 18 s of broadcast in 31 s, 17 Mbit/s — the viewer saw
            // "does not play smoothly, hangs", the trace showed 29 buffering messages,
            // and the number that explains both stood only as a raw value in the
            // tally. Now it stands there as a sentence, and as a defect.
            if let since, let media = mediaSeconds,
                let verdict = Self.deliveryVerdict(
                    broadcast: media, duration: Date().timeIntervalSince(since), bytes: bytes)
            {
                Diagnostics.playbackProblem("\(tag): \(verdict)", since: nil)
            }
        }

        // **The pairing tally belongs at the orderly halt, not at the
        // `deinit` of the remuxer.** There it falls when the `URLSession` has let go of its
        // delegate — that is, on an undetermined thread, in the middle of the
        // startup lines of the NEXT channel. It carries no channel name itself;
        // in the diagnostic run it stands here directly behind the tombstone, which
        // carries one, and can thereby be assigned. Without the verbose
        // switch the tombstone is silent — then only the timestamp remains,
        // and that is already half the finding.
        //
        // **Expressly not under `bytes > 0`:** The tally has its own,
        // sharper muting — it outputs nothing as long as nothing was
        // counted, so a progressive channel gets no line at all.
        // A second, coarser condition above it could only swallow.
        // Called twice it writes once.
        if !wasStopped { remuxer.reportPairingBalance() }

        // The fetch ends with the task; the session stays for the next
        // channel. The zombie lock still holds: A cancelled fetch no longer calls
        // its delegate, and ``isFinished`` catches the rest.
        running?.cancel()
        stream?.stop()
        store?.clearTimeShift()
    }

    deinit { stream?.stop() }

    /// How much broadcast this session has produced, in seconds —
    /// from the buffer or from the segments. `nil` if there is nothing to measure.
    private var mediaSeconds: Double? {
        if let samples {
            guard let first = samples.firstVideoTime, let latest = samples.latestVideoTime
            else { return nil }
            return (latest - first).seconds
        }
        return store?.producedTotalSeconds
    }

    /// From which running time the verdict is passed at all.
    /// The marks of this startup, for the player's startup line.
    public var marks: StartupMarks {
        lock.lock()
        defer { lock.unlock() }
        return _marks
    }

    static let verdictFrom: TimeInterval = 8
    /// Below which ratio of broadcast to running time the delivery counts as
    /// too slow. Not one: Startup costs, and a provider that delivers
    /// exactly in real time reaches 0.9 on short sessions.
    static let tooSlowBelow = 0.85

    /// The verdict as pure computation — checkable without a channel.
    ///
    /// - Returns: The sentence for the trace, or `nil` if the delivery
    ///   kept pace or the session was too short to know.
    static func deliveryVerdict(broadcast: Double, duration: TimeInterval, bytes: Int) -> String? {
        guard duration >= verdictFrom, broadcast > 0, broadcast / duration < tooSlowBelow else { return nil }
        let mbit = Double(bytes) * 8 / broadcast / 1_000_000
        return "Delivery too slow — \(Int(broadcast.rounded())) s of broadcast in "
            + "\(Int(duration.rounded())) s (\(String(format: "%.1f", mbit)) Mbit/s): "
            + "The channel needs more than the link delivers"
    }

    /// Whether the player can jump back in this session.
    public var hasTimeShift: Bool { store?.hasTimeShift ?? false }

    /// What this session has produced — segments or packets.
    private var tallyHeader: String {
        if let samples {
            return "\(samples.receivedVideo) Bilder, \(samples.receivedAudio) Tonpakete"
                + (samples.discarded > 0 ? ", \(samples.discarded) verworfen" : "")
        }
        guard let store else { return "nichts" }
        let ring =
            store.hasTimeShift
            ? String(
                format: ", time shift %.1f min (%d MB) on disk", store.timeShiftSeconds / 60,
                Int(store.timeShiftBytes / 1_000_000))
            : ""
        return "\(store.producedCount) pieces (\(String(format: "%.0f", store.producedTotalSeconds)) s)"
            + ring
    }

    /// Readable within the module, so that the zombie lock can be checked: A
    /// thrown session must be finished, otherwise it connects forever.
    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isStopped
    }

    // MARK: - Abruf

    private func connect() {
        lock.lock()
        defer { lock.unlock() }
        guard !isStopped else { return }

        // **Warm address, if there is one** (AP7 · 2): past the panel to the
        // remembered edge. If that one rejects or delivers nothing, it goes once
        // cold — see ``EdgeMemory``.
        let warm = EdgeMemory.shared.edge(for: source)
        warmEdgeInUse = warm != nil
        burstBytes = 0
        burstSince = nil
        if _marks.connected == nil {
            _marks.connected = Date()
            _marks.warmAddress = warm != nil
        }
        if let warm {
            Diagnostics.verbose("\(tag): warme Adresse \(warm.host ?? "?") — am Panel vorbei")
        }
        // **Every grab leaves a line — even the one that brings nothing** (2026-09-07,
        // Telve 1 HQ in the simulator): After "new attempt in 0.5 s" nothing
        // stood in the trace for two minutes, and whether the attempt ever started could not be
        // said. The line stands BEFORE the fetch, so that a grab that hangs without an answer and
        // without a deadline at least proves its start.
        Diagnostics.verbose(
            "\(tag): verbinde (Griff \(reconnects + 1), "
                + (warm != nil ? "warm" : "kalt")
                + (hasDownloads
                    ? ", Stille-Frist nach Vorsprung \(Int(Self.silenceTimeout))–\(Int(Self.silenceUpperLimit)) s)"
                    : ", Stille-Frist \(Int(Self.startupSilenceTimeout)) s)"))
        var request = URLRequest(url: warm ?? source)
        // **No cache.** A channel is never the same twice; a
        // remembered answer would here be a frozen picture.
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        // Without a time limit for the whole fetch: It is never meant to end. The
        // limit applies to the **silence** — why it sits so tight is at
        // ``silenceTimeout``. Before the first segment the shorter deadline applies:
        // There is no buffer to protect there, see
        // ``startupSilenceTimeout``.
        //
        // **With a buffer the session watches itself** (AP64): The fetch gets only the
        // upper limit, the actual deadline follows the lead — see
        // ``silenceDeadline(lead:)``. A fetch knows its deadline only at the start.
        request.timeoutInterval =
            hasDownloads ? Self.silenceUpperLimit : Self.startupSilenceTimeout

        let next = Self.sharedSession.dataTask(with: request)
        // The delegate per task — the session is shared, see ``sharedSession``.
        next.delegate = self
        task = next
        silenceWatch?.cancel()
        silenceWatch = hasDownloads ? watchSilence(about: next) : nil
        lastReception = Date()
        next.resume()
    }

    /// Aborts the connection as soon as it is silent longer than the lead allows.
    ///
    /// The abort goes the same way as every drop — ``urlSession(_:task:didCompleteWithError:)``
    /// reconnects. The line before it says why: which deadline, how much lead.
    private func watchSilence(about fetch: URLSessionDataTask) -> Task<Void, Never> {
        Task { [weak self, weak fetch] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, let fetch, !Task.isCancelled else { return }
                let (current, still, lead) = self.lock.withLock {
                    (
                        self.task === fetch,
                        self.lastReception.map { Date().timeIntervalSince($0) } ?? 0,
                        self.leadAtReception
                    )
                }
                guard current else { return }
                let deadline = Self.silenceDeadline(lead: lead)
                guard still > deadline else { continue }
                Diagnostics.playbackStep(
                    "\(self.tag): \(String(format: "%.1f", still)) s without a byte, silence deadline "
                        + "\(String(format: "%.1f", deadline)) s at "
                        + (lead.map { String(format: "%.1f s", $0) } ?? "unknown")
                        + " lead — reconnecting",
                    since: nil)
                fetch.cancel()
                return
            }
        }
    }

    /// The panel's redirect to its token edge — as a line in the trace.
    ///
    /// **So that "where does it stumble" has an answer** (requirement 2026-08-15): Whether
    /// a channel fails at the panel or at its edge could not be told from the trace
    /// — both looked like "connection dropped". Now
    /// the edge stands there by name, and a dead edge can be told from a dead
    /// panel without firing up the computer.
    public func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        if let edge = request.url {
            let port = edge.port.map { ":\($0)" } ?? ""
            Diagnostics.verbose("\(tag): redirect to \(edge.host ?? "?")\(port)")
            let cold = lock.withLock {
                if _marks.redirected == nil { _marks.redirected = Date() }
                return !warmEdgeInUse
            }
            // What is remembered is the address that the PANEL redirects to — not
            // a redirect behind a warm address.
            if cold { EdgeMemory.shared.remember(source: source, edge: edge) }
        }
        return request
    }

    /// The answer of the remote end — status and sender, before data flows.
    ///
    /// A status outside 2xx is here an **error and not a
    /// side note**: The provider sometimes accepts a surplus connection
    /// and answers it with an error head or not at all — the trace
    /// said nothing of this so far, and the session looked as if it were starving
    /// for no reason.
    ///
    /// **A refusal is aborted, not accepted** (remuxer check B10,
    /// 2026-09-27). There stood `.allow` afterwards: The error page in the body — nginx
    /// sends one with every 403 — arrived as data, immediately erased the refusal again and
    /// reset the backoff to half a second. Measured: eight grabs in four
    /// seconds against a panel that rejects every time, and in the end "no content" instead of
    /// "provider refuses". Exactly the sustained fire the backoff is built against —
    /// it leads into the IP throttle for all channels.
    public func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse
    ) async -> URLSession.ResponseDisposition {
        if let http = response as? HTTPURLResponse {
            let from = response.url?.host ?? "?"
            if (200..<300).contains(http.statusCode) {
                Diagnostics.verbose("\(tag): response \(http.statusCode) from \(from)")
            } else if beginColdRetry() {
                // **The warm address has expired** — no reason for a
                // refusal line: The panel gets its grab immediately.
                Diagnostics.verbose(
                    "\(tag): warm address rejected (\(http.statusCode)) — back to the panel")
                return .cancel
            } else {
                noteRefusal(http.statusCode)
                // **The same refusal says nothing new the second time.** It
                // is counted and accounted for when the session halts.
                if admitRefusal(http.statusCode, from: from) {
                    Diagnostics.playbackProblem(
                        "\(tag): response \(http.statusCode) from \(from) — the fetch stumbles here",
                        since: nil)
                }
                return .cancel
            }
        }
        return .allow
    }

    public func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data
    ) {
        guard !isFinished else { return }
        if let http = dataTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            return
        }
        // It flows again — the backoff starts from the beginning at the next drop,
        // and an earlier refusal is thereby refuted.
        lock.lock()
        currentReconnectDelay = Self.reconnectDelay
        if received == 0 {
            firstDataAt = Date()
            if _marks.firstData == nil { _marks.firstData = firstDataAt }
        }
        received += data.count
        burstBytes += data.count
        lastReception = Date()
        if burstSince == nil { burstSince = Date() }
        receptionTrail.append((Date(), data.count))
        if receptionTrail.count > 400 { receptionTrail.removeFirst(receptionTrail.count - 400) }
        lastRefusal = nil
        let firstByte = firstDataAt
        lock.unlock()
        remuxer.feed(data)
        // The lead at the last byte: the broadcast that is there, minus what
        // real time has consumed since the first byte.
        if let firstByte, let broadcast = mediaSeconds {
            let lead = broadcast - Date().timeIntervalSince(firstByte)
            lock.withLock { leadAtReception = lead }
        }
        if remuxer.hasFirstPicture {
            lock.lock()
            if _marks.firstKeyframe == nil { _marks.firstKeyframe = Date() }
            lock.unlock()
        }
    }

    /// Forgets the warm address and promises the immediate cold grab.
    /// `false` if no warm address was in play at all.
    private func beginColdRetry() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard warmEdgeInUse else { return false }
        warmEdgeInUse = false
        coldRetryPending = true
        // Not only forget, but remember the provider — see
        // ``EdgeMemory/rejectWarm(source:)``.
        EdgeMemory.shared.rejectWarm(source: source)
        return true
    }

    public func urlSession(
        _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
    ) {
        guard !isFinished else { return }

        // **The cold grab after an expired warm address** — immediately,
        // without backoff and without counting as a reconnection: It is the same
        // startup, only the detour via the panel that the warm address
        // wanted to save. An edge that accepts and then closes without a byte
        // also lands here.
        lock.lock()
        let muted = received == 0 && warmEdgeInUse
        lock.unlock()
        if muted { _ = beginColdRetry() }
        lock.lock()
        let cold = coldRetryPending
        coldRetryPending = false
        lock.unlock()
        if cold {
            connect()
            return
        }

        // **An end here is always a drop.** A channel does not end by
        // itself; when the fetch returns, something has intervened —
        // with an error or without, makes no difference for the handling.
        //
        // First, what is already there is rescued: The next fetch begins at
        // a new keyframe, and nobody picks up the segment that was begun afterwards.
        remuxer.flushSegment()

        lock.lock()
        reconnects += 1
        let attempt = reconnects
        let delay = currentReconnectDelay
        // Doubling for the next time — if data flows again,
        // ``urlSession(_:dataTask:didReceive:)`` resets the backoff.
        currentReconnectDelay = min(currentReconnectDelay * 2, Self.reconnectDelayCeiling)
        let burst =
            String(format: "Schub %.1f MB", Double(burstBytes) / 1_000_000)
            + (burstSince.map { String(format: " in %.1f s", Date().timeIntervalSince($0)) } ?? "")
        let intoLedger = dropoutPulse.tally()
        lock.unlock()

        // The counterpart to the buffer's production line: Without it the trace
        // could not show whether the cutter was stuck or the
        // connection (2026-08-15, "one segment, then never another").
        // **Into the ledger, not only with verbose recording** (AP64): The
        // jump back of 2026-10-02 stood nowhere because exactly this line was missing.
        let row =
            "\(tag): Verbindung riss ab (Nr. \(attempt), \(burst)"
            // **Not `String(describing:`** — with an `NSError` the dump is
            // the whole bag including `NSErrorFailingURLStringKey`, and
            // that carries with Xtream the access in the path. Four lines of the
            // report of 2026-08-23 came from exactly this place.
            + (error.map { ", \(Diagnostics.explain($0))" } ?? "")
            + ") — neuer Versuch in \(String(format: "%.1f", delay)) s"
        if intoLedger {
            Diagnostics.playbackStep(row, since: nil)
        } else {
            Diagnostics.verbose(row)
        }

        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !self.isFinished else { return }
            self.connect()
        }
    }
}

/// The counters for interpreting a stall — see ``RepackerPulse``.
///
/// Here and not next to the protocol, because buffer and renderer queue
/// are private and should stay so.
extension LiveRemuxSession: RepackerPulse {

    /// Segments in HLS operation, pictures with the direct renderer.
    public var produced: Int {
        if let samples { return samples.receivedVideo }
        return store?.producedCount ?? 0
    }

    /// The broadcast that this session has produced.
    public var produzierteSekunden: Double { mediaSeconds ?? 0 }

    /// The overlap at burst seams — see ``TransportRemuxer/seamBytes``.
    public var discardedBytes: Int { remuxer.seamBytes }
}
