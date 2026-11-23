import Testing

@testable import Core

/// The engine choice is the most consequential rule in the app: a mistake here means
/// the server spends hours transcoding although the file could be played directly
/// — or that subtitles are missing. That is why every branch is covered individually.
@Suite("Playback engine selection")
struct PlaybackEngineSelectorTests {

    /// Rebuilt from a real episode of the media library: MKV, H.264, three AAC audio
    /// tracks, two subtitle tracks in ASS format.
    static var animeEpisode: MediaSource {
        MediaSource(
            container: .mkv,
            videoCodec: "h264",
            audioTracks: [
                .init(id: "1", kind: .audio, title: "German", language: "deu", codec: "aac"),
                .init(id: "2", kind: .audio, title: "English", language: "eng", codec: "aac"),
                .init(id: "3", kind: .audio, title: "Japanese", language: "jpn", codec: "aac"),
            ],
            subtitleTracks: [
                .init(id: "4", kind: .subtitle, title: "German", language: "deu", subtitleFormat: .ass),
                .init(id: "5", kind: .subtitle, title: "English", language: "eng", subtitleFormat: .ass),
            ]
        )
    }

    /// Rebuilt from a home video: MP4, H.264, one audio track, no subtitles.
    static var homeVideo: MediaSource {
        MediaSource(
            container: .mp4,
            videoCodec: "h264",
            audioTracks: [.init(id: "1", kind: .audio, title: "Ton", codec: "aac")]
        )
    }

    @Test("An MP4 with a foreign video codec is recognized as unplayable")
    func mp4WithNonNativeCodecIsRecognized() {
        // **Found in our own catalog.** A home video is an MP4 and therefore went to the
        // native engine — but its picture is MPEG-4 Part 2, the codec of DivX and Xvid, as
        // older cameras and converters write it. Apple's engine does not know it: it opens
        // the file, shows nothing and reports no error. Eighteen gigabytes of family video
        // that "could not be played".
        let camcorder = MediaSource(
            container: .mp4,
            videoCodec: "mpeg4",
            audioTracks: [.init(id: "1", kind: .audio, title: "Ton", codec: "aac")]
        )
        // **The reason is checked, not the engine** (AP8, added 2026-09-02): since VLC was
        // removed there is only one engine, and the old assertion `engine == .native` was
        // true no matter what was in the file. The reason, by contrast, really separates
        // the cases.
        //
        // **And since AP32 (2026-09-11) the reason says what it means.** It used to be
        // `containerNotNativelySupported` — but the container is MP4, which is perfectly
        // fine. The problem was not the container but that **nobody** can play this file:
        // Apple's engine does not know the codec, our own remuxer does not take it on,
        // and without a media server nobody transcodes. The name of the check said so all
        // along; the expected value did not.
        let choice = PlaybackEngineSelector.decide(for: camcorder)
        #expect(choice.reason == .notPlayable)
        #expect(choice.isDeadEnd)

        // The control case: the same shell with a codec Apple supports counts as native —
        // there, hardware decoding and AirPlay matter.
        #expect(PlaybackEngineSelector.decide(for: Self.homeVideo).reason == .nativeContainer)

        // Without codec information it stays with the container. That is the case for a
        // channel whose tracks are only known once it is opened: there the address is the
        // only thing we have, and a suspicion would be no better basis.
    }

