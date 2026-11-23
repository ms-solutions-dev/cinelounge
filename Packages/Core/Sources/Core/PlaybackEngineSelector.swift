import Foundation

/// The engine that playback hides behind.
///
/// **One, not two** (AP8, product decision of 2026-08-15: no more solution paths with
/// VLC). The `vlc` case was still here even though it is never produced at
/// **13 of 13** creating sites — they all say `.native`. An enum case nobody can
/// create is not a choice but a promise to the readers of the source that is not
/// kept: every branch on it looks like a decision and is a dead line.
///
/// The type stays as an enum rather than being removed: it appears in the
/// diagnostics, in the engine choice and in the checks, and a second engine is
/// not ruled out — it is just that today's catalog has one.
public enum PlaybackEngine: String, Sendable, Equatable {
    /// Apple's own engine. Best picture quality, hardware decoding, Picture in Picture,
    /// AirPlay and Dolby Vision — but it understands only a few containers.
    case native

    /// **The direct renderer** (2026-09-03) — Apple's hardware decoder without Apple's
    /// player in front of it: `AVSampleBufferDisplayLayer` and
    /// `AVSampleBufferAudioRenderer` on a shared clock, fed from
    /// our own remuxer.
    ///
    /// **The second engine that AP8 ruled out — and why it comes anyway.**
    /// AP8 was about VLC: a foreign decoder weighing a hundred megabytes with its own
    /// picture pipeline. This one decodes with the same hardware as the system player;
    /// it only drops the container. And the container was the wait: the HLS path
    /// demands whole chunks, a chunk is as long as the distance between two keyframes,
    /// and on the UHD channels that is ten seconds — measured 5.0 s median until the
    /// picture appears (diagnostics F-003, 2026-09-03), while VLC needed 376–678 ms.
    ///
    /// Channels only. Movies stay with the system player, which starts in 303 ms
    /// there and brings seeking, tracks and subtitles with it.
    case renderer
}

/// The route by which the file reaches the device.
public enum Delivery: String, Sendable, Equatable {
    /// Unchanged from the server. Costs it nothing and keeps all tracks.
    case directPlay
    /// Only the container is repackaged, picture and sound stay untouched.
    /// Almost free for the server and without quality loss.
    case remux
    /// Full transcoding. Last resort — costs computing time and quality.
    case transcode
    /// Chunked via HLS with fMP4 segments, for Apple's engine — the route of
    /// Swiftfin and jellyfin-web.
    ///
    /// **The continuous fMP4 stream before it was a proven dead end.** The idea came
    /// from the server log: it showed ffmpeg runs with `container=mp4` and
    /// `-movflags frag_keyframe+empty_moov+delay_moov`, attributed to
    /// UHF. Refuted on the simulator — the runs came from our own old
    /// remux path; UHF itself played the raw Matroska with its own demuxer.
    /// And Apple's engine **fundamentally** cannot open such a source:
    /// `curl -I` on `stream.mp4?static=false` shows `Accept-Ranges: none` and
    /// no length, and without range access or HLS AVFoundation gives up after
    /// two seconds. Every playback failed, without exception.
    ///
    /// Hence HLS again — but with `SegmentContainer=mp4`. The old segments
    /// were MPEG-TS, and **that** was the real mistake of the first HLS period:
    /// AVFoundation demands HEVC in fMP4 segments, in TS the picture stayed black.
    /// The codec lists in the URL stay — the server copies what the device
    /// can handle and transcodes the rest itself.
    ///
    /// With this route, resuming and seeking are the **player's** business: the
    /// playlist covers the full runtime, the engine requests the target segment,
    /// and the server restarts its ffmpeg there on its own.
    /// A `StartTimeTicks` in the URL would bring back the old mistake —
    /// the list would still start at zero, only the display would believe otherwise.
    case hls

    /// **Repackaged in the app.** The container does not suit Apple's engine, but the
    /// hardware can handle picture and sound — so only the wrapper is swapped,
    /// here on the device, and Apple's engine plays the result.
    ///
    /// This is the route P19 was built for: no second engine, no
    /// transcoding on the server, no wait of 925 ms to 14.5 s — what was measured
    /// was 303 ms to the first picture for a file of 369 MB.
    case remuxInApp

    /// **Read in the app and drawn immediately** — the route of
    /// ``PlaybackEngine/renderer``. The same remuxer as for ``remuxInApp``,
    /// but without chunks, server and playlist behind it: the packets go
    /// into a ``SampleQueue``, and the engine picks them up there.
    case renderInApp
}

public struct PlaybackDecision: Sendable, Equatable {

