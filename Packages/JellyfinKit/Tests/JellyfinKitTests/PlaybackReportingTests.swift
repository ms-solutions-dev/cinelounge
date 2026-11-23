import Core
import Foundation
import JellyfinAPI
import Testing

@testable import JellyfinKit

/// What the server provides for playback and what goes back to it.
///
/// The network stays outside. What is checked are the two places where errors can hide
/// without causing a crash: the translation of real server responses and the building of
/// the playback address. Both show up on the device only as "looks bad" or "doesn't work" —
/// symptoms nobody can follow from the UI.
///
/// The JSON excerpts come from responses fetched with `curl` from the server on the home
/// network. They are shortened only by fields that play no role here; names, nesting and
/// values are unchanged. Self-built examples would hide exactly the quirks where things
/// snag — that `LocalTrailers` delivers a bare field, say, or that `AdjacentTo` returns two
/// or three titles depending on position.
@Suite("Playback: server values and URL construction")
struct PlaybackReportingTests {

    static func decode<T: Decodable>(_ json: String, as type: T.Type) throws -> T {
        // The same decoder as in the real integration — otherwise the test checks something other
        // than what runs later.
        try JellyfinDecoder.make().decode(T.self, from: Data(json.utf8))
    }

    static func value(_ name: String, in query: [URLQueryItem]) -> String? {
        query.first { $0.name == name }?.value
    }

    // MARK: - Trailer

    /// Response to `Users/{userID}/Items/{itemID}/LocalTrailers` for "Circle of the Clockmakers". A
    /// **field** at the top level, not an object with `Items`.
    static let localTrailers = """
        [
          {
            "Name": "Zirkel der Uhrmacher (1991) - Sample",
            "Id": "270f8e2f4d056bbecd9adc37fe43e75f",
            "Type": "Trailer",
            "ExtraType": "Trailer",
            "Container": "mkv",
            "RunTimeTicks": 641540000,
            "ProductionYear": 1991,
            "ImageTags": { "Primary": "5291fd6f7a7e59f1a2c8ebb99dd4a3fc" },
            "MediaSources": [
              {
                "Id": "270f8e2f4d056bbecd9adc37fe43e75f",
                "Container": "mkv",
                "SupportsDirectPlay": true,
                "Bitrate": 49101716,
                "RunTimeTicks": 641540000,
                "MediaStreams": [
                  {
                    "Codec": "hevc", "Type": "Video", "Index": 0,
                    "DisplayTitle": "4K HEVC HDR",
                    "VideoRange": "HDR", "VideoRangeType": "HDR10",
                    "Width": 3840, "Height": 2160, "BitRate": 40374640,
                    "IsDefault": true
                  },
                  {
                    "Codec": "ac3", "Type": "Audio", "Index": 1, "Language": "deu",
                    "DisplayTitle": "DTS 5.1 - German - Dolby Digital - Standard",
                    "ChannelLayout": "5.1", "BitRate": 640000, "IsDefault": true
                  },
                  {
                    "Codec": "truehd", "Type": "Audio", "Index": 2, "Language": "eng",
                    "DisplayTitle": "DTS 5.1 - English - Dolby TrueHD + Dolby Atmos - 7.1",
                    "ChannelLayout": "7.1", "BitRate": 3188163, "IsDefault": false
                  },
                  {
                    "Codec": "PGSSUB", "Type": "Subtitle", "Index": 5, "Language": "deu",
                    "DisplayTitle": "Forced - German - Standard - Erzwungen - PGSSUB",
                    "Width": 1920, "Height": 1080, "IsDefault": true
                  }
                ]
              }
            ]
          }
        ]
        """

    @Test("A local trailer is mapped with its own properties")
    func trailerCarriesItsOwnSource() throws {
        // The core of the matter: the trailer lies as a file of its own next to the film and is
        // built differently from it — here MKV with HEVC, while the film itself is MP4. Without its
        // own ``MediaSource`` the engine choice would have to use the film's, and the trailer would
        // play black on the system player. Exactly for this the contract returns a title and not a
        // finished address.
        let dtos = try Self.decode(Self.localTrailers, as: [BaseItemDto].self)
        let trailer = try #require(dtos.first.flatMap(ItemMapping.mediaItem(from:)))

        let source = try #require(trailer.source, "without a MediaSource the engine choice is blind")
        #expect(source.container == .mkv)
        #expect(source.videoCodec == "hevc")
        #expect(source.videoRange == .hdr10)
        #expect(trailer.runtime.map { Int($0) } == 64, "a little over a minute")
    }

