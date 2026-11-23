import Core
import Foundation

/// Where the player gets its address and its details from.
///
/// **Narrow like the other sources.** `Core.ContentSource` can do forty things; the
/// player needs three — the address, reporting progress back and the next episode. A
/// protocol that demands only what is needed can be rebuilt in a test with ten lines.
public protocol PlayerSource: Sendable {

    /// Everything needed for playback — address, tracks, chapters, start position.
    func target(zu job: PlaybackJob) async throws -> PlaybackRequest

    /// The address from which one can **download** — for the downloads.
    ///
    /// **Two questions and not one, because the server answers them differently.** Until
    /// 2026-09-08 this said that a second resolution chain would be the place where downloads
    /// and player drift apart. The sentence is right — and it cost the whole loading path,
    /// because it carried the wrong conclusion: there remains **one** chain, it only answers
    /// two questions.
    ///
    /// **Measured on 2026-09-08 against the media server of this setup:**
    ///
    /// | Address | Status for a range request |
    /// |---|---|
    /// | `/Videos/{id}/stream?static=true` | **206**, `Accept-Ranges: bytes` |
    /// | `/Videos/{id}/stream.mp4?VideoBitrate=…` (transcoded) | **200**, `Accept-Ranges: none` |
    ///
    /// The transcoded version is a **stream** and not a file; Jellyfin says so itself.
    /// The download run, however, fetches block by block and demands 206 — it therefore
    /// failed at the **first** block with "Range not answered (200)", and the screen said
    /// "Loading · 0 KB", forever.
    ///
    /// **Why this is the difference from a browser** (question raised on 2026-09-08: a browser
    /// can download such a file — where is the difference?): a browser loads the address it
    /// is given, and that is a **file**. This app asked for a transcoded version in 720p —
    /// and the media server offers that only as a stream. Not the download was difficult,
    /// the address was the wrong one.
    ///
    /// **The default is ``target(zu:)``**, because for portals and channels there is no second
    /// address: a portal resolves a host file, and it is the same one that plays.
    func loadTarget(zu job: PlaybackJob) async throws -> PlaybackRequest

    /// Reports how far someone is.
    ///
    /// **The server keeps the progress, not the app.** Anyone who noted it only locally
    /// would not have it on the TV — and that is exactly what this path is for.
    func notify(
        location: TimeInterval, duration: TimeInterval, zu job: PlaybackJob, isPaused: Bool)
        async throws

    /// What comes after this episode. `nil` for a film, at the end of a season and for
    /// everything that knows no episodes.
    func nextEpisode(after job: PlaybackJob) async throws -> PlaybackRequest?

    /// The segments of a title — intro, recap, credits (AP58 R4).
    ///
    /// **For skipping and for the trigger point of the next episode.** The TV has always
    /// asked for them; on the phone neither existed.
    func segments(zu job: PlaybackJob) async throws -> [MediaSegment]

    /// Tells the server that a playback **begins**.
    ///
    /// **With an account that has exactly one allowed connection this is no cosmetic
    /// flaw.** A session that never ends keeps counting as open; the next request then gets
    /// "occupied" instead of a picture. In the whole phone project `beginSession` occurred
    /// **not once** until 2026-09-06.
    func begin(_ job: PlaybackJob) async throws

    /// And that it ends — with the position where it was stopped.
    func finish(_ job: PlaybackJob, at location: TimeInterval) async throws

    /// What this title offers in hosts, tiers and versions.
    ///
    /// **Only portals have an answer to that.** A media server has one file, a channel one
    /// stream; the choice between third-party addresses exists only where the addresses are
    /// third-party.
    func host(zu job: PlaybackJob) async throws -> [PortalHost]

    /// The content source behind this request — **for what the player shows beyond the
    /// title** (AP58 G1): cast and further episodes (A4), preview images while scrubbing
    /// (A7) and the similar movie at the end (A8).
    ///
    /// **The same source that the TV asks** — `Core.ContentSource` —, so that the shared
    /// flows (``Flows/InfoBoard``) read the same on both devices. It has already passed
    /// through the parental-controls filter. `nil` for channels, the downloads and
    /// everything that has no catalog.
    func contents(zu job: PlaybackJob) -> (any ContentSource)?