    /// Why this choice was made. It is stated explicitly in the result so that
    /// a wrong playback can be traced back later without having to rethink
    /// the rule.
    public enum Reason: String, Sendable, Equatable {
        case dolbyVisionNeedsNative
        case containerNotNativelySupported
        /// The container fit, but the video or audio codec is foreign — or not
        /// given at all. A case of its own and not a subset of the container case:
        /// anyone who meets an MP4 title on the chunked route should read in the
        /// diagnostics that the codecs decided, and not start looking at the
        /// container, which visibly fit.
        case codecNotProvenNative
        /// Several audio tracks, and the file plays directly — **so that the track stays
        /// selectable.** Was called `multipleAudioTracksNeedVLC` until 2026-09-26 and
        /// thereby named an engine that has not existed since 2026-08-16.
        case multipleAudioTracksStayDirect
        case nativeContainer
        case bandwidthTooLow
        /// **Never delivered since the VLC removal** (remuxer review, finding 9, 2026-09-27).
        ///
        /// Once meant: resuming does not work by seeking, but by the
        /// server starting to deliver further ahead (``PlaybackDecision/startAt`` — here
        /// it said `startOffset`, the name from before the rename). Until VLC was removed
        /// (2026-08-16), ``sourceCanStartAtOffset`` decided in `decide(for:…)` whether this
        /// case applied; since then every decision carries its ``PlaybackDecision/startAt``
        /// on unchanged (``decide(for:…)``, `settled(_:)`) — Apple's engine resumes
        /// by itself, without any motive of its own for it. `decide(for:…)` therefore
        /// never returns this case anymore.
        case resumeStartsAtServer
        /// The viewer has prescribed the engine in the settings.
        ///
        /// A case of its own and not an addendum to the others: anyone who later
        /// investigates an unexpected playback should see at first glance that
        /// the rule did not decide.
        case chosenByViewer
        /// The container does not fit, but the hardware can handle picture and sound — so
        /// the app repackages itself instead of fetching a second engine.
        case remuxedInApp
        /// Like ``remuxedInApp``, but the viewer has chosen the direct renderer
        /// in the diagnostics — the packets go to the engine without a container.
        case renderedInApp
        /// The chosen track forces the server route: an audio codec the device
        /// does not output, or a subtitle that belongs in the chunking. The
        /// file itself would have played directly too — anyone looking here should start
        /// at the track choice, not at the container.
        case trackChoiceNeedsServer
        /// The picture needs a software decoder — H.264 at ten bits (Hi10P).
        /// A case of its own, because the codec name in the diagnostics would otherwise
        /// mislead: `h264` looks like "the hardware can do it", and exactly
        /// this mix-up made the remuxer build streams that
        /// AVFoundation accepts and never decodes (device finding 2026-08-15).
        case videoNeedsSoftwareDecoder
        /// **Nobody can help here anymore** — and that is an answer.
        ///
        /// The case (AP32, 2026-09-11): a source **without a media server** whose
        /// container or video codec Apple's engine does not know and that our own remuxer
        /// cannot take over — a camcorder MPEG-4 Part 2, an H.264 at ten bits
        /// from a provider catalog. Only a server could transcode, and there is none
        /// here.
        ///
        /// **Until then this went unchanged to Apple's engine**: it opened the file,
        /// showed nothing and reported nothing. The choice already knew — it wrote
        /// `containerNotNativelySupported` to the diagnostics and delivered anyway.
        /// **A silent dead end is worse than a refusal:** you press again,
        /// and again.
        case notPlayable = "nichtSpielbar"
    }

    /// Whether this decision is no decision at all — **a route nobody can take.**
    ///
    /// As a question on the result and not as a comparison at the call site: whoever
    /// checks the enumerator themselves will not check it in the next case.
    public var isDeadEnd: Bool { reason == .notPlayable }

    public let engine: PlaybackEngine
    public let delivery: Delivery
    public let reason: Reason

    /// Upper limit for the bit rate in bits per second, `nil` for unlimited.
    ///
    /// Lives in the decision and not with the source, because the two belong
    /// together: whoever limits must have it transcoded — a limit with
    /// unchanged delivery would be a setting without effect, and nobody
    /// would notice that it does not take hold.
    public let maxBitrate: Int?
    /// The picture width that matches the limit. For the reasoning see ``StreamQuality``.
    public let maxWidth: Int?

    /// Whether the delivery route was switched to transcoding because of a bandwidth limit.
    ///
    /// Separate from ``reason``, and that is the point: ``reason`` says why
    /// **this engine** was chosen — subtitles, container, Dolby Vision. That is
    /// a different question from why transcoding happens. If both were written into the same
    /// field, the diagnostics would claim bandwidth for every title whenever a limit is set,
    /// even where the subtitles had decided — and the next troubleshooting
    /// would start in the wrong place.
    public let isBandwidthLimited: Bool