    @Test("A start offset applies on EVERY VLC path through the rule")
    func everyVLCPathCarriesTheStartOffset() {
        // **This test case came from a bug that looked exactly like no bug.** The start
        // point was set at four return sites — at three of them. The fourth, the path for
        // MKV with several audio tracks, was left out: it is the only one at function
        // level instead of inside an `if`, and so it had a different indentation from the
        // others. That is why this case checks not one path but all the paths on which VLC
        // comes out.
        //
        // Only the VLC paths remain: on a raw-read Matroska, VLC's jump depends on the
        // seek index at the end of the file and does not reliably work — there the server
        // starts further ahead. Apple's engine, by contrast, resumes by itself; its paths
        // are in the case below.
        // **Of the two paths, one was dropped on 2026-08-10**
        //
        // Without visible subtitles the app now remuxes by itself: the container does not
        // suit Apple's engine, but the hardware can handle picture and sound. Then the
        // player jumps itself — the playlist covers the full duration, every segment can
        // be fetched individually, and a start point for the server would be an order to
        // someone who has nothing to do with it.
        let remuxed = PlaybackEngineSelector.decide(
            for: Self.animeEpisode, wantsSubtitles: false, startAt: 875)
        #expect(remuxed.delivery == .remuxInApp)

        // **With subtitles it stays with VLC — without a media server.** There nobody
        // extracts the track; the app does read the file, but the subtitles inside it are
        // not wired up yet. And for VLC the start point still applies: its jump depends on
        // a seek index at the end of the file and does not reliably work on a raw-read
        // Matroska.
        let withSubtitles = PlaybackEngineSelector.decide(
            for: Self.animeEpisode, wantsSubtitles: true, startAt: 875)
        #expect(
            withSubtitles.delivery != .directPlay,
            "without its own jump the server only has a grip when remuxing")
    }

    @Test("Apple's engine resumes by itself — no server offset on its paths")
    func nativePathsResumeAtThePlayer() {
        // The reverse of the old path, and it is verified in the simulator: the
        // progressive remux stream that a server offset requires cannot be opened by
        // AVFoundation at all (`Accept-Ranges: none`, no length). With HLS the list covers
        // the full duration and would start at zero despite `StartTimeTicks`. So the
        // player jumps — with direct playback via range requests, with HLS via the target
        // segment.
        let paths: [(String, MediaSource)] = [
            ("Heimvideo in MP4", Self.homeVideo),
            ("Dolby Vision in MP4", MediaSource(container: .mp4, videoRange: .dolbyVision)),
        ]

        for (name, source) in paths {
            let decision = PlaybackEngineSelector.decide(for: source, startAt: 875)

            #expect(decision.delivery == .directPlay, "\(name): the delivery path stays untouched")
        }
    }

    @Test("Without a start offset the delivery path stays untouched")
    func withoutOffsetNothingChanges() {
        // The control case to the case above — and since 2026-08-10 it comes out the same way:
        // remuxing happens in the app, with or without a start point, because it costs the
        // server nothing.
        let decision = PlaybackEngineSelector.decide(for: Self.animeEpisode)
        #expect(decision.delivery == .remuxInApp)
    }

    @Test("If the source cannot deliver at an offset, it stays on direct play")
    func offsetIsIgnoredWhereTheSourceCannot() {
        // An IPTV provider delivers finished files and knows no start point. If remuxing
        // were done here anyway, the app would request a delivery path that nobody
        // serves — and lose direct operation for nothing. There the player jumps itself;
        // the movies of the tested provider answer partial requests.
        let decision = PlaybackEngineSelector.decide(
            for: Self.animeEpisode,
            startAt: 875,
            sourceCanStartAtOffset: false
        )
        #expect(decision.delivery == .remuxInApp)
    }

    // MARK: - The path via a media server
    //
    // **Everything below describes the rule without a media server.** It still applies
    // and is still correct: it answers the question which engine can *open* a file if
    // it arrives unchanged — for an IPTV provider, for example.
    //
    // If a media server stands behind it, however, it no longer applies, because then
    // there is a third possibility: it delivers the title as a continuous fMP4 and
    // transcodes whatever the device cannot handle — the way UHF is proven to run on
    // the same server. Stuttering, missing seeking via the bar and unreliable resuming
    // were the complaints the rebuild started with.
    //
    // The switch for this is called ``PlaybackEngineSelector/decide(for:…hasMediaServer:)``
    // and is **off by default**. That is deliberate: an earlier attempt used
    // `sourceCanStartAtOffset`, which defaults to `true` — so every caller got the
    // server path, including the Xtream provider, where nobody remuxes.

    /// **Since 2026-08-11 our own remuxer sits in front of the server**, and that is the
    /// whole point of P19: for the same file the server needed 8.1 seconds until the
    /// first picture, the remuxer 303 milliseconds. The order used to be the other way
    /// round, and so the remuxer ran only where there is no server at all — the work
    /// was built and invisible.
    @Test("With a media server the app remuxes itself instead of letting it segment")
    func mediaServerPrefersInAppRemux() {
        let decision = PlaybackEngineSelector.decide(
            for: Self.animeEpisode,
            hasMediaServer: true
        )

        #expect(decision.delivery == .remuxInApp)
        #expect(decision.reason == .remuxedInApp)
    }

    /// **What the server still has to do, it keeps doing.** An audio track the device
    /// does not output can only be converted by the server — remuxed, it would stay
    /// silent, and a silent title looks like a broken one. Since 2026-09-04. TrueHD stands
    /// here instead of DTS: the app now decodes DTS itself (``DTSSelectorTests``).
    @Test("An audio track the device cannot output stays with the server")
    func unsupportedAudioStaysWithTheServer() {
        var source = Self.animeEpisode
        source.audioTracks = [
            MediaTrack(id: "1", kind: .audio, title: "TrueHD", language: "deu", codec: "truehd")
        ]
        let decision = PlaybackEngineSelector.decide(
            for: source,
            audioTrack: source.audioTracks[0],
            hasMediaServer: true
        )

        #expect(decision.delivery == .hls)
    }

    @Test("Subtitles only VLC can render also beat the media server")
    func subtitlesBeatTheMediaServer() {
        // VLC is the silent fallback for exactly this case: Apple's engine does not render
        // ASS and image subtitles, and without this precedence they would simply be gone
        // on the fMP4 path — with no message and no recognizable reason.
        let decision = PlaybackEngineSelector.decide(
            for: Self.animeEpisode,
            wantsSubtitles: true,
            hasMediaServer: true
        )

        #expect(decision.delivery == .remuxInApp)
        #expect(decision.reason == .remuxedInApp)
    }

    @Test("What the engine opens anyway stays untouched even with a media server")
    func mediaServerKeepsDirectPlayForNativeFiles() {
        // Remuxing costs the server one ffmpeg run per playback. For an MP4 with a
        // matching picture and sound that buys nothing — the file goes raw to the engine.
        let decision = PlaybackEngineSelector.decide(for: Self.homeVideo, hasMediaServer: true)

        #expect(decision.delivery == .directPlay)
    }

    @Test("Foreign audio forces even an MP4 onto the segmented path")
    func foreignAudioForcesHLS() {
        // An Apple TV does not output DTS. Delivered unchanged, the title would stay
        // silent — the server has to touch the audio, and it can do so only on the path
        // where it repackages the stream anyway.
        let dts = MediaSource(
            container: .mp4,
            videoCodec: "h264",
            audioTracks: [.init(id: "1", kind: .audio, title: "Ton", codec: "dts")]
        )
        let decision = PlaybackEngineSelector.decide(for: dts, hasMediaServer: true)

        #expect(decision.delivery == .hls)
        // The container fit — the diagnosis should name the codecs, not it.
        #expect(decision.reason == .codecNotProvenNative)
    }

    @Test("A DivX-era MP4 goes segmented — the \"audio without picture\" case")
    func divxEraVideoUsesHLS() {
        // Verified with ffprobe on our own server: a family video file, picture MPEG-4
        // Simple Profile at 1920×1080, audio AAC. Delivered unchanged, Apple's engine
        // played the sound and left the picture black — without an error message.
        // Segmented, the address names h264 and hevc, so the server really does transcode
        // the picture and copies the audio.
        let camcorder = MediaSource(
            container: .mp4,
            videoCodec: "mpeg4",
            audioTracks: [.init(id: "1", kind: .audio, title: "Ton", codec: "aac")]
        )
        let decision = PlaybackEngineSelector.decide(for: camcorder, hasMediaServer: true)

        #expect(decision.delivery == .hls)
        #expect(decision.reason == .codecNotProvenNative)
    }

    @Test("MP3 in an MP4 goes segmented — delivered directly, the audio drops out")
    func mp3InMP4UsesHLS() {
        // The twenty-two old phone videos in the catalog: H.264 at 352×288, audio MP3 at
        // 44.1 kHz. Apple's engine plays MP3 **files**, but not MP3 in an MP4 container —
        // Swiftfin lists the pairing in its native profile for mov and mpegts, explicitly
        // not for mp4, and on our own device the sound stayed missing. The server converts
        // MP3 to AAC cheaply; the HLS codec list therefore stays without mp3, so that no
        // segment special case arises.
        let phoneVideo = MediaSource(
            container: .mp4,
            videoCodec: "h264",
            audioTracks: [.init(id: "1", kind: .audio, title: "Ton", codec: "mp3")]
        )
        let decision = PlaybackEngineSelector.decide(for: phoneVideo, hasMediaServer: true)

        #expect(decision.delivery == .hls)
        #expect(decision.reason == .codecNotProvenNative)
    }

    @Test("Missing codec info with a media server means: segmented when in doubt")
    func missingCodecInfoUsesHLSOnTheMediaServer() {
        // Without information, direct playback would be a bet on the container — and that
        // bet was lost twice on the home videos. HLS with copy costs the server almost
        // nothing; a black picture costs trust.
        let bare = MediaSource(container: .mp4)
        let bareDecision = PlaybackEngineSelector.decide(for: bare, hasMediaServer: true)
        #expect(bareDecision.delivery == .hls)
        #expect(bareDecision.reason == .codecNotProvenNative)

        // Audio without a name is also a doubt, not a free pass.
        let unknownAudio = MediaSource(
            container: .mp4,
            videoCodec: "h264",
            audioTracks: [.init(id: "1", kind: .audio, title: "Ton")]
        )
        #expect(
            PlaybackEngineSelector.decide(for: unknownAudio, hasMediaServer: true).delivery == .hls
        )

        // The distinction: no audio track at all is not a doubt but a silent film — the
        // track list did arrive, otherwise the picture would be missing as well.
        let silent = MediaSource(container: .mp4, videoCodec: "h264")
        #expect(
            PlaybackEngineSelector.decide(for: silent, hasMediaServer: true).delivery == .directPlay
        )
    }

    @Test("Resuming with a media server stays HLS — and the start offset stays with the player")
    func mediaServerResumeStaysAtThePlayer() {
        // The playlist covers the full duration; the player jumps itself after opening. A
        // `StartTimeTicks` in the address would be the return of the verified bug: the list
        // started at zero anyway, only the display believed something else — the movie
        // played from the beginning while the bar stood in the middle.
        let decision = PlaybackEngineSelector.decide(
            for: Self.animeEpisode,
            startAt: 875,
            hasMediaServer: true
        )

        // Remuxed instead of segmented since 2026-08-11 — that changes nothing about the start
        // point: Apple's engine jumps itself in both cases.
        #expect(decision.delivery == .remuxInApp)
    }

    @Test("Dolby Vision in a foreign container goes segmented with a media server")
    func dolbyVisionUsesHLSOnTheMediaServer() {
        // The codec list names hevc — the server copies the picture into the fMP4
        // segments, the metadata survives. The earlier progressive remux path could not be
        // opened by AVFoundation at all.
        let source = MediaSource(container: .mkv, videoCodec: "hevc", videoRange: .dolbyVision)
        let decision = PlaybackEngineSelector.decide(for: source, hasMediaServer: true)

        #expect(decision.delivery == .hls)
        #expect(decision.reason == .dolbyVisionNeedsNative)
    }

    @Test("A bandwidth limit stays inside the segmentation on the native engine")
    func bandwidthLimitStaysInsideHLS() {
        // The limit moves into the address of the same playlist — the server transcodes
        // down within HLS. A switch to the progressive transcode path would be the end:
        // Apple's engine fundamentally does not open it.
        var source = Self.homeVideo
        source.bitrate = 60_000_000
        let decision = PlaybackEngineSelector.decide(
            for: source,
            quality: .low,
            hasMediaServer: true
        )

        #expect(decision.delivery == .hls)
        #expect(decision.isBandwidthLimited)
        #expect(decision.maxBitrate == 2_000_000)
    }

    @Test("Without a media server the old rule applies")
    func withoutMediaServerNothingChanges() {
        // The control case, and the more important of the two: a channel or an Xtream
        // title still gets VLC. An address with remux instructions would go nowhere there,
        // and on the device the error could not be told apart from a dead channel.
        let decision = PlaybackEngineSelector.decide(for: Self.animeEpisode, wantsSubtitles: true)

        #expect(decision.delivery == .remuxInApp)
    }

    @Test("An anime episode with character-set subtitles goes to VLC and plays directly")
    func animeWithSubtitles() {
        let decision = PlaybackEngineSelector.decide(for: Self.animeEpisode, wantsSubtitles: true)

        #expect(decision.delivery == .remuxInApp)
        #expect(decision.reason == .remuxedInApp)
    }

    /// **Until 2026-08-10 this was the case "three audio tracks, therefore VLC".** The
    /// argument was: after remuxing the audio track choice would be lost, because an
    /// fMP4 stream carries only the tracks that were registered at setup.
    ///
    /// It still applies — the choice just happens earlier now: ``MatroskaRemuxer``
    /// receives the preferred language and takes the matching track instead of taking
    /// all of them and letting the engine choose.
    @Test("An anime episode with three audio tracks is remuxed by the app itself")
    func animeWithoutSubtitles() {
        let decision = PlaybackEngineSelector.decide(for: Self.animeEpisode, wantsSubtitles: false)

        #expect(decision.delivery == .remuxInApp)
        #expect(decision.reason == .remuxedInApp)
    }

    @Test("Home video runs on the native engine")
    func homeVideoNative() {
        let decision = PlaybackEngineSelector.decide(for: Self.homeVideo)

        #expect(decision.delivery == .directPlay)
        #expect(decision.reason == .nativeContainer)
    }

    @Test("Dolby Vision forces the native engine and is remuxed in a foreign container")
    func dolbyVisionRemux() {
        let source = MediaSource(container: .mkv, videoCodec: "hevc", videoRange: .dolbyVision)
        let decision = PlaybackEngineSelector.decide(for: source)

        #expect(decision.delivery == .remux, "remux instead of transcode — the picture stays untouched")
        #expect(decision.reason == .dolbyVisionNeedsNative)
    }

    @Test("Dolby Vision in a matching container needs no remux")
    func dolbyVisionDirect() {
        let source = MediaSource(container: .mp4, videoRange: .dolbyVision)
        let decision = PlaybackEngineSelector.decide(for: source)

        #expect(decision.delivery == .directPlay)
    }

    /// **The transport stream now also stays with Apple's engine** — it is remuxed in
    /// the app instead of fetching a second engine. Without codec information it is
    /// attempted: for a channel they only become known on opening, and the remuxer then
    /// looks for itself.
    @Test("Live channels run natively — as HLS and as a transport stream")
    func liveChannels() {

        let stream = PlaybackEngineSelector.decide(for: MediaSource(container: .ts))
        #expect(stream.delivery == .remuxInApp)

        // What the hardware cannot decode is not rescued by remuxing either: the channel
        // then goes out unchanged and has to try by itself. **This used to say
        // `engine == .native`** and has been always true since VLC was removed; the
        // warning gate from AP15 found the orphaned line (2026-09-02).
        let mpeg2 = PlaybackEngineSelector.decide(
            for: MediaSource(container: .ts, videoCodec: "mpeg2video"))
        #expect(mpeg2.delivery == .directPlay)
        #expect(mpeg2.delivery != .remuxInApp, "remuxing does not help without a decoder")
    }

    @Test("Image-based Blu-ray subtitles need VLC")
    func imageBasedSubtitles() {
        let source = MediaSource(
            container: .mkv,
            subtitleTracks: [.init(id: "1", kind: .subtitle, title: "Deutsch", subtitleFormat: .pgs)]
        )
        let decision = PlaybackEngineSelector.decide(for: source, wantsSubtitles: true)

        #expect(decision.reason == .remuxedInApp)
    }

    @Test("Timed text does not stop the native engine")
    func textSubtitlesStayNative() {
        let source = MediaSource(
            container: .mp4,
            subtitleTracks: [.init(id: "1", kind: .subtitle, title: "Deutsch", subtitleFormat: .vtt)]
        )
        let decision = PlaybackEngineSelector.decide(for: source, wantsSubtitles: true)

        #expect(decision.delivery == .directPlay)
        #expect(decision.reason == .nativeContainer)
    }

    @Test("If the connection is too slow, it transcodes — otherwise it only buffers")
    func lowBandwidth() {
        // The measured values: the file needs about 5.2 Mbit/s, 0.3 Mbit/s arrived through
        // the tunnel.
        var source = Self.animeEpisode
        source.bitrate = 5_200_000

        let decision = PlaybackEngineSelector.decide(for: source, availableBitrate: 300_000)

        #expect(decision.delivery == .transcode)
        #expect(decision.isBandwidthLimited)

        // The reason stays with the ENGINE and is not overwritten by the bandwidth. They
        // are different questions: why this engine, and why transcoded. Written into one
        // field, the diagnosis claimed bandwidth for every title on the road, even where
        // the container had decided — and the next troubleshooting started in the wrong
        // place.
        #expect(decision.reason != .bandwidthTooLow)

        // And the limit is passed along explicitly. It was missing here before: the
        // stream was transcoded, but without an upper limit, and the server picked a rate
        // of the size of the source — it kept buffering.
        #expect(decision.maxBitrate != nil)
        #expect(decision.maxWidth != nil)
    }

    @Test("If the connection suffices, it stays on direct play")
    func enoughBandwidth() {
        var source = Self.animeEpisode
        source.bitrate = 5_200_000

        // Im Heimnetz gemessen: rund 286 Mbit/s.
        let decision = PlaybackEngineSelector.decide(for: source, availableBitrate: 286_000_000)

        #expect(decision.delivery == .remuxInApp)
    }

    /// **"Directly playable" is not the same as "readable", and that was the most
    /// expensive misjudgment of this stage.**
    ///
    /// The flag is the server's answer to the question "can **your player** play this?".
    /// For Matroska the answer is no — it knows the device profile. As long as it
    /// blocked remuxing, every title of the media library kept going through the
    /// server: 14.9 seconds instead of 300 milliseconds, for a file of MKV, H.264 and
    /// AAC (viewer finding 2026-08-11).
    ///
    /// The file is read unchanged via `static=true`, no matter what the server thinks
    /// about the player. If nothing comes of that after all, the session throws, and the
    /// player takes the old path again.
    @Test("Readable is not playable: remuxing happens even without direct play")
    func directPlayFlagDoesNotBlockRemuxing() {
        var source = Self.animeEpisode
        source.supportsDirectPlay = false

        #expect(PlaybackEngineSelector.decide(for: source).delivery == .remuxInApp)
        #expect(
            PlaybackEngineSelector.decide(for: source, hasMediaServer: true).delivery
                == .remuxInApp)
    }

    @Test("Container identifiers are recognized, including spelling variants")
    func containerParsing() {
        #expect(MediaSource.Container(rawValue: "x-matroska") == .mkv)
        #expect(MediaSource.Container(rawValue: "MKV") == .mkv)
        #expect(MediaSource.Container(rawValue: "mpegts") == .ts)
        #expect(MediaSource.Container(rawValue: "m3u8") == .hls)
        #expect(MediaSource.Container(rawValue: "quatsch") == .unknown)
    }

    @Test("Subtitle formats are distinguished by renderability")
    func subtitleParsing() {
        #expect(MediaSource.SubtitleFormat(rawValue: "hdmv_pgs_subtitle") == .pgs)
        #expect(MediaSource.SubtitleFormat(rawValue: "webvtt") == .vtt)
        #expect(MediaSource.SubtitleFormat(rawValue: "ass").needsOwnRenderer)
        #expect(!MediaSource.SubtitleFormat(rawValue: "ttml").needsOwnRenderer)
    }
}

