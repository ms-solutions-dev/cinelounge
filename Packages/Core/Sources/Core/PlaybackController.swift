import Foundation

/// What a playback engine has to be able to do.
///
/// Two implementations fulfil it — VLC and the system player. The choice is made by
/// ``PlaybackEngineSelector``; the interface knows only this contract and does not
/// notice who is playing. That is the purpose: the control bar, skipping the intro
/// and the progress report are built once, not twice.
///
/// **Deliberately kept narrow.** Everything that can be done outside is not here:
/// reporting progress to the server, finding the next episode, fetching intro
/// sections. A broad contract forces both engines into stubs for things that only one
/// can do.
@MainActor
public protocol PlaybackController: AnyObject {

    /// What is happening right now.
    var status: PlaybackStatus { get }

    /// Where we are and how long the whole is.
    var position: TimeInterval { get }
    var duration: TimeInterval { get }

    /// The tracks present.
    ///
    /// **Not ready immediately.** VLC determines them only while the playback starts up —
    /// whoever asks right after starting gets an empty list. That was noticed in the
    /// proof from E0 and applies to the contract as a whole: the interface must expect
    /// that tracks appear later.
    var audioTracks: [PlaybackTrack] { get }
    var subtitleTracks: [PlaybackTrack] { get }

    var selectedAudioTrack: PlaybackTrack.ID? { get }
    var selectedSubtitleTrack: PlaybackTrack.ID? { get }

    /// The already loaded span around the current position, in seconds of the stream.
    ///
    /// `nil` if the engine does not know it — VLC, for instance, does not hand it out.
    /// For a file read raw the information decides whether a jump stays with the player
    /// or goes to the server as a new request: within the span the player jumps itself,
    /// everything outside would first have to download what lies between here and there
    /// — and exactly that takes time.
    var bufferedRange: ClosedRange<TimeInterval>? { get }

    /// The window in which one can jump with a channel that has a time offset — from the
    /// oldest piece in the ring to the live edge, in the time of the engine.
    ///
    /// **The limits of the timeline in the buffer** (AP58 G1, A1). A channel has no
    /// length; without this window no bar would know where it starts and where "now" is.
    var timeShiftWindow: ClosedRange<TimeInterval>? { get }

    /// Whether the engine actually delivers a picture.
    ///
    /// **Audio without picture is the case this question exists for** (finding 2026-08-08:
    /// the provider's 4K channels played audibly, the picture stayed black — on the
    /// device as in the simulator). Apple's player accepts a playlist with HEVC in
    /// MPEG-TS although it cannot decode this pairing: it plays the audio, reports no
    /// error and lets the clock run. Neither state nor progress give it away — only the
    /// picture size stays zero.
    ///
    /// `nil` means "I don't know" and is the default: engines that give no information
    /// should not wrongly count as pictureless.
    var hasVideoOutput: Bool? { get }

    /// Whether the first picture has become **visible** — not merely announced.
    ///
    /// A different question from ``hasVideoOutput``, and the separation is the whole
    /// purpose: the picture size says whether the engine can decode the track at all —
    /// with the system player, however, it is already there when it has merely read the
    /// metadata, long before a picture is drawn. For the blind detection that is right
    /// (if it stays zero, no picture ever comes); for the startup measurement it is a
    /// lie — it measured "metadata read" and called it "first picture".
    ///
    /// `nil` means "I don't know" here too: without a drawing surface there is no honest
    /// answer, and a guessed one would be worse than none.
    var firstFrameVisible: Bool? { get }

    /// How many pictures the engine has **discarded** so far.
    ///
    /// **The gap that the judder of 2026-08-22 fell through.** ``PlaybackTrace`` measures the
    /// position twice per second and recognizes stall and lead from it — both events of
    /// half a second upward. An engine that throws away every second picture moves the
    /// position on completely regularly in the process: the measurement reports "ran
    /// through" while the viewer sees stuttering. Discarded pictures are the only
    /// quantity that names this case at all.
    ///
    /// `nil` means, as everywhere here, "I don't know" — an engine without this
    /// information should not pass as "zero discarded", for that would be an exoneration
    /// that nobody has proven.
    var droppedVideoFrames: Int? { get }

    /// What the line carries and what the film needs — measured while the engine loads a
    /// file (AP69). `nil` if the engine does not know it or the measurement has no
    /// honest window yet; the stall board then says its previous sentence.
    var lineFinding: LineFinding? { get }

    /// When the engine became ready to play — the time of the **event**, not that of the
    /// asking.
    ///
    /// **Explicitly a date and not a truth value.** An "is ready", polled every 50 ms,
    /// would carry the timestamp of the sample and not that of the readiness — exactly
    /// the error from which the 156 of 156 zeros at "first picture" arose: both marks of
    /// the startup measurement came from the same sample and thus from the same instant.
    /// Only a date can also be checked against ``StartupTiming/startedAt``, and exactly
    /// this check catches the timestamp of a previous target.
    ///
    /// `nil` means, as everywhere in this contract, "I don't know" and not "was never
    /// ready".
    var readyToPlayAt: Date? { get }