    /// Where playback should begin, in seconds — zero for the start.
    ///
    /// **Back, with a different job** (F-013, 2026-09-04): the offset was removed
    /// together with VLC because Apple's engine resumes by itself. It does resume
    /// — but with HLS it requests the segment at the target position while
    /// the server has just started its ffmpeg at zero. The server then stops it
    /// and restarts with `-ss`, **or** it waits until the remuxing has advanced
    /// from zero to the position: "Continue Watching" at minute
    /// 17 took 30 seconds, during which the server
    /// remuxed 17 minutes of film. With the position in the URL (`StartTimeTicks`),
    /// ffmpeg begins where the engine is about to ask — the list still covers the
    /// full runtime, the engine seeks within it as before.
    public let startAt: TimeInterval

    /// The audio track that the server should put into the chunking — as a
    /// Jellyfin track number, or `nil` for its default choice.
    ///
    /// Set only for the delivery route ``Delivery/hls``: with unchanged delivery
    /// the engine itself chooses between the tracks of the file, and with VLC likewise —
    /// there a number in the URL would be a setting without a recipient.
    public let audioStreamIndex: Int?

    /// The text subtitle that the **app draws itself** — as a
    /// Jellyfin track number, or `nil` for none.
    ///
    /// No longer part of the request: the player fetches the track as WebVTT and lays it
    /// over the picture — the server route via the main list is proven broken on Dolby Vision.
    /// Only plain text arrives here: ASS and bitmap formats
    /// are routed to VLC by the choice beforehand.
    public let subtitleStreamIndex: Int?

    /// Whether the connected display can play HDR.
    ///
    /// Lives in the decision because the server must know it **before** it builds the
    /// stream: only with a declared Dolby Vision capability does it label the
    /// copied HEVC as `dvh1` — only by that does the Apple TV recognise real Dolby
    /// Vision. Without the declaration it copied the same data as `hvc1`, the
    /// TV read the stream as ordinary HEVC, and the embedded
    /// DV metadata showed through as brightness flashes lasting milliseconds —
    /// the proven finding from the on-device test on a profile 5 title.
    ///
    /// The capability comes from the device at runtime (not from a setting):
    /// on the simulator it is off, on an Apple TV 4K with an HDR TV it is on.
    public let displaySupportsHDR: Bool

    public init(
        engine: PlaybackEngine,
        delivery: Delivery,
        reason: Reason,
        maxBitrate: Int? = nil,
        maxWidth: Int? = nil,
        isBandwidthLimited: Bool = false,
        audioStreamIndex: Int? = nil,
        subtitleStreamIndex: Int? = nil,
        displaySupportsHDR: Bool = false,
        startAt: TimeInterval = 0
    ) {
        self.engine = engine
        self.startAt = startAt
        self.delivery = delivery
        self.reason = reason
        self.maxBitrate = maxBitrate
        self.maxWidth = maxWidth
        self.isBandwidthLimited = isBandwidthLimited
        self.audioStreamIndex = audioStreamIndex
        self.subtitleStreamIndex = subtitleStreamIndex
        self.displaySupportsHDR = displaySupportsHDR
    }
}

/// Chooses engine and delivery route based on what the server reports about the file.
///
/// The order of the checks is chosen deliberately and not arbitrarily:
///
/// 1. **Subtitles first.** Anyone who wants character-set or bitmap subtitles
///    shown gets VLC — the native engine simply cannot
///    display them, and burning them in on the server would be expensive and final.
/// 2. **Dolby Vision.** Only the native engine passes the dynamic metadata
///    through. If the container does not fit, it is repackaged instead of transcoded.
/// 3. **A media server delivers to Apple's engine.** Unchanged, what it opens
///    anyway; everything else chunked with fMP4 segments — see
///    ``Delivery/hls``. This is the route of Swiftfin and jellyfin-web.
/// 4. **Without a media server** the file itself decides: what the native engine
///    opens goes to it; the rest to VLC, since nobody repackages there.
public enum PlaybackEngineSelector {