    @Test("The trailer is repackaged based on its properties")
    func trailerDecisionFollowsFromMapping() throws {
        // The translation is only right if in the end a path comes out that can also open the file.
        // Apple's engine cannot do MKV — since 2026-08-10 the app swaps the container beforehand, and
        // the second audio track is not lost in the process but chosen beforehand.
        let dtos = try Self.decode(Self.localTrailers, as: [BaseItemDto].self)
        let source = try #require(dtos.first.flatMap(ItemMapping.mediaItem(from:))?.source)

        let decision = PlaybackEngineSelector.decide(for: source)

        #expect(decision.delivery == .remuxInApp)
        #expect(decision.reason == .remuxedInApp)
    }

    @Test("Without an attached trailer nothing comes back instead of an error")
    func trailerAbsent() throws {
        // The server answers with status 200 and an empty field — also for an identifier it does
        // not know. Whoever turns that into an error shows a message on every episode of a series
        // although nothing is broken.
        let dtos = try Self.decode("[]", as: [BaseItemDto].self)

        #expect(dtos.first.flatMap(ItemMapping.mediaItem(from:)) == nil)
    }

    // MARK: - Next episode

    /// `Shows/{seriesID}/Episodes?AdjacentTo=…` in the middle of a season: three titles in
    /// broadcast order, the episode asked about in the middle.
    static let adjacentInsideSeason = """
        {
          "Items": [
            {
              "Name": "Die Nacht der Laternenwache - Die Heimkehr der Siedler, Teil 2",
              "Id": "3438403f99640eda0a402f5cd7482073", "Type": "Episode",
              "SeriesId": "f8bae756f276a61acae318a522781457", "SeriesName": "Hiske bl Tedren",
              "ParentIndexNumber": 1, "IndexNumber": 4, "RunTimeTicks": 14523260000
            },
            {
              "Name": "Feuerprobe - Schlacht um den Bezirk Wendel, Teil 1",
              "Id": "cdf234ab120f03754b6cfd45e8b8dbce", "Type": "Episode",
              "SeriesId": "f8bae756f276a61acae318a522781457", "SeriesName": "Hiske bl Tedren",
              "ParentIndexNumber": 1, "IndexNumber": 5, "RunTimeTicks": 14500320000
            },
            {
              "Name": "Die Stadt durch die Augen eines Jungen - Schlacht um den Bezirk Wendel, Teil 2",
              "Id": "480a05c8f990abc6363823b50cb51396", "Type": "Episode",
              "SeriesId": "f8bae756f276a61acae318a522781457", "SeriesName": "Hiske bl Tedren",
              "ParentIndexNumber": 1, "IndexNumber": 6, "RunTimeTicks": 14500320000
            }
          ],
          "TotalRecordCount": 3,
          "StartIndex": 0
        }
        """

    /// The same query for the last episode of the first season. The third title belongs to the
    /// **second** season — the server itself crosses the boundary.
    static let adjacentAtSeasonBoundary = """
        {
          "Items": [
            {
              "Name": "Reue - Sturm auf den Bezirk Lindrel, Teil 2",
              "Id": "5c3998a1ad83180f26c7bf517d3cb3c8", "Type": "Episode",
              "SeriesId": "f8bae756f276a61acae318a522781457",
              "ParentIndexNumber": 1, "IndexNumber": 24
            },
            {
              "Name": "Der Wall - Sturm auf den Bezirk Lindrel, Teil 3",
              "Id": "3704ebcfe7f9cf9a9e815f90a2e8d150", "Type": "Episode",
              "SeriesId": "f8bae756f276a61acae318a522781457",
              "ParentIndexNumber": 1, "IndexNumber": 25
            },
            {
              "Name": "Der Tier-Koloss",
              "Id": "f4c86ec24c6e4d6032497acac40a76aa", "Type": "Episode",
              "SeriesId": "f8bae756f276a61acae318a522781457",
              "ParentIndexNumber": 2, "IndexNumber": 1
            }
          ],
          "TotalRecordCount": 3,
          "StartIndex": 0
        }
        """