/// The self-imposed limit applies last and changes only the delivery path. It is the
/// only way to see anything at all while on the road — if it does not take effect,
/// the setting is a display without effect, and that only becomes apparent when the
/// movie buffers on the train.
@Suite("Playback with a bandwidth limit set")
struct PlaybackEngineSelectorQualityTests {

    /// The same episode as in the engine choice, here with a measured rate: 5.2 Mbit/s.
    static var episode: MediaSource {
        var source = PlaybackEngineSelectorTests.animeEpisode
        source.bitrate = 5_200_000
        return source
    }

    @Test("Without a limit the decision carries no cap")
    func withoutLimit() {
        // A value instead of nothing would let the server transcode on the home network too.
        let decision = PlaybackEngineSelector.decide(for: Self.episode)

        #expect(decision.maxBitrate == nil)
        #expect(decision.maxWidth == nil)
        #expect(decision.delivery == .remuxInApp)
    }

    @Test("A limit above the source rate leaves the file untouched")
    func limitAboveSource() {
        // A limit is a limit and not a target value. If transcoding happened here, one would
        // lose quality and audio tracks without saving a single byte.
        let decision = PlaybackEngineSelector.decide(for: Self.episode, quality: .veryHigh)

        #expect(decision.delivery == .remuxInApp)
        #expect(decision.maxBitrate == nil)
    }

