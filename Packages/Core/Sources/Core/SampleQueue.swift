import CoreMedia
import Foundation

/// The buffer for the direct renderer: finished packets waiting for their engine.
///
/// **The counterpart to ``SegmentStore`` — only without pieces.** The piece store holds
/// fMP4 segments for a player that reads a playlist. This one holds the raw
/// `CMSampleBuffer`s as the remuxer builds them, for an engine that hands them directly to
/// the hardware. Between the first keyframe and the first drawn picture there is then
/// nothing left that would have to wait for a second keyframe.
///
/// **Two threads, one lock.** It is filled from the remuxer's network thread, drained from
/// the renderer's feed thread. Both touch only this class; nothing here calls outward while
/// the lock is held — with one exception, which explicitly comes after: the wake-up call to
/// the consumer.
///
/// **Capped**, for the same reason as ``TransportRemuxer/maximumWaiting``: An engine that
/// does not consume must not fill the memory. With a stalled consumer the oldest is
/// dropped — what would be played next is the newest.
public final class SampleQueue: SampleSink, @unchecked Sendable {

    /// How many pictures wait at most: a hundred seconds at 25 per second.
    public static let maximumFrames = 2500
    /// How many audio packets wait at most: about two and a half minutes of AAC.
    public static let maximumAudio = 8000
    /// How many bytes of picture wait at most — about 30 s of UHD, see ``BufferCap``.
    public static let maximumFrameBytes = 64 << 20
    /// How many bytes of audio wait at most.
    public static let maximumAudioBytes = 16 << 20
    static let frameCap = BufferCap(count: maximumFrames, bytes: maximumFrameBytes)
    static let audioCap = BufferCap(count: maximumAudio, bytes: maximumAudioBytes)

    private let lock = NSLock()
    private var video = CappedQueue<CMSampleBuffer>(cap: frameCap, size: BufferCap.size)
    private var audio = CappedQueue<CMSampleBuffer>(cap: audioCap, size: BufferCap.size)

    private var _videoFormat: CMFormatDescription?
    private var _audioFormat: CMFormatDescription?
    private var _firstVideoTime: CMTime?
    private var _latestVideoTime: CMTime?
    /// The distance of the audio to the youngest picture on its arrival, in seconds — smallest
    /// and largest ever seen. See ``audioSkew``.
    private var _skewMin: Double?
    private var _skewMax: Double?
    private var _receivedVideo = 0
    private var _receivedAudio = 0
    private var _discarded = 0
    private var _discontinuities = 0
    private var _finished = false
    private var hasReportedOverflow = false
    /// The picture cadence, measured from the intervals between pictures — for the renderer's
    /// frame-rate registration. See ``FrameCadence``.
    private var cadence = FrameCadence()
    private var lastOrder: CMTime?

    /// The name in the log lines — with the channel, if one is known.
    private let tag: String