    /// Whether a title **that the player offers on its own** may play — the parental-controls
    /// filter at the last step (review 2026-09-25, finding 1).
    func mayPlay(_ title: MediaItem, zu job: PlaybackJob) -> Bool
}

extension PlayerSource {

    /// Without an answer of its own, the download address is the playback address.
    public func loadTarget(zu job: PlaybackJob) async throws -> PlaybackRequest {
        try await target(zu: job)
    }

    /// **Default for sources that know no episodes.** A channel has no next episode, and a
    /// portal keeps no season order from which one would result.
    public func nextEpisode(after job: PlaybackJob) async throws -> PlaybackRequest? {
        nil
    }

    /// **Default for sources without segments** — channels, portals, the downloads.
    public func segments(zu job: PlaybackJob) async throws -> [MediaSegment] { [] }

    /// **Default for sources without a session concept.** A portal has no session that
    /// could be opened — there is no account there that counts one.
    public func begin(_ job: PlaybackJob) async throws {}
    public func finish(_ job: PlaybackJob, at location: TimeInterval) async throws {}

    /// **Default for sources without a source choice** — empty, and the choice then drops
    /// out by itself: ``PortalSourceChoice/isWorthwhile`` is false on an empty list, and the
    /// button in the player header does not appear at all.
    public func host(zu job: PlaybackJob) async throws -> [PortalHost] { [] }

    /// **Default: no catalog** — and thereby no board, no preview image, no offer.
    public func contents(zu job: PlaybackJob) -> (any ContentSource)? { nil }

    /// **Default: no.** Anyone who cannot say whether a title may play offers none —
    /// parental controls close in case of doubt (decision 20).
    public func mayPlay(_ title: MediaItem, zu job: PlaybackJob) -> Bool { false }
}

/// What the player needs for playback.
public struct PlaybackRequest: Sendable, Equatable {

    public let identifier: String
    public let title: String
    /// The second line — for an episode "S1 F35", for a film the year.
    public let beside: String?
    public let address: URL

    /// What the address needs in headers — **empty for everything except portals.**
    ///
    /// **Finding of 2026-09-09:** the bridge delivers its headers with every host address
    /// (Referer and related), and until then `PortalSource.stream(forItem:source:)` threw them
    /// away. This went unnoticed during playback — there the stream runs through the bridge,
    /// which sets them itself. When **downloading** it is the difference between a file and
    /// a 403 before the first byte.
    public let headers: [String: String]

    /// Where to begin, in seconds.
    ///
    /// **The server says it, not the app.** Anyone who stopped at minute 17 wants to resume
    /// there — even if they last watched on the TV.
    public let startAt: TimeInterval
    public let duration: TimeInterval?

    public let audioTracks: [PlaybackTrack]
    public let subtitles: [PlaybackTrack]

    /// What to begin with — **chosen where the source still knows everything** (E45).
    ///
    /// **Why not in the player.** ``Core/StartingTracks/select(for:isAnime:preference:interfaceLanguage:)``
    /// chooses audio **and** subtitles together and needs a `MediaSource` for that — only the
    /// source has it, and precisely at the place where it already computes ``isAnime``. The
    /// player gets two identifiers and applies them; it would otherwise have to ask for
    /// information that was long since there one level above it.
    ///
    /// **Together and not twice individually**, because the rule is: "anime in the original
    /// audio" means Japanese audio **and** subtitles in the interface language — anyone who
    /// switches only the audio track delivers Japanese audio without text.
    ///
    /// **`nil` means "nothing to choose", not "off".** For a channel, a portal and everywhere
    /// else where no rule applies, the file's default stays. A rule that finds nothing must
    /// not silently land on some track.
    public var startAudio: PlaybackTrack.ID?
    public var startSubtitle: PlaybackTrack.ID?

    /// The language of the starting tracks — **for the engine and remuxer, which choose
    /// themselves** (AP58 R4).
    ///
    /// With chunked delivery the choice stands as a track number in the address; anyone who
    /// remuxes a Matroska themselves finds the audio track only through the language
    /// (`MatroskaFileSession(audioLanguage:)`). Until R4 it never arrived on the phone, and
    /// the remuxer took the first track of the file — for an anime the dubbed one.
    public var audioLanguage: String?
    public var subtitleLanguage: String?
    public let chapters: [Chapter]