    /// The same query for the last existing episode of the series: only **two** titles, and the
    /// one asked about is at the back.
    static let adjacentAtSeriesEnd = """
        {
          "Items": [
            {
              "Name": "Attacke",
              "Id": "21caa8912ec8d22b638b2c3a5f493cc8", "Type": "Episode",
              "SeriesId": "f8bae756f276a61acae318a522781457",
              "ParentIndexNumber": 2, "IndexNumber": 11
            },
            {
              "Name": "Schreie",
              "Id": "058ddb65f7f2dc3b41a0ba511db7c196", "Type": "Episode",
              "SeriesId": "f8bae756f276a61acae318a522781457",
              "ParentIndexNumber": 2, "IndexNumber": 12
            }
          ],
          "TotalRecordCount": 2,
          "StartIndex": 0
        }
        """

    /// The same query for the **first** episode of the series: likewise only two titles, but
    /// the one asked about at the front.
    static let adjacentAtSeriesStart = """
        {
          "Items": [
            {
              "Name": "Für dich in 2000 Wintern - Der Fall von Kerrbach, Teil 1",
              "Id": "4f7a85536b68adcaa65defef27c8ce98", "Type": "Episode",
              "SeriesId": "f8bae756f276a61acae318a522781457",
              "ParentIndexNumber": 1, "IndexNumber": 1
            },
            {
              "Name": "An jenem Morgen - Der Fall von Kerrbach, Teil 2",
              "Id": "d13c49557b4fbab58211d600570593ee", "Type": "Episode",
              "SeriesId": "f8bae756f276a61acae318a522781457",
              "ParentIndexNumber": 1, "IndexNumber": 2
            }
          ],
          "TotalRecordCount": 2,
          "StartIndex": 0
        }
        """

    @Test("After an episode in the middle of the season comes the immediately next one")
    func nextEpisodeInsideSeason() throws {
        // The basic case. What is wanted is the episode after, and not the next unwatched one: on
        // a second viewing of a series that would lie somewhere a hundred episodes further on, and
        // the credits would carry an offer that throws the viewer out of the story.
        let response = try Self.decode(Self.adjacentInsideSeason, as: BaseItemDtoQueryResult.self)
        let items = try #require(response.items)

        let next = JellyfinSource.episodeFollowing("cdf234ab120f03754b6cfd45e8b8dbce", in: items)
        let episode = try #require(next.flatMap(ItemMapping.mediaItem(from:)))

        #expect(episode.episodeNumber == 6)
        #expect(episode.seasonNumber == 1)
        #expect(episode.id == "480a05c8f990abc6363823b50cb51396")
    }

    @Test("After the last episode of a season comes the first of the next")
    func nextEpisodeCrossesSeasonBoundary() throws {
        // For the viewer the season boundary is no caesura. If the offer breaks off there, it looks
        // like the end of the series — and the second season is found only by whoever goes back to
        // the overview on their own.
        let response = try Self.decode(Self.adjacentAtSeasonBoundary, as: BaseItemDtoQueryResult.self)
        let items = try #require(response.items)

        let next = JellyfinSource.episodeFollowing("3704ebcfe7f9cf9a9e815f90a2e8d150", in: items)
        let episode = try #require(next.flatMap(ItemMapping.mediaItem(from:)))

        #expect(episode.seasonNumber == 2)
        #expect(episode.episodeNumber == 1)
    }

    @Test("After the last available episode nothing is offered")
    func nextEpisodeAtSeriesEnd() throws {
        // The case that makes the search by identifier necessary. Here only two titles come, and
        // the one asked about is in second place. Whoever stubbornly takes the second entry offers
        // the episode just watched again in the credits — an error that is never noticed when
        // trying things out in the middle of a season, because there it does the right thing.
        let response = try Self.decode(Self.adjacentAtSeriesEnd, as: BaseItemDtoQueryResult.self)
        let items = try #require(response.items)

        #expect(JellyfinSource.episodeFollowing("058ddb65f7f2dc3b41a0ba511db7c196", in: items) == nil)
    }