    @Test("A limit below the source rate transcodes and records both values")
    func limitBelowSource() {
        let decision = PlaybackEngineSelector.decide(for: Self.episode, quality: .low)

        #expect(decision.delivery == .transcode)
        #expect(decision.isBandwidthLimited)
        #expect(decision.maxBitrate == 2_000_000)
        // Without the width the server squeezes 1080p into two Mbit/s — a picture made of
        // blocks, although 720p looks clean at the same amount of data.
        #expect(decision.maxWidth == 1280)
    }

    @Test("With an unknown source rate the limit applies as well")
    func limitWithUnknownSourceRate() {
        // The server does not always report the rate. Unknown can mean anything, and whoever
        // sets a limit on the road wants it to be effective — when in doubt, transcode. The
        // opposite doubt costs the whole movie.
        var source = Self.episode
        source.bitrate = nil

        let decision = PlaybackEngineSelector.decide(for: source, quality: .minimal)

        #expect(decision.delivery == .transcode)
        #expect(decision.maxBitrate == 500_000)
        #expect(decision.maxWidth == 854)
    }

    @Test("The limit beats Dolby Vision")
    func limitBeatsDolbyVision() {
        // Transcoding loses the dynamic metadata, so the picture visibly gets worse. A
        // picture that gets through is still worth more than a beautiful one that buffers.
        let source = MediaSource(
            container: .mp4,
            videoCodec: "hevc",
            videoRange: .dolbyVision,
            bitrate: 60_000_000
        )
        let decision = PlaybackEngineSelector.decide(for: source, quality: .medium)

        #expect(decision.delivery == .transcode)
        #expect(decision.maxBitrate == 4_000_000)
        // The engine stays the native one: it can play the transcoded stream with hardware
        // decoding, Picture in Picture and AirPlay, and the bandwidth changes nothing about
        // that.
    }

