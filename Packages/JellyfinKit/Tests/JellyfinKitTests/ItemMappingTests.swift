import Core
import Foundation
import JellyfinAPI
import Testing

@testable import JellyfinKit

/// Checked against **real** server responses, stored under `Fixtures/`. Made-up example
/// data would hide exactly the quirks on which the translation later fails — such as
/// times arriving in hundred-nanoseconds or images only as an identifier rather than an
/// address.
@Suite("Mapping of the server responses")
struct ItemMappingTests {

    static func fixture<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
            "Test file \(name).json missing"
        )
        // The same decoder as in the real integration — otherwise the test checks something
        // other than what runs later.
        return try JellyfinDecoder.make().decode(T.self, from: Data(contentsOf: url))
    }

    // MARK: - Time arithmetic

    @Test("Hundred-nanosecond ticks are converted to seconds")
    func ticks() {
        // 14512370000 ticks: an episode of a little over 24 minutes.
        //
        // **Without `#require`, and that is no cosmetics** (AP15, 2026-09-02): the translator says
        // the expression is "never equals nil" — so the check could not fail at all. It read
        // like a safeguard and was none. The warnings gate found it.
        // `-1` as replacement and not `0`: both assertions below fall over with it should `nil`
        // ever come out here — so the case stays checked, just without a line that could not
        // have been.
        let seconds = ItemMapping.seconds(fromTicks: 14_512_370_000) ?? -1

        #expect(abs(seconds - 1451.237) < 0.001)
        #expect(Int(seconds / 60) == 24, "about 24 minutes")
    }

    @Test("Missing or empty times yield nothing instead of zero")
    func ticksMissing() {
        #expect(ItemMapping.seconds(fromTicks: nil) == nil)
        // Series report 0 as runtime — that must not become a zero duration, otherwise progress
        // later divides by zero.
        #expect(ItemMapping.seconds(fromTicks: 0) == nil)
    }

    // MARK: - Series

    @Test("A series is mapped completely")
    func series() throws {
        let response = try Self.fixture("series-list", as: BaseItemDtoQueryResult.self)
        let items = try #require(response.items).compactMap(ItemMapping.mediaItem(from:))

        #expect(!items.isEmpty)

        let first = try #require(items.first)
        #expect(first.kind == .series)
        #expect(!first.title.isEmpty)
        #expect(first.year != nil)
        #expect(!first.genres.isEmpty)
        #expect(first.ratings.community != nil)
        #expect(first.ratings.imdbID?.hasPrefix("tt") == true)
    }

    @Test("Series without a critic rating get no empty field slipped in")
    func criticRatingAbsent() throws {
        let response = try Self.fixture("series-list", as: BaseItemDtoQueryResult.self)
        let items = try #require(response.items).compactMap(ItemMapping.mediaItem(from:))

        // Rotten Tomatoes does not list these series. The field must stay empty so the display
        // can leave it out instead of showing a dash.
        for item in items {
            #expect(item.ratings.critic == nil)
            #expect(!item.ratings.isEmpty, "the audience rating is still there")
        }
    }

    // MARK: - Episodes

    @Test("An episode keeps series name, season and number")
    func episode() throws {
        let dto = try Self.fixture("episode-detail", as: BaseItemDto.self)
        let item = try #require(ItemMapping.mediaItem(from: dto))

        #expect(item.kind == .episode)
        #expect(item.parentTitle == "Blono")
        #expect(item.seasonNumber == 1)
        #expect(item.episodeNumber == 1)
        #expect(item.runtime != nil)
    }

    @Test("The technical properties are read correctly")
    func mediaSource() throws {
        let dto = try Self.fixture("episode-detail", as: BaseItemDto.self)
        let source = try #require(ItemMapping.mediaItem(from: dto)?.source)

        #expect(source.container == .mkv)
        #expect(source.videoCodec == "h264")
        #expect(source.videoRange == .sdr)
        #expect(source.supportsDirectPlay)
        #expect(source.bitrate ?? 0 > 5_000_000, "about 5.6 Mbit/s")
    }

    @Test("All three audio tracks and both subtitle tracks arrive")
    func tracks() throws {
        let dto = try Self.fixture("episode-detail", as: BaseItemDto.self)
        let source = try #require(ItemMapping.mediaItem(from: dto)?.source)

        #expect(source.audioTracks.count == 3)
        #expect(source.subtitleTracks.count == 2)

        let languages = source.audioTracks.compactMap(\.language).sorted()
        #expect(languages == ["deu", "eng", "jpn"])

        // The subtitle format later decides the engine.
        #expect(source.subtitleTracks.allSatisfy { $0.subtitleFormat == .ass })
    }

    @Test("This episode ends up at the repackager based on the mapped properties")
    func decisionFollowsFromMapping() throws {
        // The actual purpose of the translation: in the end the engine choice must deliver the
        // same result as playback on the device — since the VLC removal (2026-08-16) that means:
        // system engine, in the own repackager.
        let dto = try Self.fixture("episode-detail", as: BaseItemDto.self)
        let source = try #require(ItemMapping.mediaItem(from: dto)?.source)

        let decision = PlaybackEngineSelector.decide(for: source, wantsSubtitles: true)

        #expect(decision.delivery == .remuxInApp)
    }

    // MARK: - Chapters

    @Test("Intro and outro are mapped")
    func segments() throws {
        let response = try Self.fixture("media-segments", as: MediaSegmentDtoQueryResult.self)
        let segments = try #require(response.items).compactMap(ItemMapping.segment(from:))

        #expect(segments.count == 2)

        let intro = try #require(segments.first { $0.kind == .intro })
        #expect(intro.start == 0, "the intro starts at zero")
        #expect(abs(intro.end - 104.104) < 0.01, "and ends at 1:44")

        let outro = try #require(segments.first { $0.kind == .outro })
        #expect(outro.start > 1300)
    }

    @Test("An intro from second zero is not lost")
    func introAtZeroSurvives() throws {
        // Obvious mistake: treating start time zero as "missing". Then no button would appear
        // on any episode, because intros almost always begin at zero.
        let response = try Self.fixture("media-segments", as: MediaSegmentDtoQueryResult.self)
        let segments = try #require(response.items).compactMap(ItemMapping.segment(from:))

        #expect(segments.skippable(at: 5)?.kind == .intro)
    }

    // MARK: - Continue Watching

    @Test("Started titles keep their position")
    func resume() throws {
        let response = try Self.fixture("resume", as: BaseItemDtoQueryResult.self)
        let items = try #require(response.items).compactMap(ItemMapping.mediaItem(from:))

        #expect(!items.isEmpty)

        for item in items where item.progress != nil {
            let progress = try #require(item.progress)
            #expect(progress.duration > 0)
            #expect(progress.fraction >= 0 && progress.fraction <= 1)
        }
    }

    // MARK: - Libraries

    @Test("The AniList identifier is read from the server response")
    func anilistIDFromServerPayload() throws {
        // A real excerpt from a server response. Checked via the decoded form and not via a
        // self-built object: in such things the error experience says lies in the field's name,
        // and that can only be grasped through real JSON.
        let json = """
            {
              "Name": "Crown Cipher",
              "Id": "abc",
              "Type": "Series",
              "ProviderIds": {
                "AniList": "1575",
                "Imdb": "tt9171734",
                "Tmdb": "28351"
              }
            }
            """

        let dto = try JellyfinDecoder.make().decode(BaseItemDto.self, from: Data(json.utf8))
        let ratings = ItemMapping.ratings(from: dto)

        #expect(ratings.anilistID == "1575")
        #expect(ratings.imdbID == "tt9171734")
    }

    @Test("The library kinds are assigned")
    func libraryKinds() {
        #expect(ItemMapping.libraryKind(from: "tvshows") == .series)
        #expect(ItemMapping.libraryKind(from: "movies") == .movies)
        #expect(ItemMapping.libraryKind(from: "homevideos") == .homeVideos)
        #expect(ItemMapping.libraryKind(from: "music") == .music)
        #expect(ItemMapping.libraryKind(from: nil) == .mixed)

        // The folder name is freely chosen and different in every language — a folder
        // "Heimvideos und -bilder" reports the same marker as one named "Vidéos personnelles".
        // Only on that may detection hang, never on the name.
        #expect(ItemMapping.libraryKind(from: "HomeVideos") == .homeVideos)

        // Pure folder views cannot be assigned: they can contain anything, private things
        // included.
        #expect(ItemMapping.libraryKind(from: "folders") == .mixed)
    }

    /// **On-device test build 1332:** "Recently Added" showed music on the phone. A music
    /// library got the empty type filter, and empty means "everything" at the server — the
    /// albums came through and, lacking a type of their own, became films. The app is for
    /// films and series: music, music video and book libraries do not appear at all.
    @Test("Music, music video, audiobook and book libraries do not appear")
    func foreignLibraries() throws {
        // Jellyfin lists audiobooks as `books` — there is no collection type of their own.
        for contentType in ["music", "musicvideos", "books"] {
            let dto = try JellyfinDecoder.make().decode(
                BaseItemDto.self,
                from: Data(#"{"Id":"b1","Name":"X","CollectionType":"\#(contentType)"}"#.utf8))
            #expect(ItemMapping.library(from: dto) == nil, "\(contentType)")
        }
        for contentType in ["movies", "tvshows", "homevideos", "boxsets", "folders"] {
            let dto = try JellyfinDecoder.make().decode(
                BaseItemDto.self,
                from: Data(#"{"Id":"b1","Name":"X","CollectionType":"\#(contentType)"}"#.utf8))
            #expect(ItemMapping.library(from: dto) != nil, "\(contentType)")
        }
    }

    /// **And every title that is music or a book drops out at the one place** every list goes
    /// through — also "Continue Watching" (a started audiobook) and mixed folders that no
    /// library filter reaches.
    @Test("Music and book titles do not become films")
    func foreignTitles() throws {
        for contentType in ["Audio", "MusicAlbum", "MusicArtist", "MusicVideo", "AudioBook", "Book"] {
            let dto = try JellyfinDecoder.make().decode(
                BaseItemDto.self, from: Data(#"{"Id":"t1","Name":"X","Type":"\#(contentType)"}"#.utf8))
            #expect(ItemMapping.mediaItem(from: dto) == nil, "\(contentType)")
        }
        for contentType in ["Movie", "Series", "Episode", "Video", "BoxSet"] {
            let dto = try JellyfinDecoder.make().decode(
                BaseItemDto.self, from: Data(#"{"Id":"t1","Name":"X","Type":"\#(contentType)"}"#.utf8))
            #expect(ItemMapping.mediaItem(from: dto) != nil, "\(contentType)")
        }
    }

    @Test("Forced, external and hearing-impaired arrive on the track")
    func subtitleFlags() {
        // **Without these three fields the app was blind.** The server knows them from the file,
        // yet "subtitles don't work" was reported: for the four "Realm of the Herons" films there
        // is, next to the German full track, a forced one that translates only the apes' sign
        // language — eleven captions against eight hundred. Whoever does not carry the
        // difference over can neither choose nor display it.
        var forced = MediaStream()
        forced.type = .subtitle
        forced.index = 3
        forced.codec = "subrip"
        forced.language = "deu"
        forced.isForced = true
        forced.isDefault = true

        let track = ItemMapping.track(from: forced)
        #expect(track.id == "3")
        #expect(track.isForced)
        #expect(!track.isExternal)
        #expect(!track.isHearingImpaired)
        #expect(track.subtitleFormat == .srt)

        var external = MediaStream()
        external.type = .subtitle
        external.index = 1
        external.codec = "DVDSUB"
        external.language = "deu"
        external.isExternal = true
        external.isHearingImpaired = true

        let side = ItemMapping.track(from: external)
        #expect(side.isExternal)
        #expect(side.isHearingImpaired)
        #expect(!side.isForced)
        // Jellyfin writes "DVDSUB", not "dvd_subtitle" — as an unknown format the track would
        // have been requested as text, which the server never answers for picture tracks.
        #expect(side.subtitleFormat == .vobsub)

        // If the value is missing entirely, it counts as "no" — and not as "unknown".
        var plain = MediaStream()
        plain.type = .subtitle
        plain.index = 4
        plain.codec = "subrip"
        let ordinary = ItemMapping.track(from: plain)
        #expect(!ordinary.isForced)
        #expect(!ordinary.isExternal)
        #expect(!ordinary.isHearingImpaired)
    }

    @Test("The dynamic range is recognized, also in spelling variants")
    func videoRangeDetection() {
        // Decisive for the engine choice: Dolby Vision must be recognized for certain, otherwise
        // a 4K film lands with the wrong engine.
        var stream = MediaStream()
        stream.videoRangeType = .dovi
        #expect(ItemMapping.videoRange(from: stream) == .dolbyVision)

        stream.videoRangeType = .hdr10
        #expect(ItemMapping.videoRange(from: stream) == .hdr10)

        stream.videoRangeType = .sdr
        #expect(ItemMapping.videoRange(from: stream) == .sdr)

        #expect(ItemMapping.videoRange(from: nil) == .sdr)
    }

    // MARK: - Image format

    @Test("Home videos report landscape, films portrait")
    func imageFormat() throws {
        // **Against the real response of the own server**, like everything here. The home video
        // library returns 22 entries, 21 of them at 1.222 and one at 1.778; the films sit at
        // 0.667. Made-up values would have turned the boundary at 1 into a stipulation —
        // measured, it is a gap.
        let reply = try Self.fixture("home-videos", as: BaseItemDtoQueryResult.self)
        let homeVideos = try #require(reply.items).compactMap(ItemMapping.mediaItem(from:))

        #expect(homeVideos.count == 6)
        #expect(homeVideos.allSatisfy { $0.artwork.isWide == true })
        // And with that the **layer** draws wide — that was the reported error: a still frame
        // from the recording in the 2 : 3 poster frame.
        #expect(MediaItem.prefersWideArtwork(in: homeVideos))

        let film = try #require(
            ItemMapping.mediaItem(from: Self.fixture("movie-detail", as: BaseItemDto.self)))
        #expect(film.artwork.isWide == false)
    }

    @Test("Without a value the format stays unchecked instead of tall")
    func imageFormatWithoutInfo() {
        var withoutAnything = BaseItemDto()
        withoutAnything.id = "leer"
        #expect(ItemMapping.wideImage(withoutAnything) == nil)

        // A poster for which the server reports no ratio: unchecked. A `false` would be an
        // assertion here — and in a mixed layer it would overrule the checked entries.
        var withoutRatio = BaseItemDto()
        withoutRatio.imageTags = ["Primary": "abc"]
        #expect(ItemMapping.wideImage(withoutRatio) == nil)
    }

    @Test("Without a poster the image that is shown instead counts as wide")
    func imageFormatWithoutPoster() {
        // The case "Kadim Yol" of 2026-08-22: no poster, only a backdrop image. ``PosterAddress``
        // then shows the backdrop — and that is 16 : 9.
        var backdropOnly = BaseItemDto()
        backdropOnly.backdropImageTags = ["xyz"]
        #expect(ItemMapping.wideImage(backdropOnly) == true)

        var previewOnly = BaseItemDto()
        previewOnly.imageTags = ["Thumb": "abc"]
        #expect(ItemMapping.wideImage(previewOnly) == true)
    }
}