    @Test("After the first episode of a series the second still comes")
    func nextEpisodeAtSeriesStart() throws {
        // Control test for the previous case, and the reason why the position says nothing: here
        // too two titles come, but the episode asked about is at the front instead of the back. The
        // two edges cannot be told apart by count, only by identifier.
        let response = try Self.decode(Self.adjacentAtSeriesStart, as: BaseItemDtoQueryResult.self)
        let items = try #require(response.items)

        let next = JellyfinSource.episodeFollowing("4f7a85536b68adcaa65defef27c8ce98", in: items)
        let episode = try #require(next.flatMap(ItemMapping.mediaItem(from:)))

        #expect(episode.episodeNumber == 2)
    }

    @Test("If the requested episode is missing from the response, nothing is offered")
    func nextEpisodeUnrelatedAnswer() throws {
        // It happens: if `AdjacentTo` points at an episode of another series, the server does not
        // answer with an error but with the first episode of the series asked for. Such a response
        // cannot be interpreted, and an offer from it would be an arbitrary episode from a series
        // the viewer is not watching right now.
        let response = try Self.decode(Self.adjacentInsideSeason, as: BaseItemDtoQueryResult.self)
        let items = try #require(response.items)

        #expect(JellyfinSource.episodeFollowing("ffffffffffffffffffffffffffffffff", in: items) == nil)
        #expect(JellyfinSource.episodeFollowing("cdf234ab120f03754b6cfd45e8b8dbce", in: []) == nil)
    }

    // MARK: - URL construction

    /// A session as the handshake delivers it — every address carries it.
    static let playback = PlaybackSession(
        itemID: "film",
        playSessionID: "session-1",
        mediaSourceID: "source-1"
    )

    static func query(for decision: PlaybackDecision) -> [URLQueryItem] {
        JellyfinSource.streamQuery(
            for: decision,
            accessToken: "token",
            deviceID: "device-1",
            playback: playback
        )
    }

    static func hlsQuery(for decision: PlaybackDecision) -> [URLQueryItem] {
        JellyfinSource.hlsQuery(
            for: decision,
            accessToken: "token",
            deviceID: "device-1",
            playback: playback
        )
    }

    @Test("Every URL carries session, media source and device")
    func everyURLCarriesTheSession() {
        // The documented error behind "video stuck": without the `PlaySessionId` assigned by the
        // server, it considered the encoding orphaned after about ten seconds, ended it and deleted
        // the segment files — the player ran into a 404. That is why the session is in EVERY
        // address, not only in those where the server converts.
        var queries: [(String, [URLQueryItem])] = [.directPlay, .remux, .transcode].map {
            (delivery: Delivery) in
            (
                delivery.rawValue,
                Self.query(
                    for: PlaybackDecision(
                        engine: .native, delivery: delivery, reason: .nativeContainer
                    )
                )
            )
        }
        queries.append(
            (
                "hls",
                Self.hlsQuery(
                    for: PlaybackDecision(engine: .native, delivery: .hls, reason: .nativeContainer)
                )
            )
        )

        for (name, query) in queries {
            #expect(Self.value("PlaySessionId", in: query) == "session-1", "\(name)")
            #expect(Self.value("MediaSourceId", in: query) == "source-1", "\(name)")
            #expect(Self.value("DeviceId", in: query) == "device-1", "\(name)")
        }
    }

    @Test("Ten-bit H.264 gets the eight-bit limit in the playlist URL — other reasons do not")
    func tenBitH264AsksForEightBit() {
        let hi10p = Self.hlsQuery(
            for: PlaybackDecision(engine: .native, delivery: .hls, reason: .videoNeedsSoftwareDecoder))
        #expect(Self.value("MaxVideoBitDepth", in: hi10p) == "8")
        let fallback = Self.hlsQuery(
            for: PlaybackDecision(engine: .native, delivery: .hls, reason: .nativeContainer))
        #expect(Self.value("MaxVideoBitDepth", in: fallback) == nil)
    }

    @Test("Delivering unchanged needs nothing more than static=true")
    func directPlayAsksForNothing() {
        // Every additional parameter would get the server to do something after all — and the
        // cheapest path would become the most expensive.
        let query = Self.query(
            for: PlaybackDecision(engine: .native, delivery: .directPlay, reason: .nativeContainer)
        )

        #expect(Self.value("static", in: query) == "true")
        #expect(Self.value("videoCodec", in: query) == nil)
        #expect(Self.value("audioCodec", in: query) == nil)
        #expect(Self.value("videoBitRate", in: query) == nil)
        #expect(Self.value("maxWidth", in: query) == nil)
    }