    /// For the shelf and for the history.
    public let image: URL?

    /// Whether the picture is **landscape** — `nil` means: unknown.
    ///
    /// **It lives here because ``image`` lives here too** (2026-09-08). The history arises at the
    /// end of playback from this request; without the field, a landscape poster from a portal
    /// would arrive in "Continue Watching" again in the portrait frame — even after the portal
    /// layer has long been doing it right.
    ///
    /// **Not threaded through the ``PlaybackJob``**, although the series comes exactly that
    /// way: the series is known only to whoever enters the player; the picture format is known
    /// by the **source**, and it sets the picture address one line further on anyway.
    /// Threading four sources to hand over something that each of them knows itself would be
    /// four places instead of one.
    public let wide: Bool?

    public let backdrop: URL?
    public let description: String?
    public let origin: Catalog.Origin

    /// Until when the address is valid. `nil` means **"unknown"**, not "forever".
    ///
    /// **Only portals name one.** A host address is valid for five minutes, and five minutes
    /// are shorter than any interruption — on the phone the case occurs constantly. Without
    /// this number "expired" and "the host does not hand over the film" look the same, and
    /// the only possible answer would be to resolve anew on **every** playback error. That is
    /// exactly what the schedule warns against: "one would re-fetch on every playback
    /// error".
    public let validUntil: Date?

    /// Whether the address has expired **now**.
    ///
    /// Without an expiry the answer is **no** and not "maybe": anyone who treats an unknown
    /// expiry like an expired one re-fetches on every error again.
    public func isExpired(um time: Date = Date()) -> Bool {
        guard let validUntil else { return false }
        return validUntil <= time
    }

    /// What kind of thing this is — recording, channel or preview.
    ///
    /// **Until 2026-09-06 everything counted as a recording.** A channel was thereby scrubbable
    /// and wrote progress: `PlaybackTarget.tracksProgress` and `isSeekable` hang exactly on
    /// this field, and the default value `.recording` made every channel a film with a length
    /// and an end. The progress of a channel is a number without meaning — it ended up in the
    /// history all the same.
    public let kind: PlaybackTarget.Kind

    /// How the engine gets to this title — **fetched and not calculated.**
    ///
    /// **The finding of 2026-09-07:** no title of the media server played;
    /// `AVFoundationErrorDomain -11828` after half a second. This field did not exist.
    /// ``JellyfinPlayerSource`` fetched the decision from `PlaybackEngineSelector`, wrote it
    /// into the diagnostics — and dropped it; ``target`` invented a new one via ``deliveryRoute``,
    /// and that one read "native via hls" for every recording. For a Matroska the **real** one
    /// is `remuxInApp`, and `JellyfinSource.streamURL` builds the **raw** file for it
    /// (`Videos/<id>/stream?static=true`). ``RepackagerRun/isNeeded(_:)`` reads the delivery
    /// path, saw the invented `hls`, did not kick in — and `AVURLAsset` received a Matroska
    /// without a reader.
    ///
    /// `nil` means **"does not apply to this address"** and not "don't care": channels,
    /// portals and the provider catalog build their address without the delivery path, and
    /// for them ``deliveryRoute`` keeps calculating it from the address — see
    /// ``JellyfinPlayerSource/passedThrough(_:origin:)``.
    public let decision: PlaybackDecision?

    /// Whether the title counts as anime — for the original-audio rule.
    ///
    /// **Decided at the source and not in the player** (2026-09-07). The shared
    /// ``Core/StartingTracks/isAnime(genres:anilistID:)`` needs genres and the AniList
    /// identifier; the player no longer has both, the source very much does. Anyone who
    /// answers the question here answers it once and with the information that exists for it
    /// — instead of guessing in the player.
    ///
    /// **The AniList identifier is the reliable sign**, the genre the second net.
    /// For channels and portals this says `false`: there are neither genres nor an
    /// identifier, and "maybe anime" is no basis for an audio track choice.
    public let isAnime: Bool