    /// - Parameters:
    ///   - source: What the server knows about the file.
    ///   - wantsSubtitles: Whether a subtitle track should be shown.
    ///   - availableBitrate: Available bandwidth in bits per second, if
    ///     known. If it is not enough, the file is transcoded — otherwise playback stutters.
    ///   - quality: The upper limit set by the viewer. It applies **last**
    ///     and changes only the delivery route, never the engine: which engine can open
    ///     the file depends on subtitles and container and not on
    ///     bandwidth. Whoever lets it co-determine the engine loses the
    ///     character-set subtitles on the go, although they have nothing to do with the limit.
    ///   - startAt: Where playback should begin. Passes unchanged through to the
    ///     returned ``PlaybackDecision/startAt`` (here it said `startOffset`,
    ///     the name from before a rename) — `decide(for:…)` itself no longer reads
    ///     the value, since Apple's engine took over resuming
    ///     on its own with the VLC removal (2026-08-16) (see the reasoning at ``PlaybackDecision/startAt``).
    ///   - sourceCanStartAtOffset: **Unused since the same removal** (remuxer review,
    ///     finding 9, 2026-09-27) — until then this parameter decided whether `startAt`
    ///     was allowed to force the delivery route to remuxing (``PlaybackDecision/Reason/resumeStartsAtServer``);
    ///     `decide(for:…)` has not read it anywhere since. Cleaning up (removing the
    ///     parameter along with its call sites) is a separate, larger
    ///     change across several files — only corrected here so that nobody assumes
    ///     an effect that does not exist.
    public static func decide(
        for source: MediaSource,
        wantsSubtitles: Bool = false,
        audioTrack: MediaTrack? = nil,
        subtitleTrack: MediaTrack? = nil,
        availableBitrate: Int? = nil,
        quality: StreamQuality = .unlimited,
        startAt: TimeInterval = 0,
        sourceCanStartAtOffset: Bool = true,
        /// Whether character-set subtitles may be fetched as plain text —
        /// see ``SubtitleStyle/prefersPlainSubtitles(from:)``.
        prefersPlainSubtitles: Bool = false,
        hasMediaServer: Bool = false,
        displaySupportsHDR: Bool = false,
        /// Whether **this device** decodes HEVC in hardware — from `DeviceCodecs`.
        ///
        /// Given here as an input and not as a fixed assumption in the rule: an
        /// Apple TV of the HD line cannot, the simulator cannot either, and
        /// a future model can do more. Whoever assumes it repackages where
        /// there is nothing to decode — a black picture instead of a second engine
        /// that could do it in software.
        canDecodeHEVC: Bool = true
    ) -> PlaybackDecision {

        // The limit that actually applies: the stricter of the chosen level and the
        // measured line. Both can apply at the same time, and then neither
        // may be silently ignored.
        //
        // The measurement is translated into a level via ``StreamQuality/fitting(_:)``
        // and not taken directly as a number. The reason is stated there:
        // every level has a matching picture width, and a limit without a width
        // yields a picture made of blocks even though the number is right.
        let effective: StreamQuality =
            switch availableBitrate {
            case let measured?: quality.stricter(than: .fitting(measured))
            case nil: quality
            }

        // Does it apply? Determined first, applied only at the end to the
        // finished decision.
        let limitApplies: Bool = {
            guard let limit = effective.bitrate else { return false }
            // Unknown source rate means: could be anything. Whoever sets a limit
            // on the go wants it to be effective — when in doubt, the file is transcoded. The
            // opposite doubt costs a movie that buffers endlessly.
            guard let needed = source.bitrate else { return true }
            // A limit is a limit and not a target value: what lies below it
            // on its own stays untouched and is not scaled up.
            return needed > limit
        }()

        /// Applies the limit to a finished decision.
        ///
        /// Also over Dolby Vision, and that is a trade-off: transcoding loses
        /// the dynamic metadata, so the picture visibly gets
        /// worse. A picture that gets through is still worth more than a
        /// beautiful one that buffers — and whoever set the limit knows they are
        /// on the go.
        ///
        /// **The engine stays untouched, and so does the reason.** Both were
        /// different before and both were wrong. The engine: which one can open the file
        /// depends on subtitles and container, not on bandwidth — a
        /// switch here would lose the character-set subtitles on the go, and nobody
        /// would look for the cause at the line. The reason: it is stated explicitly
        /// in the result so that a wrong playback can be traced back. If
        /// it was set to `.bandwidthTooLow` here, the diagnostics claimed bandwidth
        /// on the go for **every** title — even where the subtitles had
        /// decided. That the limit took hold is now stated by
        /// ``PlaybackDecision/isBandwidthLimited``.
        func limited(_ decision: PlaybackDecision) -> PlaybackDecision {
            guard limitApplies else { return decision }
            // **With the native engine and a media server, the limit stays in the
            // chunking.** The values go into the URL of the same
            // playlist, and the server transcodes down within HLS —
            // even a file that was just playing directly unchanged. The
            // progressive transcoding path would be the end for Apple's engine: the stream
            // would arrive without range access and without length, and AVFoundation
            // fundamentally does not open that. Only VLC — and the edge case without a
            // media server — continue on ordinary transcoding.
            let limitedDelivery: Delivery = hasMediaServer ? .hls : .transcode
            return .init(
                engine: decision.engine,
                delivery: limitedDelivery,
                reason: decision.reason,
                maxBitrate: effective.bitrate,
                maxWidth: effective.maxWidth,
                isBandwidthLimited: true
            )
        }

        // **Which subtitles only VLC draws is decided by the format of the
        // chosen track — no longer by the worst format in the file.**
        //
        // Plain text (SRT/SubRip/VTT) the app fetches with a media server as a
        // WebVTT track, PGS as a raw bitmap track — it draws both itself
        // over the picture, without an engine switch. ASS/SSA lose their layout
        // in the conversion, the DVD bitmap formats have no raw delivery route; they
        // remain the case for VLC. Without a media server nobody converts or delivers,
        // there every non-VTT subtitle needs VLC as before.
        let subtitleNeedsOwnRenderer: Bool = {
            if let format = subtitleTrack?.subtitleFormat {
                if hasMediaServer {
                    // Whoever prefers plain text lets the server convert
                    // ASS/SSA as well — then Apple's engine carries them (roadmap
                    // P11). Bitmap formats are unaffected: they cannot
                    // be converted to text.
                    if prefersPlainSubtitles, format.isTextBased { return false }
                    return !format.isSelfRenderable
                }
                return format.needsOwnRenderer
            }
            // Without a named track the old, coarse question applies: does anyone want
            // subtitles, and does the file carry any that only VLC can handle?
            return wantsSubtitles
                && source.subtitleTracks.contains { $0.subtitleFormat?.needsOwnRenderer ?? false }
        }()

        /// Both in the order in which they apply: first the limit, then the
        /// start point. The other way round, the limit would undo the delivery route again.
        /// At the end come the settings that apply to every decision
        /// equally — the display's HDR capability and the
        /// chosen tracks: if they stood in every branch individually, they would
        /// eventually be missing from one.
        ///
        /// The track numbers go only into the chunking: with unchanged
        /// delivery and with VLC the engine itself chooses between the tracks
        /// of the file, a number in the URL would have no recipient there.
        func settled(_ decision: PlaybackDecision) -> PlaybackDecision {
            // **No more resume offset** (AP8): ``resuming(_:)`` applied
            // explicitly only to VLC and returned the decision unchanged for
            // everything else — since the removal, that is, always.
            // Apple's engine resumes by itself: with HLS the playlist covers
            // the full runtime, with unchanged delivery the server answers
            // range requests.
            let combined = limited(decision)
            let carriesTracks = combined.delivery == .hls
            // The subtitle does not depend on the delivery route: the app draws it
            // itself, so also over a file delivered unchanged.
            let carriesSubtitle = !subtitleNeedsOwnRenderer
            return .init(
                engine: combined.engine,
                delivery: combined.delivery,
                reason: combined.reason,
                maxBitrate: combined.maxBitrate,
                maxWidth: combined.maxWidth,
                isBandwidthLimited: combined.isBandwidthLimited,
                audioStreamIndex: carriesTracks ? audioTrack.flatMap { Int($0.id) } : nil,
                subtitleStreamIndex: carriesSubtitle
                    ? subtitleTrack.flatMap { Int($0.id) } : nil,
                displaySupportsHDR: displaySupportsHDR,
                startAt: max(0, startAt)
            )
        }

        // A chosen audio track that the device does not output (DTS, TrueHD)
        // forces the server route: there it transcodes exactly this track to AAC.
        // Delivered unchanged, it would simply stay silent — and a silent
        // title looks like a broken one, not like a format question.
        //
        // **Since 2026-09-04 with an exception**: what our own remuxer transcodes
        // (MPEG audio, DTS core) stays in the app, provided the file can be
        // remuxed at all. For DTS this is the reason for the whole
        // decoder: the server probes a DTS Matroska completely before the first
        // segment — Continue Watching therefore took half a minute.
        let chosenAudioNeedsServer: Bool = {
            guard hasMediaServer, let codec = audioTrack?.codec, !codec.isEmpty else {
                return false
            }
            let lowered = codec.lowercased()
            if MediaSource.nativeAudioCodecs.contains(lowered) { return false }
            if MediaSource.remuxableAudioCodecs.contains(lowered),
                canRemuxInApp(source, canDecodeHEVC: canDecodeHEVC)
            {
                return false
            }
            return true
        }()

        // **No more subtitle detour** (VLC removal 2026-08-16): character-set
        // and bitmap subtitles used to lead to the second engine. Now
        // this catalog also takes the normal route — what the native renderer
        // (ASS/PGS) can do is drawn; VobSub is on the roadmap as an AP0 remainder,
        // and the title plays without that one track in the meantime.

        if source.videoRange == .dolbyVision {
            // In the wrong container: with a media server chunked instead of progressively
            // remuxed. The codec list names hevc, so the server copies the picture
            // into the fMP4 segments — and a progressive remux stream
            // Apple's engine does not open anyway. Without a media server the old
            // route stays; nobody really remuxes there.
            //
            // If a chosen track requires the server — text subtitles into the
            // list, a foreign audio codec —, even a natively playable container goes
            // chunked: nothing can be attached to a file delivered unchanged,
            // and the subtitle would otherwise be missing without a word.
            let delivery: Delivery =
                if hasMediaServer, chosenAudioNeedsServer {
                    .hls
                } else if source.container.isNativelySupported {
                    .directPlay
                } else {
                    hasMediaServer ? .hls : .remux
                }
            return settled(
                .init(engine: .native, delivery: delivery, reason: .dolbyVisionNeedsNative)
            )
        }

        // **Everything that comes from a media server goes to Apple's engine.**
        //
        // Unchanged it gets only what is **proven** to fit: container, video codec and
        // audio codec must be known and native — see
        // ``MediaSource/isProvenNativelyPlayable``. The container alone has proven
        // a trap twice, both times with our own home videos: an MP4
        // with MPEG-4 Part 2 (the video codec of the DivX era) played the sound over
        // a black picture, and an MP4 with MP3 sound stayed silent. If the information is missing,
        // the same doubt applies: HLS with a copy costs the server almost nothing, a
        // black picture costs trust.
        //
        // Everything else comes chunked with fMP4 segments (see ``Delivery/hls``):
        // the server repackages what lies only in the wrong container, and transcodes
        // what the device cannot handle — it makes the decision itself based on the
        // codec lists in the URL. This is the route of Swiftfin and
        // jellyfin-web; the progressive fMP4 stream before it failed on AVFoundation
        // itself, see ``Delivery/hls``.
        //
        // Several audio tracks no longer hold this up. Over a repackaged stream
        // the track cannot be switched — but a title that runs smoothly
        // and seeks reliably outweighs a choice that most people never make.
        if hasMediaServer {
            // **H.264 at ten bits goes chunked to the server** — it transcodes
            // the picture, and Apple's engine plays the result (product decision
            // 2026-08-15: away from second engines, everything via the native route).
            // The first version of this branch sent Hi10P to VLC to spare the
            // server the transcoding; the viewer's rule weighs
            // more, and the server route also brings the clean
            // audio track selection with it — on which the German version
            // had failed with VLC. That the server really transcodes instead of copying
            // is ensured by the eight-bit condition in the device profile.
            if source.videoNeedsSoftwareDecoding {
                return settled(
                    .init(engine: .native, delivery: .hls, reason: .videoNeedsSoftwareDecoder)
                )
            }

            if source.isProvenNativelyPlayable, !chosenAudioNeedsServer {
                return settled(
                    .init(engine: .native, delivery: .directPlay, reason: .nativeContainer)
                )
            }

            // **The own remuxer comes before the server**, and this order
            // is the whole point of P19.
            //
            // It originally stood the other way round, and that made the work invisible:
            // every title from the library kept going to the server because
            // this branch hit first — measured 8.1 seconds to the picture,
            // while the remuxer needs 303 milliseconds for the same file
            // (viewer finding 2026-08-11, display `native/hls`). The remuxer ran
            // only where there is no server at all.
            //
            // **What nevertheless needs the server** still goes to it: an
            // audio track that the device does not output (DTS, TrueHD) — someone
            // has to transcode it, and only the server can.
            if !chosenAudioNeedsServer, canRemuxInApp(source, canDecodeHEVC: canDecodeHEVC) {
                return settled(
                    .init(engine: .native, delivery: .remuxInApp, reason: .remuxedInApp)
                )
            }
            // Three reasons for the same route, so that the diagnostics start the search
            // in the right place: if the container did not fit, it is named;
            // if it fit, the codecs decided — or a chosen
            // track that only the server can deliver.
            let reason: PlaybackDecision.Reason =
                if source.isProvenNativelyPlayable {
                    .trackChoiceNeedsServer
                } else if source.container.isNativelySupported {
                    .codecNotProvenNative
                } else {
                    .containerNotNativelySupported
                }
            return settled(.init(engine: .native, delivery: .hls, reason: reason))
        }

        // **Container AND video codec**, not just the container. An MP4 with
        // MPEG-4 Part 2 — the codec of DivX and Xvid — went to Apple's engine here,
        // which does not know it: it opened the file, showed nothing and reported no
        // error. The detailed reasoning is at ``MediaSource/isNativelyPlayable``.
        //
        // From here on it is only about sources **without** a media server — that is, channels
        // from a channel list. Nobody repackages for us there; if the provider
        // delivers HLS itself, Apple's engine opens it anyway.
        if source.isNativelyPlayable {
            return settled(.init(engine: .native, delivery: .directPlay, reason: .nativeContainer))
        }

        // **The container does not fit — but that no longer means "VLC".**
        //
        // Since 2026-08-10 the app repackages itself: picture and sound pass
        // through unchanged, only the wrapper is swapped, and Apple's
        // engine plays the result. The only condition is that the hardware can decode
        // picture **and** sound — where it cannot, repackaging does not help, and then
        // the second engine remains.
        if canRemuxInApp(source, canDecodeHEVC: canDecodeHEVC) {
            return settled(
                .init(engine: .native, delivery: .remuxInApp, reason: .remuxedInApp)
            )
        }

        // Several audio tracks are mentioned explicitly because the most common
        // mistake lurks here: the native engine could open the container after
        // repackaging, but the audio track would then be nailed down.
        if source.audioTracks.count > 1, source.supportsDirectPlay {
            return settled(
                .init(
                    engine: .native, delivery: .directPlay,
                    reason: .multipleAudioTracksStayDirect))
        }

        // **And here it ends — honest instead of silent** (AP32, 2026-09-11).
        //
        // From this line on: no media server (the branches above would have caught it),
        // Apple's engine does not know the container or the video codec, and our own
        // remuxer cannot take it over — otherwise `canRemuxInApp` would have been `true`.
        // **Only a server could transcode, and there is none.**
        //
        // Until today this returned `directPlay` or `transcode`: the one handed
        // the file unchanged to an engine that does not know it — it opened it,
        // showed nothing and reported nothing. The other named a delivery route for which
        // there is no supplier. **The choice knew and delivered anyway.**
        return settled(
            .init(engine: .native, delivery: .directPlay, reason: .notPlayable))
    }