    @Test("The own repackager gets the file untouched as well")
    func remuxInAppAsksForTheRawFile() {
        // **The on-device test of 2026-08-11**: here `== .directPlay` stood twice, and with it the
        // repackager got `stream.mp4?static=false`. The server then repackaged on its own, its
        // stream came without range access, the repackager threw, and the player silently fell back
        // to VLC — picture stood, sound continued. An error no display named: the diagnosis said
        // `native/remuxInApp`, what played was `vlc/directPlay`.
        let query = Self.query(
            for: PlaybackDecision(engine: .native, delivery: .remuxInApp, reason: .remuxedInApp)
        )

        #expect(Self.value("static", in: query) == "true")
        #expect(Self.value("videoCodec", in: query) == nil)
        #expect(Self.value("audioCodec", in: query) == nil)
        #expect(Self.value("container", in: query) == nil)
        // And the path belongs to the same question: `stream.mp4` would be the address where the
        // server repackages even with `static=true`.
        #expect(JellyfinSource.wantsUntouchedFile(.remuxInApp))
        #expect(JellyfinSource.wantsUntouchedFile(.directPlay))
        #expect(!JellyfinSource.wantsUntouchedFile(.remux))
        #expect(!JellyfinSource.wantsUntouchedFile(.transcode))
        #expect(!JellyfinSource.wantsUntouchedFile(.hls))
    }

    @Test("The playlist names fMP4 segments and codec lists")
    func playlistSpeaksFMP4() {
        // `SegmentContainer=mp4` is the fix for the actual codec error of the early HLS period:
        // AVFoundation demands HEVC in fMP4 segments, in MPEG-TS the picture stayed black. The
        // codec lists let the server decide — it copies what the device can and converts the rest.
        let query = Self.hlsQuery(
            for: PlaybackDecision(
                engine: .native,
                delivery: .hls,
                reason: .containerNotNativelySupported
            )
        )

        #expect(Self.value("SegmentContainer", in: query) == "mp4")
        #expect(Self.value("VideoCodec", in: query) == "h264,hevc")
        // E-AC-3 is missing on purpose: in the on-device test the audio of an E-AC-3 title in the
        // segmented stream was clearly offset, AC-3 and AAC clean. The server therefore converts the
        // track to multichannel AAC — the picture stays a copy. With unchanged delivery E-AC-3
        // still plays directly; nobody segments there.
        #expect(Self.value("AudioCodec", in: query) == "aac,ac3")
        // **Eight, not six** (check agent 2026-08-23): the device profile promises eight channels, but
        // the number in this address wins — every 7.1 title was silently downmixed to 5.1. The
        // check pinned the six without anyone ever having justified why.
        #expect(Self.value("MaxAudioChannels", in: query) == "8")
        // **One, not two** (F-004, 2026-09-03): one finished piece suffices to start; the second cost
        // three seconds of waiting during conversion.
        #expect(Self.value("MinSegments", in: query) == "1")

        // Even WITHOUT a limit set, a frame rate is in the address. The documented error behind it:
        // on the first real conversion (home video from the DivX era) the server started its VAAPI
        // encoder with `-b:v 0` and aborted immediately — "Bitrate must be set for VBR RC mode".
        // As long as it only copied, that was never noticed. The default is that of jellyfin-web on
        // the home network and lies far above any source in the catalog, so it never becomes the
        // cause for a downscale itself.
        #expect(Self.value("VideoBitrate", in: query) == "120000000")
        #expect(Self.value("MaxWidth", in: query) == nil)
    }

    /// **The start point no longer exists — and the address least of all carries it** (AP8,
    /// 2026-09-02). `PlaybackDecision.startOffset` was dropped with the VLC removal; it had stood at
    /// zero since, and the branch that would have written it into the address was unreachable.
    ///
    /// The check stays, because its subject stays: the documented error of the old resuming was
    /// that the list began at zero despite `StartTimeTicks` — the film played from the start,
    /// the bar stood in the middle.
    @Test("The playlist carries NO start point — the player seeks itself")
    func playlistCarriesNoStartTime() {
        let query = Self.hlsQuery(
            for: PlaybackDecision(
                engine: .native,
                delivery: .hls,
                reason: .containerNotNativelySupported
            )
        )

        #expect(Self.value("StartTimeTicks", in: query) == nil)
        #expect(Self.value("startTimeTicks", in: query) == nil)
    }