    @Test("The limit does not change the engine")
    func limitKeepsEngine() {
        // The most important case of the whole rule: only VLC can render character-set
        // subtitles. If the limit also co-determined the engine, the subtitles would
        // vanish as soon as one sets a limit on the road — with a cause that nobody looks
        // for in the bandwidth.
        let decision = PlaybackEngineSelector.decide(
            for: Self.episode,
            wantsSubtitles: true,
            quality: .low
        )

        #expect(decision.delivery == .transcode)
        #expect(decision.maxBitrate == 2_000_000)

        // And the other way round: the home video stays with the native engine.
        let native = PlaybackEngineSelector.decide(
            for: PlaybackEngineSelectorTests.homeVideo,
            quality: .low
        )
        #expect(native.delivery == .transcode)
    }

    @Test("Automatic and a manual limit together yield the manual limit")
    func automaticAndManualTogether() {
        // Without this case the setting disappears exactly when it is needed: the automatic
        // mode detects the narrow line and transcodes — but without an upper limit, and the
        // server picks a rate that does not get through.
        let decision = PlaybackEngineSelector.decide(
            for: Self.episode,
            availableBitrate: 300_000,
            quality: .minimal
        )

        #expect(decision.delivery == .transcode)
        #expect(decision.isBandwidthLimited)
        #expect(decision.maxBitrate == 500_000)
        #expect(decision.maxWidth == 854)
    }