    /// The source that this address really carries — **only for portals**, otherwise `nil`.
    ///
    /// Since 2026-09-16 the server may take a different one than the requested one if that
    /// one does not carry (filmhub: the premium mirror answers 403 on every variant). The
    /// player aligns its wish with that, so that the source choice marks the row that is
    /// running — not the one that was pressed.
    public let source: String?

    /// What the parental controls know about the title — **for the history** (AP58,
    /// finding K4).
    ///
    /// `nil` means unknown; such an entry counts as locked in child mode. A channel carries
    /// an empty clearance, because the channel clearance decides about it.
    public let approval: HistoryClearance?

    public init(
        identifier: String, title: String, beside: String? = nil, address: URL,
        headers: [String: String] = [:],
        startAt: TimeInterval = 0, duration: TimeInterval? = nil,
        audioTracks: [PlaybackTrack] = [], subtitles: [PlaybackTrack] = [],
        chapters: [Chapter] = [], image: URL? = nil, backdrop: URL? = nil,
        description: String? = nil, origin: Catalog.Origin = .jellyfin,
        kind: PlaybackTarget.Kind = .recording, validUntil: Date? = nil,
        decision: PlaybackDecision? = nil, isAnime: Bool = false, wide: Bool? = nil,
        startAudio: PlaybackTrack.ID? = nil, startSubtitle: PlaybackTrack.ID? = nil,
        audioLanguage: String? = nil, subtitleLanguage: String? = nil,
        source: String? = nil, approval: HistoryClearance? = nil
    ) {
        self.audioLanguage = audioLanguage
        self.subtitleLanguage = subtitleLanguage
        self.approval = approval
        self.source = source
        self.identifier = identifier
        self.title = title
        self.beside = beside
        self.address = address
        self.headers = headers
        self.startAt = startAt
        self.duration = duration
        self.audioTracks = audioTracks
        self.subtitles = subtitles
        self.chapters = chapters
        self.image = image
        self.backdrop = backdrop
        self.description = description
        self.origin = origin
        self.kind = kind
        self.validUntil = validUntil
        self.decision = decision
        self.isAnime = isAnime
        self.wide = wide
        self.startAudio = startAudio
        self.startSubtitle = startSubtitle
    }

    /// As a target for the shared engine.
    ///
    /// **`itemID` stays empty for a channel**, and that is the rule of the shared type
    /// itself: "For what progress is reported. Empty for a trailer or a channel: there is
    /// nothing to remember there."
    ///
    /// **The decision that travelled along takes precedence.** Whoever has one has it from
    /// `PlaybackEngineSelector` — from container, codecs, colour range and bandwidth.
    /// Whoever has none gets ``deliveryRoute``, and that is an estimate from the address.
    public var target: PlaybackTarget {
        PlaybackTarget(
            itemID: kind == .recording ? identifier : nil, title: title, subtitle: beside,
            url: address, decision: decision ?? deliveryRoute,
            startAt: startAt, duration: duration, chapters: chapters,
            preferredAudioLanguage: audioLanguage, preferredSubtitleLanguage: subtitleLanguage,
            kind: kind)
    }