    /// Whether the line about the missing video codec has already been written.
    ///
    /// The sentence names no channel and so does not distinguish the cases; its
    /// only variable part is `canDecodeHEVC`, and that comes via
    /// ``DeviceCapabilities`` from VideoToolbox — determined once at app start and
    /// unchangeable afterwards. On 2026-08-23 the line therefore appeared 131 times verbatim in the
    /// log, 2.5 % of the verbose block, without ever saying anything that was not
    /// already established. Once per process run is enough.
    ///
    /// The lock nevertheless sits on the **value** and not on a mere flag:
    /// it should not depend on the device question staying answered
    /// once and for all.
    private nonisolated(unsafe) static var hevcNote = NoiseGate<Bool>()

    /// ``canRemuxInApp(_:canDecodeHEVC:)`` has no storage on which a lock
    /// could hang — so it sits on the type. Unlike ``DebugMode/current``, however, this
    /// is also **written** here, and it is called from the UI as well as from the
    /// channel list, hence from more than one thread. That is why there is a lock.
    private static let hevcNoteLock = NSLock()

    private static func claimHEVCNote(_ canDecodeHEVC: Bool) -> Bool {
        hevcNoteLock.lock()
        defer { hevcNoteLock.unlock() }
        return hevcNote.admit(canDecodeHEVC)
    }

