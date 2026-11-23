import Testing

@testable import Core

@Suite("Probe") struct ProbeSuite {
    @Test("Hollowmark with real values") func real() {
        let source = MediaSource(
            container: .mkv,
            videoCodec: "h264",
            videoRange: .sdr,
            audioTracks: [
                MediaTrack(id: "1", kind: .audio, title: "Deutsch", language: "deu", codec: "aac"),
                MediaTrack(id: "2", kind: .audio, title: "English", language: "eng", codec: "aac"),
                MediaTrack(id: "3", kind: .audio, title: "日本語", language: "jpn", codec: "aac"),
            ],
            subtitleTracks: [],
            supportsDirectPlay: true,
            bitrate: 5_603_445,
            isInterlaced: false
        )
        print("PROBE canRemux(HEVC yes):", PlaybackEngineSelector.canRemuxInApp(source, canDecodeHEVC: true))
        print(
            "PROBE canRemux(HEVC no):", PlaybackEngineSelector.canRemuxInApp(source, canDecodeHEVC: false))
        let d1 = PlaybackEngineSelector.decide(for: source, hasMediaServer: true, canDecodeHEVC: false)
        print("PROBE without HEVC:", d1.engine, d1.delivery, d1.reason, "limit:", d1.isBandwidthLimited)
        let d2 = PlaybackEngineSelector.decide(for: source, hasMediaServer: true, canDecodeHEVC: true)
        print("PROBE with HEVC:", d2.engine, d2.delivery, d2.reason)
        // With a chosen audio track, as in the player
        let d3 = PlaybackEngineSelector.decide(
            for: source, audioTrack: source.audioTracks[0], hasMediaServer: true, canDecodeHEVC: false)
        print("PROBE with audio track:", d3.engine, d3.delivery, d3.reason)
    }
}