    /// Who wants to be woken as soon as something new is there.
    ///
    /// The renderer asks via `requestMediaDataWhenReady` only while it is hungry **and** gets
    /// something; if it stands before an empty store, it does not call again by itself. Without
    /// the wake-up call the engine would stay silent forever after the first idle moment.
    public var onAvailable: (@Sendable () -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _onAvailable
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _onAvailable = newValue
        }
    }
    private var _onAvailable: (@Sendable () -> Void)?

    public init(label: String? = nil) {
        tag = label.map { "Vorrat „\($0)“" } ?? "Vorrat"
    }

    // MARK: - SampleSink

    /// A store never fails — it only holds. What does not fit is reported by the engine.
    public var failure: Error? { nil }

    @discardableResult
    public func append(video sample: CMSampleBuffer) -> Bool {
        lock.lock()
        if _videoFormat == nil { _videoFormat = sample.formatDescription }
        let order = Self.order(of: sample)
        if _firstVideoTime == nil { _firstVideoTime = order }
        _latestVideoTime = _latestVideoTime.map { max($0, order) } ?? order
        if let lastOrder { cadence.add((order - lastOrder).seconds) }
        lastOrder = order
        _receivedVideo += 1
        let overflow = video.append(sample)
        _discarded += overflow
        let report = overflow > 0 && !hasReportedOverflow
        if report { hasReportedOverflow = true }
        let backlog = (video.count, video.bytes >> 20)
        let wake = _onAvailable
        lock.unlock()

        if report {
            Diagnostics.playbackProblem(
                "\(tag): \(backlog.0) pictures (\(backlog.1) MB) waiting for an engine "
                    + "that does not take them — older ones are discarded",
                since: nil)
        }
        wake?()
        return true
    }

    @discardableResult
    public func append(audio sample: CMSampleBuffer) -> Bool {
        lock.lock()
        if _audioFormat == nil { _audioFormat = sample.formatDescription }
        _receivedAudio += 1
        if let latest = _latestVideoTime {
            let skew = (sample.presentationTimeStamp - latest).seconds
            if skew.isFinite {
                _skewMin = min(_skewMin ?? skew, skew)
                _skewMax = max(_skewMax ?? skew, skew)
            }
        }
        _discarded += audio.append(sample)
        let wake = _onAvailable
        lock.unlock()
        wake?()
        return true
    }

    /// A break is counted, not handled: The time stays continuous through ``StreamClock``, the
    /// engine simply plays on.
    public func discontinuity() {
        lock.lock()
        defer { lock.unlock() }
        _discontinuities += 1
    }

    /// Throws away the waiting audio of the old track and counts the switch — the engine reads
    /// the number and flushes its audio renderer.
    public func audioTrackChanged() {
        lock.lock()
        defer { lock.unlock() }
        audio.removeAll()
        _audioFormat = nil
        _audioSwitches += 1
    }

    private var _audioSwitches = 0

    /// How often the audio track was switched — for the engine, which flushes as a result.
    public var audioSwitches: Int {
        lock.lock()
        defer { lock.unlock() }
        return _audioSwitches
    }

    // MARK: - Tonspurwahl

    /// An audio track to choose from — the identifier is the PID.
    public struct AudioOption: Sendable, Equatable {
        public let pid: UInt16
        public let codec: String
        public let language: String?

        public init(pid: UInt16, codec: String, language: String?) {
            self.pid = pid
            self.codec = codec
            self.language = language
        }
    }

    /// What the session offers in audio tracks — set as soon as the program table has been
    /// read. The engine turns it into its menu.
    public var audioOptions: [AudioOption] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _audioOptions
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _audioOptions = newValue
        }
    }
    private var _audioOptions: [AudioOption] = []

    /// Which track is currently passing through — the session keeps track of it.
    public var selectedAudioPID: UInt16? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _selectedAudioPID
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _selectedAudioPID = newValue
        }
    }
    private var _selectedAudioPID: UInt16?

    /// The wire back to the session: The engine chooses, the remuxer switches.
    public var onSelectAudio: (@Sendable (UInt16) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _onSelectAudio
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _onSelectAudio = newValue
        }
    }
    private var _onSelectAudio: (@Sendable (UInt16) -> Void)?

    public func finish() async {
        // `withLock` instead of `lock()`/`unlock()`: A lock held by hand is forbidden in an
        // asynchronous body in Swift 6 — it could be held across a suspension point.
        let wake: (@Sendable () -> Void)? = lock.withLock {
            _finished = true
            return _onAvailable
        }
        wake?()
    }

    // MARK: - Abnehmen

    /// The description of the next waiting picture — without fetching it. For the decision who
    /// decodes, before the first picture goes out.
    public func peekVideoFormat() -> CMFormatDescription? {
        lock.lock()
        defer { lock.unlock() }
        return video.first?.formatDescription
    }

    /// The next picture in decode order — or `nil` if none is waiting.
    public func nextVideo() -> CMSampleBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard !video.isEmpty else { return nil }
        return video.removeFirst()
    }

    public func nextAudio() -> CMSampleBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard !audio.isEmpty else { return nil }
        return audio.removeFirst()
    }

    /// Throws away everything waiting — when the engine stops.
    public func drain() {
        lock.lock()
        defer { lock.unlock() }
        video.removeAll()
        audio.removeAll()
    }

    // MARK: - Auskunft

    public var videoFormat: CMFormatDescription? {
        lock.lock()
        defer { lock.unlock() }
        return _videoFormat
    }

    public var audioFormat: CMFormatDescription? {
        lock.lock()
        defer { lock.unlock() }
        return _audioFormat
    }

    /// The time of the very first picture — the anchor at which the engine sets its clock.
    public var firstVideoTime: CMTime? {
        lock.lock()
        defer { lock.unlock() }
        return _firstVideoTime
    }

    /// The youngest picture time ever delivered — it says how far the broadcast is there,
    /// whether the picture still waits here or already lies with the engine.
    public var latestVideoTime: CMTime? {
        lock.lock()
        defer { lock.unlock() }
        return _latestVideoTime
    }

    /// How much broadcast is still waiting **here**, in seconds: from the picture that will be
    /// fetched next up to the youngest delivered.
    ///
    /// Before the first fetch this is the entire startup buffer — the number
    /// ``LiveRemuxSession`` waits for. Afterwards it is only the part that has not yet reached
    /// the engine; how far ahead **it** is, only it knows itself.
    public var bufferedSeconds: Double {
        lock.lock()
        defer { lock.unlock() }
        guard let latest = _latestVideoTime, let first = video.first else { return 0 }
        return max(0, (latest - Self.order(of: first)).seconds)
    }

    /// The time of the picture that would be fetched next — `nil` if none is waiting.
    public var firstPendingVideoTime: CMTime? {
        lock.lock()
        defer { lock.unlock() }
        return video.first.map(Self.order(of:))
    }

    public var pendingVideoCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return video.count
    }

    public var pendingAudioCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return audio.count
    }

    /// How many pictures ever came in — including those long since fetched.
    public var receivedVideo: Int {
        lock.lock()
        defer { lock.unlock() }
        return _receivedVideo
    }

    public var receivedAudio: Int {
        lock.lock()
        defer { lock.unlock() }
        return _receivedAudio
    }

    /// Where the audio arrives relative to the picture — range over the session.
    ///
    /// **The number for "picture and audio do not match"** (F-016, Pusula 1): Negative means
    /// the audio arrives behind the youngest picture — the normal case of interleaving, a few
    /// tenths. Both tracks go through the same clock; if the range widens far over the session,
    /// the channel itself drifts, and no renderer can heal that. If it stays narrow, an offset
    /// is not due to the stamps.
    public var audioSkew: ClosedRange<Double>? {
        lock.lock()
        defer { lock.unlock() }
        guard let lo = _skewMin, let hi = _skewMax else { return nil }
        return lo...hi
    }

    /// How many packets were dropped because of a stalled consumer.
    public var discarded: Int {
        lock.lock()
        defer { lock.unlock() }
        return _discarded
    }

    public var discontinuities: Int {
        lock.lock()
        defer { lock.unlock() }
        return _discontinuities
    }

    public var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _finished
    }

    /// The measured picture cadence in hertz — `nil` as long as too little has been measured.
    public var frameRate: Double? {
        lock.lock()
        defer { lock.unlock() }
        return cadence.rate
    }

    /// Whether a picture has been there at all.
    public var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _receivedVideo > 0
    }

    /// The time by which a picture is queued: the decode time where there is one, otherwise the
    /// presentation time.
    ///
    /// With B-frames the presentation time jumps back; the decode time rises strictly, the
    /// remuxer ensures that. Only with it is "how far is the broadcast there" a number that does
    /// not jitter.
    static func order(of sample: CMSampleBuffer) -> CMTime {
        let decode = sample.decodeTimeStamp
        return decode.isValid ? decode : sample.presentationTimeStamp
    }
}