    /// For tests only: allows the line again.
    static func resetHEVCNote() {
        hevcNoteLock.lock()
        defer { hevcNoteLock.unlock() }
        hevcNote = NoiseGate<Bool>()
    }

    /// Whether our own remuxer can take over this source.
    ///
    /// **The question is about the hardware, not the container.** Remuxing swaps the
    /// wrapper and leaves picture and sound untouched; what the device cannot
    /// decode stays just as undecodable afterwards. MPEG-2 and AV1
    /// therefore drop out.
    ///
    /// **For audio this has no longer applied literally since 2026-09-04**, and here it
    /// still said "DTS and TrueHD likewise": what the remuxer transcodes itself, the
    /// hardware does not need to output at all — MPEG audio via ``MPEGAudioTranscoder``,
    /// the DTS core via ``DTSTranscoder``. The list for this is
    /// ``MediaSource/remuxableAudioCodecs``, and it is wider than the native one.
    /// **TrueHD stays out** and is the reason the sentence does not simply
    /// disappear: there is no decoder for it in the app, and the title goes to
    /// the server.
    ///
    /// And the containers for which there are readers: MKV and MPEG-TS. For everything
    /// else — AVI, WebM — there is none, and a remuxer without a reader would be
    /// a promise that is kept nowhere.
    public static func canRemuxInApp(_ source: MediaSource, canDecodeHEVC: Bool = true) -> Bool {
        guard source.container == .mkv || source.container == .ts else {
            Diagnostics.verbose("Remux: container \(source.container.rawValue) has no reader")
            return false
        }
        // **Here it said `supportsDirectPlay`, and that was the logical error.**
        //
        // This flag is the server's answer to the question "can **your
        // player** play this?" — and for Matroska it says no, because it
        // knows the device profile. Exactly for that reason every title in the library
        // kept going through the server: the condition was always false (viewer finding
        // 2026-08-11, display "native/hls · containerNotNativelySupported" for a
        // file made of MKV, H.264 and AAC).
        //
        // But we do not play the file, we **read** it — and for that it
        // suffices that the server hands it out unchanged. It does so via
        // `static=true`, whatever it thinks about the player.
        //
        // **And if nothing arrives after all, it falls back softly:** ``MatroskaFileSession``
        // throws, and the player takes the old route again.
        // Interlacing rules out the native route anyway.
        guard source.isInterlaced != true else {
            Diagnostics.verbose("Remux: interlaced")
            return false
        }

        // **The hardware cannot do H.264 at ten bits** — the codec name
        // conceals that (device finding 2026-08-15: Woujeinspes Skutgro, `h264`
        // High 10 — the remuxer delivered a stream that AVFoundation
        // accepts and never decodes). Detailed reasoning at
        // ``MediaSource/videoNeedsSoftwareDecoding``.
        guard !source.videoNeedsSoftwareDecoding else {
            Diagnostics.verbose(
                "Remux: hardware cannot do H.264 at \(source.videoBitDepth ?? 0) bit")
            return false
        }

        // **A channel does not state its video codec** — it is only established once
        // the stream is running. Trying is still allowed, but only on a
        // device that can decode everything that might arrive. Where HEVC is missing,
        // it would be a gamble with a black picture as the loss; there
        // the second engine remains, which decodes it in software.
        guard let codec = source.videoCodec, !codec.isEmpty else {
            // The switch is queried **before** the lock, although
            // ``Diagnostics/verbose(_:since:)`` already checks it itself: otherwise
            // the lock uses up its one slot while nothing is being
            // recorded — and if the viewer flips the switch in the middle of
            // the session, the line would never appear again. Exactly the kind of
            // throttling that throws away the incident being looked for.
            if DebugMode.current.isOn, Self.claimHEVCNote(canDecodeHEVC) {
                // The wording now also says what follows from the answer —
                // previously you had to read the next line for that.
                Diagnostics.verbose(
                    "Remux: channel without a video codec entry — HEVC-capable=\(canDecodeHEVC), "
                        + "it is \(canDecodeHEVC ? "tried anyway" : "not remuxed")")
            }
            return canDecodeHEVC
        }

        let lowered = codec.lowercased()
        guard MediaSource.nativeVideoCodecs.contains(lowered) else {
            Diagnostics.verbose("Remux: hardware cannot do video codec \(lowered)")
            return false
        }
        // **The device is asked, not the list.** The list says what
        // Apple's engine can do in principle; whether **this** device also
        // decodes it is answered by VideoToolbox. The difference is not
        // theoretical: an Apple TV of the HD line cannot do HEVC, and the
        // simulator cannot either. Repackaged, the channel would stay black there —
        // while the second engine decodes it in software and thereby shows it
        // (viewer finding 2026-08-10: "HEVC and 4K channels no longer work at all").
        guard canDecodeHEVC || !MediaSource.hevcCodecs.contains(lowered) else {
            Diagnostics.verbose("Remux: HEVC, but this device does not decode it")
            return false
        }

        // **Without named audio tracks it is attempted.** With a channel they
        // are only established on opening; the remuxer then looks for itself and
        // leaves out what it cannot handle.
        guard !source.audioTracks.isEmpty else { return true }
        let usable = source.audioTracks.contains { track in
            guard let codec = track.codec, !codec.isEmpty else { return true }
            // The wide list: the remuxer transcodes MPEG audio itself.
            return MediaSource.remuxableAudioCodecs.contains(codec.lowercased())
        }
        if !usable {
            Diagnostics.verbose(
                "Remux: no usable audio track — \(source.audioTracks.compactMap(\.codec))")
        }
        return usable
    }
}