    /// Whether the last failure was AVPlayer's rejection of the partial path
    /// (CoreMediaErrorDomain -15410, "Low Latency: Server must support http2 ECN and
    /// SACK") — see ``LowLatencyMemory``.
    var rejectedLowLatency: Bool { get }

    func load(_ url: URL, startingAt position: TimeInterval)
    func play()
    func pause()
    func stop()
    func seek(to position: TimeInterval)
    /// Jumps to the leading edge of what can be played — with a channel that has a time
    /// offset back to live. The default jumps "infinitely far", an engine that knows its
    /// time axis lands more precisely.
    func seekToLiveEdge()

    func selectAudioTrack(_ id: PlaybackTrack.ID)
    /// `nil` schaltet Untertitel ab.
    func selectSubtitleTrack(_ id: PlaybackTrack.ID?)

    /// Whether this engine can change the speed at all.
    ///
    /// **An information and not an attempt.** On the phone a long press holds the film at
    /// double speed (AP4); where that does not work, the gesture should imply nothing
    /// instead of grasping at nothing. The default is `false` — an engine that says
    /// nothing cannot do it.
    var supportsSpeed: Bool { get }

    /// Sets the playback speed. 1 is the default.
    ///
    /// **Only as long as it is held.** The caller resets it; an engine that remembers the
    /// speed carries it over to the next title — and nobody would find the switch again
    /// that they never consciously flipped.
    func setRate(_ rate: Double)

    /// Keeps the subtitle line in the visible area when the picture is filled.
    ///
    /// - Parameter sichtbarerAnteil: What share of the picture height remains after the
    ///   crop, 0 to 1. At 1 what the viewer has set in the system applies again — see
    ///   ``SubtitleLayout``.
    func setSubtitlePosition(visibleFraction: Double)
}

extension PlaybackController {

    /// The default for engines that do not know their loaded span.
    ///
    /// As a default and not as an obligation so that the contract stays narrow: whoever
    /// cannot deliver the span should not have to write a stub — and the caller then falls
    /// back to a fixed jump distance.
    public var bufferedRange: ClosedRange<TimeInterval>? { nil }

    /// The default: whoever knows no window has no time offset to show.
    public var timeShiftWindow: ClosedRange<TimeInterval>? { nil }

    /// The default for engines without information — see ``hasVideoOutput``.
    public var hasVideoOutput: Bool? { nil }

    /// The default for engines without information — see ``firstFrameVisible``.
    public var firstFrameVisible: Bool? { nil }

    /// The default for engines without information — see ``droppedVideoFrames``.
    public var droppedVideoFrames: Int? { nil }

    /// The default for engines without information — see ``lineFinding``.
    public var lineFinding: LineFinding? { nil }

    /// The default for engines without information — see ``readyToPlayAt``.
    ///
    /// Both of today's implementers answer the question themselves; the default is there
    /// anyway because it carries the doctrine of this contract: no information is not
    /// zero.
    public var readyToPlayAt: Date? { nil }

    /// The default: whoever does not know the partial path cannot reject it.
    public var rejectedLowLatency: Bool { false }

    /// The default: an engine that says nothing cannot do speed — see ``supportsSpeed``.
    public var supportsSpeed: Bool { false }

    /// The default does nothing, and ``supportsSpeed`` says so in advance.
    public func setRate(_ rate: Double) {}

    /// The default does nothing.
    ///
    /// **And with an engine without subtitles of its own that is the right answer.**
    /// Whoever draws no text track has no line to shift either; a stub that tried would
    /// shift something that does not exist.
    public func setSubtitlePosition(visibleFraction: Double) {}
}

/// The state of playback.
///
/// "Buffering" is a case of its own and not the same as "paused": with one you wait,
/// with the other you have stopped yourself. Whoever shows both alike leaves the
/// viewer in the dark as to why the picture stands.
public enum PlaybackStatus: String, Sendable, Equatable {
    case idle
    case opening
    case buffering
    case playing
    case paused
    case ended
    case failed
}

/// An audio or subtitle track.
public struct PlaybackTrack: Identifiable, Sendable, Equatable {

    public let id: Int
    /// What the engine calls it — often "Track 2" or nothing at all.
    public let rawName: String?
    /// Language code per ISO, such as `deu`.
    public let language: String?

    /// Whether the track translates only the passages that are not understood.
    ///
    /// Stated here because it has to be visible in the menu: with "Survival" the two
    /// tracks would otherwise simply be called "Deutsch" and "Englisch", and whoever
    /// chooses "Deutsch" gets 199 captions instead of the 800 of the whole film — and
    /// takes the subtitles to be broken.
    public let isForced: Bool

    public init(
        id: Int,
        rawName: String? = nil,
        language: String? = nil,
        isForced: Bool = false
    ) {
        self.id = id
        self.rawName = rawName
        self.language = language
        self.isForced = isForced
    }