    @Test("The stream never carries subtitles — the app renders them itself")
    func playlistCarriesNoSubtitles() {
        // The master playlist (`master.m3u8`) declares DV copies wrongly (hvc1 instead of dvh1) and
        // attaches convert fallbacks — documented black on the device. Burning in first extracts
        // all tracks of the whole file — documented 90 seconds without a byte. That is why the
        // address always stays on the simple list and names no subtitle; the app fetches the track
        // as WebVTT and lays it over the picture itself.
        let chosen = PlaybackDecision(
            engine: .native,
            delivery: .hls,
            reason: .containerNotNativelySupported,
            subtitleStreamIndex: 3
        )
        #expect(
            JellyfinSource.hlsPlaylistPath(for: chosen, itemID: "x") == "Videos/x/main.m3u8"
        )
        let query = Self.hlsQuery(for: chosen)
        #expect(Self.value("SubtitleMethod", in: query) == nil)
        #expect(Self.value("SubtitleStreamIndex", in: query) == nil)
    }

    @Test("The dynamic ranges appear in the URL only for an HDR-capable display")
    func playlistDeclaresRangesOnlyWithHDR() {
        // The documented finding from the on-device test: without a declared DOVI capability the
        // server copies Dolby Vision HEVC as `hvc1`, the device reads ordinary HEVC, and the
        // embedded DV metadata flicker through as brightness flashes. With the declaration it
        // marks the same copy as `dvh1`. And conversely: an SDR screen must not be told anything it
        // cannot hold — there the address stays as before.
        let plain = Self.hlsQuery(
            for: PlaybackDecision(
                engine: .native,
                delivery: .hls,
                reason: .containerNotNativelySupported
            )
        )
        #expect(Self.value("hevc-rangetype", in: plain) == nil)

        let hdr = Self.hlsQuery(
            for: PlaybackDecision(
                engine: .native,
                delivery: .hls,
                reason: .containerNotNativelySupported,
                displaySupportsHDR: true
            )
        )
        #expect(Self.value("hevc-rangetype", in: hdr) == "SDR,HDR10,HLG,DOVI,DOVIWithHDR10")
    }

    @Test("A bandwidth limit appears in the playlist URL")
    func playlistCarriesTheLimit() {
        // The limit moves into the same list — the server downscales within the segmenting, and the
        // engine notices nothing of the change.
        let query = Self.hlsQuery(
            for: PlaybackDecision(
                engine: .native,
                delivery: .hls,
                reason: .nativeContainer,
                maxBitrate: 2_000_000,
                maxWidth: 1280,
                isBandwidthLimited: true
            )
        )

        #expect(Self.value("VideoBitrate", in: query) == "2000000")
        #expect(Self.value("MaxWidth", in: query) == "1280")
    }

    @Test("Repackaging leaves picture and sound untouched")
    func remuxCopiesInsteadOfEncoding() {
        // The case at hand: Dolby Vision in a container Apple's engine does not open. `copy` stays
        // here explicitly — unlike with the continuous stream the server must NOT decide itself,
        // because converting would lose exactly the dynamic metadata that matters.
        let query = Self.query(
            for: PlaybackDecision(
                engine: .native,
                delivery: .remux,
                reason: .dolbyVisionNeedsNative
            )
        )

        #expect(Self.value("static", in: query) == "false")
        #expect(Self.value("videoCodec", in: query) == "copy")
        #expect(Self.value("audioCodec", in: query) == "copy")
        // Without naming the container the server repackages into the same one, and the whole
        // detour would be for nothing.
        #expect(Self.value("container", in: query) == "mp4")
    }

    @Test("Repackaging knows no limits")
    func remuxIgnoresLimits() {
        // A limit means converting. When repackaging the server only copies — a limit in the
        // address would be a parameter without effect, and nobody would notice it does not take.
        let query = Self.query(
            for: PlaybackDecision(
                engine: .native,
                delivery: .remux,
                reason: .dolbyVisionNeedsNative,
                maxBitrate: 2_000_000,
                maxWidth: 1280
            )
        )

        #expect(Self.value("videoBitRate", in: query) == nil)
        #expect(Self.value("maxWidth", in: query) == nil)
    }

    @Test("Without a set limit there is no limit in the URL")
    func transcodeWithoutLimits() {
        // Before, 1500000 and 1280 were hard-coded. With that every converted title looked like it
        // was over mobile data even on the home network, and the viewer's setting was silently
        // bypassed.
        let query = Self.query(
            for: PlaybackDecision(engine: .native, delivery: .transcode, reason: .bandwidthTooLow)
        )

        #expect(Self.value("videoCodec", in: query) == "h264")
        #expect(Self.value("audioCodec", in: query) == "aac")
        #expect(Self.value("videoBitRate", in: query) == nil, "no limit means no value")
        #expect(Self.value("maxWidth", in: query) == nil)
    }

    @Test("Transcoding names the container, otherwise a transport stream comes")
    func transcodeNamesTheContainer() {
        // Checked against the server: without `container` it answers the same address with
        // `video/mp2t`, with `container=mp4` with `video/mp4`. Apple's engine does not open a
        // transport stream — and the pairing checked here, native engine plus converting, arises
        // with every Dolby Vision title as soon as a bandwidth limit is set. A black picture would
        // be seen, and the cause would lie in a setting that has nothing to do with the container.
        let query = Self.query(
            for: PlaybackDecision(engine: .native, delivery: .transcode, reason: .bandwidthTooLow)
        )

        #expect(Self.value("container", in: query) == "mp4")
        #expect(Self.value("static", in: query) == "false")
    }

    @Test("A set limit appears with frame rate and width in the URL")
    func transcodeCarriesBothLimits() {
        // Both belong together: whoever squeezes 4K into 2 Mbit/s without reducing the pixels gets
        // a picture made of blocks. Without the width the limit would be worse than useless.
        let quality = StreamQuality.low
        let query = Self.query(
            for: PlaybackDecision(
                engine: .native,
                delivery: .transcode,
                reason: .bandwidthTooLow,
                maxBitrate: quality.bitrate,
                maxWidth: quality.maxWidth
            )
        )

        #expect(Self.value("videoBitRate", in: query) == "2000000")
        #expect(Self.value("maxWidth", in: query) == "1280")
    }

    // MARK: - The handshake before playback

    /// Response to `POST /Items/{id}/PlaybackInfo`, shortened to the fields read here — the real
    /// response carries the complete media description too.
    static let playbackInfo = """
        {
          "MediaSources": [
            {
              "Id": "0e2f4d056bbecd9adc37fe43e75f270f",
              "Container": "mkv",
              "SupportsDirectPlay": true,
              "SupportsDirectStream": true,
              "SupportsTranscoding": true
            }
          ],
          "PlaySessionId": "24ec5b2100a24a2b8a8fe775c4b268b4"
        }
        """

    @Test("Session and media source are read from the response")
    func playbackInfoYieldsBothIdentifiers() throws {
        // The two values everything hangs on: without the server's `PlaySessionId` the encoding
        // counts as orphaned, without the `MediaSourceId` nobody knows which version of the title is
        // meant.
        let info = try Self.decode(Self.playbackInfo, as: PlaybackHandshake.Reply.self)

        #expect(info.playSessionId == "24ec5b2100a24a2b8a8fe775c4b268b4")
        #expect(info.mediaSources.first?.id == "0e2f4d056bbecd9adc37fe43e75f270f")
    }

    @Test("The device profile names container and codecs in the server's spelling")
    func deviceProfileSpeaksPascalCase() throws {
        // The server reads capitalized field names exclusively. A lowercase `deviceProfile` it would
        // silently take as an empty profile — no error, only a server that converts everything it
        // has for this device.
        let body = try JSONEncoder().encode(PlaybackHandshake.Body.standard())
        let json = try JSONSerialization.jsonObject(with: body)
        let fields = try #require(json as? [String: Any])
        let profile = try #require(fields["DeviceProfile"] as? [String: Any])
        let directPlay = try #require(profile["DirectPlayProfiles"] as? [[String: Any]])
        let transcoding = try #require(profile["TranscodingProfiles"] as? [[String: Any]])

        #expect(directPlay.first?["VideoCodec"] as? String == "h264,hevc")
        #expect(directPlay.first?["AudioCodec"] as? String == "aac,ac3,eac3")
        // The conversion target is HLS with MP4 segments — the same as the playback address demands.
        // A profile that promised something else would let the server decide differently than it
        // delivers.
        #expect(transcoding.first?["Container"] as? String == "mp4")
        #expect(transcoding.first?["Protocol"] as? String == "hls")
    }

    // MARK: - Reports to the server

    @Test("The paused flag is reported along and not omitted")
    func progressCarriesPauseFlag() throws {
        // The server shows in its web interface which device is playing something. Whoever does not
        // report pausing stays there as "playing" — and whoever looks in the living room to see why
        // the picture stands finds no explanation.
        let body = JellyfinSource.ProgressReport(
            itemId: "abc",
            positionTicks: 0,
            isPaused: true,
            playSessionId: "session-1",
            mediaSourceId: "source-1"
        )
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(body))
        let fields = try #require(json as? [String: Any])

        // The field names begin with a capital. A lowercase `isPaused` the server silently takes as
        // "playing" — there is no error, only a wrong state.
        #expect(fields["IsPaused"] as? Bool == true)
        #expect(fields["ItemId"] as? String == "abc")
        // And the session goes along: without it the state hangs on no encoding, and the server
        // clears it away as orphaned.
        #expect(fields["PlaySessionId"] as? String == "session-1")
        #expect(fields["MediaSourceId"] as? String == "source-1")
    }

    @Test("Without a handshake the report goes out without session fields")
    func reportsOmitMissingSession() throws {
        // The fallback when `PlaybackInfo` did not answer: the report then carries only the title.
        // An empty field would be worse than a missing one — the server would look for a session with
        // an empty identifier.
        let body = JellyfinSource.PlaybackStopReport(
            itemId: "abc",
            positionTicks: 100,
            playSessionId: nil,
            mediaSourceId: nil
        )
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(body))
        let fields = try #require(json as? [String: Any])

        #expect(fields["PlaySessionId"] == nil)
        #expect(fields["MediaSourceId"] == nil)
        #expect(fields["ItemId"] as? String == "abc")
    }

    @Test("Seconds are converted to hundred-nanosecond ticks")
    func positionInTicks() {
        // The server counts in hundred-nanoseconds. A factor off, and "Continue Watching" starts at
        // second 12 instead of minute 20.
        #expect(JellyfinSource.ticks(1200) == 12_000_000_000)
        #expect(JellyfinSource.ticks(0) == 0)
    }

    @Test("Nonsensical positions are not reported as a position")
    func positionRejectsNonsense() {
        // VLC occasionally reports a value below zero before the first picture, and AVFoundation
        // returns `NaN` while the duration is still unknown. The server would take either as the
        // position: "Continue Watching" then begins at a time that does not exist, or the conversion
        // crashes at the transition to `Int`.
        #expect(JellyfinSource.ticks(-5) == 0)
        #expect(JellyfinSource.ticks(.nan) == 0)
        #expect(JellyfinSource.ticks(.infinity) == 0)
    }
}