    @Test("If the server cannot deliver directly, the limit still stands")
    func limitSurvivesForcedTranscode() {
        var source = Self.episode
        source.supportsDirectPlay = false

        // Transcoding happens anyway — but without the values with the rate of the source,
        // and that does not get through on the road.
        let decision = PlaybackEngineSelector.decide(for: source, quality: .low)

        #expect(decision.delivery == .transcode)
        #expect(decision.maxBitrate == 2_000_000)
    }

    /// **The engine preference is no longer part of the call** (AP8, 2026-09-02): it was
    /// accepted by ``PlaybackEngineSelector/decide`` and **never once** read in the
    /// body. The subject under test here is a different one and stays.
    @Test("The display's HDR capability survives limit and start offset")
    func hdrCapabilityReachesEveryDecision() {
        // It is laid over the finished decision last — if it stood in each branch
        // individually, it would at some point be missing in one, and the bug would look
        // like a device problem: Dolby Vision flickered only with exactly the combination
        // of bandwidth limit and resuming that hits the branch without the setting.
        var source = Self.episode
        source.supportsDirectPlay = false

        let decision = PlaybackEngineSelector.decide(
            for: source,
            quality: .low,
            startAt: 300,
            displaySupportsHDR: true
        )
        #expect(decision.displaySupportsHDR)

        let plain = PlaybackEngineSelector.decide(for: Self.episode, hasMediaServer: true)
        #expect(!plain.displaySupportsHDR)
    }

    // MARK: - Chosen tracks

    /// Rebuilt from "K for Kestrel": MKV with AC3 audio and one SubRip subtitle —
    /// plain text, no character-set layout.
    static var movieWithTextSubtitle: MediaSource {
        MediaSource(
            container: .mkv,
            videoCodec: "h264",
            audioTracks: [
                .init(id: "5", kind: .audio, title: "Deutsch", language: "deu", codec: "ac3"),
                .init(id: "7", kind: .audio, title: "English", language: "eng", codec: "ac3"),
            ],
            subtitleTracks: [
                .init(
                    id: "6", kind: .subtitle, title: "Deutsch", language: "deu",
                    codec: "subrip", subtitleFormat: .subrip
                )
            ]
        )
    }

    @Test("A chosen text subtitle travels as a track number into the segmentation")
    func chosenTextSubtitleRidesTheStream() {
        // Plain text no longer needs VLC: the app fetches the track as WebVTT from the
        // server and draws it itself over the picture. The track number in the decision
        // says which track to fetch — the stream itself carries no subtitles.
        let subtitle = Self.movieWithTextSubtitle.subtitleTracks[0]
        let decision = PlaybackEngineSelector.decide(
            for: Self.movieWithTextSubtitle,
            subtitleTrack: subtitle,
            hasMediaServer: true
        )

        #expect(decision.delivery == .remuxInApp)
        // The track number stays in the decision: the app fetches the track separately and
        // draws it itself — whether the stream is segmented by the server or remuxed here.
        #expect(decision.subtitleStreamIndex == 6)
    }

