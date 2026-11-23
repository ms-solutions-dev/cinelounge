import Foundation
import Testing

@testable import Core

/// **The board of the four assembly points** (AP58 R4, report A finding S2): start
/// on the TV, next episode, jump via the server and start on the phone all call
/// ``PlaybackPlan/build(title:media:source:preference:device:reason:)``. What stands here
/// therefore applies at all four points — and what one of them used to leave out
/// stands there as a line.
@Suite("Playback plan")
struct PlaybackPlanTests {

    /// An anime episode: three audio tracks, a German SubRip, an English ASS.
    static let media = MediaSource(
        container: .mkv,
        videoCodec: "h264",
        audioTracks: [
            .init(id: "1", kind: .audio, title: "German", language: "deu", codec: "aac", isDefault: true),
            .init(id: "2", kind: .audio, title: "English", language: "eng", codec: "aac"),
            .init(id: "3", kind: .audio, title: "Japanese", language: "jpn", codec: "aac"),
        ],
        subtitleTracks: [
            .init(
                id: "5", kind: .subtitle, title: "German SRT", language: "deu", codec: "subrip",
                subtitleFormat: .subrip),
            .init(
                id: "6", kind: .subtitle, title: "English ASS", language: "eng", codec: "ass",
                subtitleFormat: .ass),
        ],
        bitrate: 20_000_000)

    static func title(state: TimeInterval? = 1_200, anime: Bool = true) -> MediaItem {
        MediaItem(
            id: "folge", kind: .episode, title: "Folge", genres: anime ? ["Anime"] : [],
            runtime: 2_400,
            progress: state.map { PlaybackProgress(position: $0, duration: 2_400) },
            source: media)
    }

    static let jellyfin = PlaybackPlan.Source(canShift: true, isMediaServer: true)
    static let provider = PlaybackPlan.Source(canShift: false, isMediaServer: false)
    static let device = PlaybackPlan.Device(hdr: false, hevc: true)
    static let original = PlaybackPlan.Preference(
        audio: AudioPreference(animeOriginal: true), interfaceLanguage: "de")

    static func plan(
        _ reason: PlaybackPlan.Occasion, title: MediaItem = title(),
        source: PlaybackPlan.Source = jellyfin, preference: PlaybackPlan.Preference = original
    ) -> PlaybackPlan.Plan {
        PlaybackPlan.build(
            title: title, media: media, source: source, preference: preference, device: device,
            reason: reason)
    }

    // MARK: - Start (Fernseher und Telefon)

    @Test("The start resumes at the saved position and picks the start tracks")
    func startResumesAndChooses() {
        let plan = Self.plan(.start(fixed: nil, fromStart: false))
        #expect(plan.startAt == 1_200)
        #expect(plan.decision.startAt == 1_200, "the position goes into the engine choice")
        #expect(plan.audio?.id == "3", "anime in the original audio")
        #expect(plan.subtitles?.id == "5", "subtitles in the interface language")
        #expect(plan.audioLanguage == "jpn", "the language travels along for the remuxer")
        #expect(plan.subtitleLanguage == "deu")
    }

    @Test(
        "Fixed position, from the beginning, almost finished",
        arguments: [
            (PlaybackPlan.Occasion.start(fixed: 300, fromStart: false), 1_200.0, 300.0),
            (.start(fixed: nil, fromStart: true), 1_200, 0),
            (.start(fixed: 0, fromStart: false), 1_200, 0),
            // 97 %: no resuming — the threshold from ``PlaybackProgress/isResumable``.
            (.start(fixed: nil, fromStart: false), 2_330, 0),
        ])
    func startPosition(reason: PlaybackPlan.Occasion, state: TimeInterval, expected: TimeInterval) {
        #expect(Self.plan(reason, title: Self.title(state: state)).startAt == expected)
    }

    @Test("Without the anime marker the audio track stays at the file default")
    func noAnimeNoChoice() {
        let plan = Self.plan(.start(fixed: nil, fromStart: false), title: Self.title(anime: false))
        #expect(plan.audio == nil)
    }

    // MARK: - Nächste Folge

    /// **Until AP58 R4 the next episode on the TV always began at zero**, on the phone at
    /// the position from the server. Now the start rule applies.
    @Test("The next episode starts at the server position, with the same start tracks")
    func nextEpisode() {
        let plan = Self.plan(.nextEpisode(withSubtitles: true))
        #expect(plan.startAt == 1_200)
        #expect(plan.audio?.id == "3")
        #expect(Self.plan(.nextEpisode(withSubtitles: false), title: Self.title(state: nil)).startAt == 0)
    }

    // MARK: - Sprung über den Server

    @Test("A seek keeps the chosen tracks and takes the target position")
    func jumpKeepsTracks() {
        let plan = Self.plan(.jump(from: 1_800, audio: 2, subtitles: 6))
        #expect(plan.startAt == 1_800)
        #expect(plan.audio?.id == "2", "no anime rule on a seek — the choice stands")
        #expect(plan.subtitles?.id == "6")
        #expect(Self.plan(.jump(from: 10, audio: nil, subtitles: nil)).audio == nil)
    }

    // MARK: - Was jede Stelle mitgibt

    /// **The tier only takes effect with Jellyfin as the segmentation** — without it it
    /// would order a conversion that nobody carries out. Until R4 the phone always
    /// assumed Jellyfin and did not pass the tier along at all.
    @Test("Quality level and media server arrive in the engine choice")
    func tierAndMediaServer() {
        let tight = PlaybackPlan.Preference(quality: .fitting(4_000_000), interfaceLanguage: "de")
        let server = Self.plan(.start(fixed: nil, fromStart: false), preference: tight)
        #expect(server.decision.delivery == .hls)
        #expect(server.decision.isBandwidthLimited)
        let provider = Self.plan(
            .start(fixed: nil, fromStart: false), source: Self.provider, preference: tight)
        #expect(provider.decision.delivery == .transcode)
    }

    @Test("The measured line counts like a level")
    func measuredLine() {
        let measured = PlaybackPlan.Preference(measuredBitrate: 3_000_000, interfaceLanguage: "de")
        #expect(
            Self.plan(.start(fixed: nil, fromStart: false), preference: measured).decision.isBandwidthLimited)
    }

    @Test("The screen travels along")
    func hdr() {
        let plan = PlaybackPlan.build(
            title: Self.title(), media: Self.media, source: Self.jellyfin,
            preference: Self.original, device: .init(hdr: true, hevc: true),
            reason: .start(fixed: nil, fromStart: false))
        #expect(plan.decision.displaySupportsHDR)
    }
}