/// The start position in the HLS address — the figure for "Continue Watching takes 30
/// seconds" (F-013, 2026-09-04).
@Suite("The start position for the server")
struct StartTimeTicksTests {

    /// **The server forbids it** (F-014): the segment addresses inherit the query part, and
    /// `StartTimeTicks` there is a 400 for every segment.
    @Test("Resuming carries NO StartTimeTicks — the server throws them back")
    func resumeCarriesNoStartTimeTicks() {
        let query = PlaybackReportingTests.hlsQuery(
            for: PlaybackDecision(
                engine: .native, delivery: .hls, reason: .videoNeedsSoftwareDecoder,
                startAt: 1074.5))
        #expect(!query.contains { $0.name == "StartTimeTicks" })
    }

    @Test("From the beginning there is no position in the URL")
    func startFromZeroHasNoTicks() {
        let query = PlaybackReportingTests.hlsQuery(
            for: PlaybackDecision(engine: .native, delivery: .hls, reason: .nativeContainer))
        #expect(!query.contains { $0.name == "StartTimeTicks" })
    }

    @Test("The decision passes the position through")
    func decisionCarriesStart() {
        let source = MediaSource(container: .mkv, videoCodec: "h264")
        let decision = PlaybackEngineSelector.decide(for: source, startAt: 1074.5, hasMediaServer: true)
        #expect(decision.startAt == 1074.5)
    }
}