    @Test("A chosen ASS subtitle is drawn by the app")
    func chosenASSSubtitleIsDrawnByTheApp() {
        // **Until 2026-08-10 this case went to VLC**, because the layout was lost in the
        // conversion to WebVTT — and for anime the layout is half the content. Since then
        // the app fetches the track raw (`Stream.ass`), reads time, text **and position**
        // itself and draws it: dialog at the bottom, signs at the top. The reason for the
        // engine change is thereby gone.
        var anime = Self.movieWithTextSubtitle
        anime.subtitleTracks = [
            .init(
                id: "4", kind: .subtitle, title: "Deutsch", language: "deu",
                codec: "ass", subtitleFormat: .ass
            )
        ]
        let decision = PlaybackEngineSelector.decide(
            for: anime,
            subtitleTrack: anime.subtitleTracks[0],
            hasMediaServer: true
        )

        // The track number still does not go into the address: drawing happens in the app,
        // the server does not need to know anything about it.
        #expect(decision.subtitleStreamIndex == 4)
    }

    @Test("Without a media server even plain text still needs VLC")
    func textSubtitleWithoutServerNeedsVLC() {
        // Nobody converts there: an SRT track in a raw-read file can only be rendered by
        // VLC — the old rule still applies at the edge without a server.
        let subtitle = Self.movieWithTextSubtitle.subtitleTracks[0]
        let decision = PlaybackEngineSelector.decide(
            for: Self.movieWithTextSubtitle,
            subtitleTrack: subtitle,
            hasMediaServer: false
        )

        #expect(decision.subtitleStreamIndex == nil)
    }

    @Test("A chosen DTS track forces the native file onto the server path")
    func foreignAudioChoiceForcesTheStream() {
        // The device does not output DTS: delivered unchanged, the chosen track would stay
        // silent — and a silent title looks like a broken one. The server converts exactly
        // this track to AAC; the reason names the track choice so that nobody starts
        // searching at the container.
        let movie = MediaSource(
            container: .mp4,
            videoCodec: "h264",
            audioTracks: [
                .init(id: "1", kind: .audio, title: "Stereo", language: "deu", codec: "aac"),
                .init(id: "2", kind: .audio, title: "DTS 5.1", language: "deu", codec: "dts"),
            ]
        )
        let decision = PlaybackEngineSelector.decide(
            for: movie,
            audioTrack: movie.audioTracks[1],
            hasMediaServer: true
        )

        #expect(decision.delivery == .hls)
        #expect(decision.reason == .trackChoiceNeedsServer)
        #expect(decision.audioStreamIndex == 2)
    }

    @Test("Even on Dolby Vision titles the subtitle does not change the delivery path")
    func dolbyVisionSubtitleStaysSideloaded() {
        // The history behind it: burn-in (90 seconds without a byte of picture), the main
        // list (declares dvh1 copies as hvc1 — black) and a list rebuild in the engine all
        // failed on the device. Since then the app draws by itself — the subtitle is only a
        // number to fetch and no longer touches the delivery path.
        var movie = Self.movieWithTextSubtitle
        movie.videoRange = .dolbyVision

        let decision = PlaybackEngineSelector.decide(
            for: movie,
            subtitleTrack: movie.subtitleTracks[0],
            hasMediaServer: true
        )

        #expect(decision.delivery == .hls)
        #expect(decision.subtitleStreamIndex == 6)
    }

    @Test("With unchanged delivery the track numbers stay empty")
    func directPlayCarriesNoTrackNumbers() {
        // There the engine itself chooses between the tracks of the file — a number in the
        // address would have no recipient, and `static=true` is meant to remain the only
        // part of the request.
        let movie = MediaSource(
            container: .mp4,
            videoCodec: "h264",
            audioTracks: [
                .init(id: "1", kind: .audio, title: "Deutsch", language: "deu", codec: "aac"),
                .init(id: "2", kind: .audio, title: "English", language: "eng", codec: "ac3"),
            ]
        )
        let decision = PlaybackEngineSelector.decide(
            for: movie,
            audioTrack: movie.audioTracks[1],
            hasMediaServer: true
        )

        #expect(decision.delivery == .directPlay)
        #expect(decision.audioStreamIndex == nil)
        #expect(decision.subtitleStreamIndex == nil)
    }
}

/// Who jumps when resuming — the server or the engine.
///
/// **The most expensive finding of this troubleshooting, and it was in our own code.**
/// Every resumed playback was switched to remuxing so that the server can start
/// further ahead. For the system engine that is right. For VLC with direct playback
/// it is wrong and expensive: VLC reads the file via range requests and jumps
/// itself, while remuxing starts an ffmpeg process that reads the same file in
/// parallel.
///
/// Measured on the server: one reader on the disk 452 Mbit/s, two simultaneous ones
/// 260 and 52. That is exactly what playback choked on — and exactly why episodes
/// (1.2 GB, second reader done after seconds) and movies (15.6 GB, second reader the
/// whole time) behaved so differently.

/// The rules from the format research of 2026-08-08. (roadmap P11).
///
/// Each of them covers a bug that would stay **silent**: the title starts, and only
/// on the TV does one see comb patterns, black or stereo.
@Suite("Engine selection after the format probe")
struct PlaybackRulesAfterResearchTests {