    /// How the track is shown to the viewer.
    ///
    /// The language first and in the local language: whoever chooses an audio track
    /// looks for "Deutsch" or "Japanisch" — not "Track 2" and not "deu". Only if no
    /// language is on file does the raw name have to do.
    public func displayName(locale: Locale = .current) -> String {
        marked(baseName(locale: locale))
    }

    private func baseName(locale: Locale) -> String {
        if let language, !language.isEmpty,
            let name = locale.localizedString(forLanguageCode: language)
        {
            // Some files carry two tracks of the same language — for example original and audio
            // commentary. Then the raw name helps to tell them apart.
            if let rawName, Self.isMeaningful(rawName),
                !rawName.localizedCaseInsensitiveContains(name)
            {
                return "\(name.localizedCapitalized) · \(rawName)"
            }
            return name.localizedCapitalized
        }

        if let rawName, !rawName.isEmpty { return rawName }
        return language ?? ""
    }

    /// Appends "Erzwungen" where it applies — and only there.
    ///
    /// **The addition is no decoration but the very information that matters.** Without
    /// it the two German tracks of a film do not differ in the menu in any way, although
    /// one carries eleven and the other eight hundred captions.
    ///
    /// The word comes from the shared catalog (`WordingKit`) in the language of the app and
    /// not from `locale`: here the locale answers only what a **language** is called.
    /// There is no second way by which the app language is set — both statements come
    /// from the same choice on the device. Until 2026-09-26 the word was in the apps'
    /// catalogs, and the phone's was missing it (AP58, report B finding 1).
    private func marked(_ name: String) -> String {
        guard isForced else { return name }
        let label = AppLanguageSetting.word("player.subtitleForced")
        // If the raw name already carries the word (Jellyfin writes "Erzwungen" into its
        // display names), the addition would be a duplication.
        guard !name.localizedCaseInsensitiveContains(label) else { return name }
        return name.isEmpty ? label : "\(name) · \(label)"
    }

    /// Translates the server's tracks into display tracks.
    ///
    /// For targets whose tracks the **server** manages (chunking): there the engine knows
    /// only the one packed track, the selection is fed from the metadata. The identifier
    /// is the Jellyfin track number — the same one that goes into the address as
    /// `AudioStreamIndex`/`SubtitleStreamIndex` on a switch.
    ///
    /// The server name ("German - Standard - SUBRIP") comes along only where it makes a
    /// difference: with two tracks of the same language **and** the same forced
    /// attribute, or if no language is on file at all. Otherwise "Deutsch" suffices — the
    /// rationale is at ``displayName(locale:)``.
    ///
    /// **The forced attribute belongs in the comparison** since it appears in the name:
    /// with "Brianklauvas" two German tracks stand side by side, a forced one and a full
    /// one. Without it each would drag the whole server name along ("Deutsch ·
    /// de--forced-- - German - Standard - Erzwungen - SUBRIP"), although "Deutsch ·
    /// Erzwungen" against "Deutsch" already makes the difference.
    public static func fromServer(_ tracks: [MediaTrack]) -> [PlaybackTrack] {
        // **Count once instead of searching per track** (AP7 · L7): the `contains` in the
        // body made the implementation quadratic, and it ran twice per tick — so four times
        // per second over all tracks. For a title with thirty subtitle tracks that is 1800
        // comparisons per second for a result that never changes within a target.
        var similar: [Group: Int] = [:]
        for track in tracks {
            similar[Group(language: track.language, isForced: track.isForced), default: 0] += 1
        }

        return tracks.compactMap { track in
            guard let index = Int(track.id) else { return nil }
            let needsName =
                (similar[Group(language: track.language, isForced: track.isForced)] ?? 0) > 1
            return PlaybackTrack(
                id: index,
                rawName: needsName || track.language == nil ? track.title : nil,
                language: track.language,
                isForced: track.isForced
            )
        }
    }

    /// Language and forced attribute together — the question on which it is decided
    /// whether a track needs its raw name.
    private struct Group: Hashable {
        let language: String?
        let isForced: Bool
    }

    /// Whether a raw name contributes anything.
    ///
    /// Most files call their tracks "Track 1", "Audio 2" or "Spur 3". That is no
    /// designation but a number — and "Deutsch · Track 1" says no more than "Deutsch",
    /// yet takes up space and distracts.
    ///
    /// Recognized by its form: a single generic word followed by a number.
    static func isMeaningful(_ rawName: String) -> Bool {
        let trimmed = rawName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }

        let generic = ["track", "audio", "spur", "stream", "subtitle", "untertitel", "piste"]
        let parts = trimmed.lowercased().split(separator: " ")

        // "Track" alone, or "Track" plus a number.
        if parts.count <= 2, let first = parts.first, generic.contains(String(first)) {
            let rest = parts.dropFirst().joined()
            return !(rest.isEmpty || Int(rest) != nil)
        }
        return true
    }
}

extension PlaybackController {
    public func seekToLiveEdge() {
        seek(to: .greatestFiniteMagnitude)
    }
}
