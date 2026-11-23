import Core
import Foundation
import Testing

@testable import Playback

/// What is checked is whether the engine choice matches what the engines can
/// actually do.
///
/// That is the point of these checks at this place: the rule lives in `Core` and knows
/// nothing of VLC or the system player. Here, where both engines live, it is
/// cross-checked that the rule demands nothing the chosen engine does not deliver.
@Suite("Engine choice against the engines")
struct EngineChoiceTests {

    private func source(
        container: MediaSource.Container,
        videoRange: MediaSource.VideoRange = .sdr,
        audioTracks: Int = 1,
        subtitles: [MediaSource.SubtitleFormat] = []
    ) -> MediaSource {
        MediaSource(
            container: container,
            videoCodec: "h264",
            videoRange: videoRange,
            audioTracks: (0..<audioTracks).map { index in
                MediaTrack(id: "a\(index)", kind: .audio, title: "", language: "deu", codec: "aac")
            },
            subtitleTracks: subtitles.enumerated().map { index, format in
                MediaTrack(
                    id: "s\(index)",
                    kind: .subtitle,
                    title: "",
                    language: "deu",
                    subtitleFormat: format
                )
            },
            supportsDirectPlay: true
        )
    }

    /// **Matroska has gone to the system player since 2026-08-10** — just not raw. It cannot
    /// open the container; if such a file went to it unchanged, the screen would stay
    /// black. So the app swaps the wrapper beforehand: picture and sound pass through
    /// untouched, and what arrives at the engine is a playlist it knows.
    @Test("Matroska never goes raw to the system player")
    func matroskaNeverNativeRaw() {
        let decision = PlaybackEngineSelector.decide(for: source(container: .mkv))

        #expect(decision.delivery == .remuxInApp)
        #expect(decision.delivery != .directPlay, "raw, the screen would stay black")
    }

    @Test("ASS-format subtitles cost no detour")
    func assSubtitlesCostNoDetour() {
        // Since the VLC removal (2026-08-16) there is no second engine any more — what is drawn
        // is what the own renderer can do (ASS/PGS); the VobSub remainder stands as a task
        // in the roadmap.
        //
        // **What is checked is therefore the path** (AP8, added 2026-09-02): an MP4 with an ASS
        // track goes out unchanged, instead of running via server or remuxer just because a
        // subtitle is in it.
        let decision = PlaybackEngineSelector.decide(
            for: source(container: .mp4, subtitles: [.ass]),
            wantsSubtitles: true
        )

        #expect(decision.delivery == .directPlay)
    }

    @Test("Dolby Vision goes out unchanged, and the reason says so")
    func dolbyVisionIsDeliveredUntouched() {
        // Dolby Vision was the reason the second engine never came into question: it did not
        // output the dynamic metadata on tvOS. What remains is the rule that nothing is
        // changed on such a title — and the reason that names it.
        let decision = PlaybackEngineSelector.decide(
            for: source(container: .mp4, videoRange: .dolbyVision)
        )

        #expect(decision.delivery == .directPlay)
        #expect(decision.reason == .dolbyVisionNeedsNative)
    }

    @Test("Dolby Vision in the wrong container is repackaged, not transcoded")
    func dolbyVisionRemuxed() {
        // Converting would lose exactly the metadata in question — and cost the server
        // compute time.
        let decision = PlaybackEngineSelector.decide(
            for: source(container: .mkv, videoRange: .dolbyVision)
        )

        #expect(decision.delivery == .remux)
    }

    @Test("A plain movie without special requests goes native")
    func simpleFileNative() {
        // Because of hardware decoding, Picture in Picture and AirPlay.
        let decision = PlaybackEngineSelector.decide(for: source(container: .mp4))

        #expect(decision.delivery == .directPlay)
    }

    @Test("Every decision carries its reason")
    func decisionsAreTraceable() {
        // Expressly in the result, so that a wrong playback can be traced back later without
        // having to rethink the rule.
        let cases = [
            source(container: .mkv),
            source(container: .mp4, videoRange: .dolbyVision),
            source(container: .mp4),
        ]

        for entry in cases {
            let decision = PlaybackEngineSelector.decide(for: entry)
            #expect(!decision.reason.rawValue.isEmpty)
        }
    }

    @Test("The trailer from the own collection ends up with VLC")
    func trailerGoesToVLC() {
        // The real case: the local trailers in the catalog are MKV with HEVC. Exactly
        // for that reason trailer playback cannot be built with the simple system player —
        // it needs the same engine as the main film.
        let trailer = MediaSource(
            container: .mkv,
            videoCodec: "hevc",
            videoRange: .sdr,
            audioTracks: [
                MediaTrack(id: "a0", kind: .audio, title: "", language: "deu", codec: "aac")
            ],
            subtitleTracks: [],
            supportsDirectPlay: true
        )

        // The trailer too is now remuxed instead of handed to the second engine — the
        // hardware can do HEVC and AAC, only the wrapper is missing.
        let decision = PlaybackEngineSelector.decide(for: trailer)
        #expect(decision.delivery == .remuxInApp)
    }
}