    /// Who unpacks the stream, **if nobody has said** — estimated from the address.
    ///
    /// **A fallback since ``decision`` travels along (2026-09-07).** Until then this was the
    /// only path, and it was wrong for the media server: every recording got "native via
    /// hls" here, while the real decision for a Matroska was `remuxInApp` and the address
    /// for it was the **raw** file — `-11828`, a black picture after half a second. Whoever
    /// brings a decision along has not come through here at all since.
    ///
    /// **It remains for the sources that bring none** — channels, portals and the provider
    /// catalog. Their address does not depend on the delivery path: a channel comes as the
    /// access delivers it, and a host delivers a bare address, whatever an evaluator would
    /// have calculated about it.
    ///
    /// **The finding of 2026-09-06, measured on the device:** a provider access that allows only
    /// `ts` delivers the channel as a raw transport stream. Apple's engine plays MPEG-TS
    /// **only inside an HLS playlist**, never raw — it ends with
    /// `AVFoundationErrorDomain -11850` and a black picture. Since AP2 the app remuxes
    /// itself (``RepackagerRun``), and this path has to be told so.
    ///
    /// **By the extension and not by a follow-up question.** Whether the access offers `m3u8`
    /// has already been asked by ``ChannelListingSource/address(forItem:)`` and laid down in exactly
    /// this address — it ends in `.ts` **because** the answer was no. Asking again here would
    /// be a second request against an account that allows one connection.
    ///
    /// **`remuxInApp` and, since AP58 G1, no longer `renderInApp`** (decision 27, A1).
    /// Both remux; the direct renderer waits for no chunk (measured on the TV: 5.0 s to the
    /// picture via chunks against 376–678 ms direct). Until then this said that a channel is
    /// not scrubbable anyway — now it is: only the playlist path puts what falls out of the
    /// downloads into the time-shift ring, and only with it can a channel be paused, rewound
    /// and jumped "back to live". The same path as the default on the TV
    /// (``Core/LiveEngineChoice/preset``); the price is the longer startup.
    ///
    /// **Since AP58 R4 via ``Core/ChannelAddressChoice``**, the same rule as on the TV, with the
    /// direct renderer as the engine. **HEVC counts as decodable:** iOS 18 requires an A12,
    /// and every one of those decodes HEVC in hardware; the question to VideoToolbox was
    /// answered differently only by the simulator, and no channel would run there.
    private var deliveryRoute: PlaybackDecision {
        guard kind == .live else {
            return PlaybackDecision(engine: .native, delivery: .hls, reason: .nativeContainer)
        }
        return ChannelAddressChoice.decision(forItem: address, canDecodeHEVC: true, motor: .hls)
    }

    /// Whether this address is a raw transport stream.
    ///
    /// **Enumerated and not pattern-matched.** `.ts` is the only extension that this
    /// provider uses for the raw stream; a pattern over "everything that is not m3u8" would
    /// also hit a portal address without an extension, and that one comes as a finished
    /// MP4.
    static func isRawStream(_ address: URL) -> Bool {
        address.pathExtension.lowercased() == "ts"
    }

    /// Whether this request belongs in the history at all.
    ///
    /// **A channel does not belong in it.** "Watched 40 %" over a running programme is a
    /// number without meaning, and in the "Continue Watching" shelf it would be an
    /// invitation to something that no longer exists.
    ///
    /// **A recording from the day's schedule does not belong in it** (A2, 2026-09-26): its
    /// identifier is that of the channel, and the tile led to the running channel.
    public var belongsInHistory: Bool { kind == .recording && origin != .channelList }

    /// As a history entry — **the one place where a history arises.**
    /// - Parameter serie: Which series the episode belongs to — see ``PlaybackJob/series``.
    ///
    /// **It comes from outside and not from the request.** The ``PlaybackRequest`` arises in
    /// four different sources; the series, however, is known only to the ``PlaybackJob``
    /// with which the viewer entered the player. Passing it in here is one place, threading
    /// it through all four sources would be four.
    /// - Parameter serienTitel: What the series is called — see ``PlaybackJob/seriesTitle``.
    ///
    /// **If it is there, it becomes the caption, and the episode moves to the second line.**
    /// That is exactly what ``TileArtwork/label(_:)`` does with every other tile:
    /// in a "Continue Watching" shelf one looks for the series and not the fourth episode.
    /// The player could not do that — it knows only the running file —, and that is why the
    /// one portal entry in the simulator carried ``title`` and ``beside`` twice: both
    /// "1 - Mebik".
    public func entry(
        at location: TimeInterval, series: String? = nil, seriesTitle: String? = nil
    ) -> HistoryEntry {
        let name = seriesTitle?.trimmingCharacters(in: .whitespaces)
        let topText = (name?.isEmpty == false) ? name! : title
        return HistoryEntry(
            identifier: identifier, origin: origin, title: topText,
            beside: topText == title ? beside : title, image: image,
            backdrop: backdrop, description: description,
            progress: portion(at: location), series: series, wide: wide, approval: approval)
    }

    /// **Only between the first and the last percent.**
    ///
    /// The same rule as with the progress bar: a bar at 0 % says "something was started
    /// here", and that is then not true; one at 100 % says it too, and then it is over.
    func portion(at location: TimeInterval) -> Double? {
        guard let duration, duration > 0 else { return nil }
        let value = location / duration
        return (value > 0.01 && value < 0.99) ? value : nil
    }
}