    /// **The name lied, and the second line checked nothing** (AP8 · the 59 tautological
    /// checks, finding 2026-08-24). "Interlacing excludes Apple's engine" — it does not:
    /// since VLC was removed there is no other, and `engine == .native` is true no
    /// matter what the file contains. The assertion also stood next to the finding from
    /// AP2 that exactly this rule never takes effect.
    ///
    /// What interlacing really does is a statement about the **delivery path**: the file
    /// does not go out unchanged but via the server or the remuxer. That is testable,
    /// and that is what stands here.
    @Test("Interlacing takes away a file's unchanged delivery")
    func interlacedLosesDirectPlay() {
        let source = MediaSource(
            container: .mp4,
            videoCodec: "h264",
            audioTracks: [MediaTrack(id: "1", kind: .audio, title: "", codec: "aac")],
            isInterlaced: true
        )

        #expect(!source.isNativelyPlayable)
        // **With a media server**, because only it can deinterlace. Without it, unchanged
        // delivery remains the only path — and that is exactly the finding from AP2: the
        // rule never takes effect for IPTV, because there is nobody there who could do
        // better.
        #expect(
            PlaybackEngineSelector.decide(for: source, hasMediaServer: true).delivery
                != .directPlay)
        #expect(PlaybackEngineSelector.decide(for: source).delivery == .directPlay)
    }

    @Test("Without interlacing info the unchanged delivery stays")
    func unknownInterlacingStaysDirect() {
        let source = MediaSource(container: .mp4, videoCodec: "h264")

        #expect(source.isNativelyPlayable)
        #expect(
            PlaybackEngineSelector.decide(for: source, hasMediaServer: true).delivery
                == .directPlay)
    }

    /// **Three checks became one, and the one says something** (AP8, added 2026-09-02).
    /// "The app draws character-set subtitles itself", "whoever prefers plain text",
    /// "image subtitles stay with VLC" — all three built a different source, called the
    /// choice and then asserted `engine == .native`. Since VLC was removed that was true
    /// in all three cases, regardless of the subtitle.
    ///
    /// The statement behind it is still a real one: **the subtitle format no longer
    /// shifts the choice.** Where ASS or DVBSUB used to force the second engine, now
    /// only picture and container decide; drawing happens afterwards, by the app. This
    /// check fails as soon as someone builds a branch on subtitle format again — and
    /// that is exactly what it is meant to do.
    @Test("The subtitle format no longer shifts the choice of path")
    func subtitleFormatNoLongerSteersTheDecision() {
        func decision(
            _ format: MediaSource.SubtitleFormat?, plain: Bool = false
        )
            -> PlaybackDecision
        {
            let track = format.map {
                MediaTrack(
                    id: "3", kind: .subtitle, title: "Deutsch", codec: $0.rawValue,
                    subtitleFormat: $0)
            }
            let source = MediaSource(
                container: .mp4, videoCodec: "h264", subtitleTracks: track.map { [$0] } ?? [])
            return PlaybackEngineSelector.decide(
                for: source, subtitleTrack: track, prefersPlainSubtitles: plain,
                hasMediaServer: true)
        }

        let without = decision(nil)
        #expect(without.delivery == .directPlay)
        for scenario in [
            decision(.ass), decision(.ass, plain: true), decision(.dvbsub),
            decision(.dvbsub, plain: true), decision(.pgs), decision(.vtt),
        ] {
            #expect(scenario.delivery == without.delivery)
            #expect(scenario.reason == without.reason)
        }
    }

    @Test("The device profile reports AV1 only if the device can do it")
    func codecListFollowsTheDevice() {
        let previous = (DeviceCapabilities.hasHEVC, DeviceCapabilities.hasAV1)
        defer { DeviceCapabilities.adopt(hasHEVC: previous.0, hasAV1: previous.1) }

        DeviceCapabilities.adopt(hasHEVC: true, hasAV1: false)
        #expect(DeviceCapabilities.videoCodecList == "h264,hevc")

        DeviceCapabilities.adopt(hasHEVC: true, hasAV1: true)
        #expect(DeviceCapabilities.videoCodecList == "h264,hevc,av1")
    }
}

/// DTS in the app (2026-09-04): a Matroska with DTS audio no longer goes to the server
/// but through our own remuxer — the core is turned into AAC there.
struct DTSSelectorTests {

    @Test("A DTS Matroska is remuxed in the app")
    func dtsMatroskaStaysInApp() {
        let movie = MediaSource(
            container: .mkv,
            videoCodec: "h264",
            audioTracks: [.init(id: "1", kind: .audio, title: "DTS 5.1", codec: "dts")]
        )
        let decision = PlaybackEngineSelector.decide(
            for: movie, audioTrack: movie.audioTracks[0], hasMediaServer: true)
        #expect(decision.delivery == .remuxInApp)
        #expect(decision.reason == .remuxedInApp)
    }

    @Test("DTS in a file the remuxer cannot read stays a server matter")
    func dtsInterlacedMatroskaGoesToServer() {
        let movie = MediaSource(
            container: .mkv,
            videoCodec: "h264",
            audioTracks: [.init(id: "1", kind: .audio, title: "DTS", codec: "dts")],
            isInterlaced: true
        )
        let decision = PlaybackEngineSelector.decide(
            for: movie, audioTrack: movie.audioTracks[0], hasMediaServer: true)
        #expect(decision.delivery == .hls)
    }

    @Test("TrueHD stays a server matter")
    func trueHDGoesToServer() {
        let movie = MediaSource(
            container: .mkv,
            videoCodec: "h264",
            audioTracks: [.init(id: "1", kind: .audio, title: "TrueHD", codec: "truehd")]
        )
        let decision = PlaybackEngineSelector.decide(
            for: movie, audioTrack: movie.audioTracks[0], hasMediaServer: true)
        #expect(decision.delivery == .hls)
    }
}
