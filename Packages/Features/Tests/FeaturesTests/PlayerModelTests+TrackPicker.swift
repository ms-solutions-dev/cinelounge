import Core
import CoreGraphics
import DesignSystem
import Foundation
import Testing

@testable import Features

/// Audio and subtitle tracks through the server — switching while holding the position.
extension PlayerModelTests {

    // MARK: - Track choice via the server

    /// Reproduced from "K for Kestrel": two AC3 audio tracks, one text subtitle.
    private static var vendettaMedia: MediaSource {
        MediaSource(
            container: .mkv,
            videoCodec: "h264",
            audioTracks: [
                .init(
                    id: "5", kind: .audio, title: "Deutsch", language: "deu",
                    codec: "ac3", isDefault: true
                ),
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

    private func makeServerManaged(
        subtitleStreamIndex: Int? = nil,
        remux: RemuxSpy = RemuxSpy()
    ) -> (model: PlayerModel, host: HostDouble, source: SourceSpy) {
        let host = HostDouble()
        let source = SourceSpy()
        let media = Self.vendettaMedia
        source.itemToReturn = MediaItem(
            id: "film",
            kind: .movie,
            title: "K wie Kestrel",
            runtime: 6200,
            source: media
        )
        let model = PlayerModel(
            target: PlaybackTarget(
                itemID: "film",
                title: "K wie Kestrel",
                url: URL(string: "https://server/Videos/film/main.m3u8")!,
                decision: PlaybackDecision(
                    engine: .native,
                    delivery: .hls,
                    reason: .containerNotNativelySupported,
                    subtitleStreamIndex: subtitleStreamIndex
                ),
                duration: 6200,
                media: media
            ),
            engine: host,
            source: source,
            remux: remux.builder
        )
        return (model, host, source)
    }

    @Test("With segmented delivery the tracks come from the metadata")
    func serverTracksFeedTheChooser() async {
        // The engine sees only the one packed track — the selection would show
        // "no tracks" for the rest of the movie, although the file carries three.
        let (model, host, _) = makeServerManaged()
        host.engine.status = .playing

        await model.tick()

        #expect(model.audioTracks.map(\.id) == [5, 7])
        #expect(model.subtitleTracks.map(\.id) == [6])
        #expect(model.selectedAudioTrack == 5, "the server's default track is audible")
        #expect(model.selectedSubtitleTrack == nil, "without a choice no subtitle plays")
    }

    @Test("An audio track change becomes a new request at the held position")
    func audioChoiceRestartsAtPosition() async {
        let (model, host, _) = makeServerManaged()
        host.engine.status = .playing
        host.engine.position = 100
        await model.tick()

        model.selectAudioTrack(7)
        // First the rebuild through the server, then the repackager in front of it — both
        // explicitly awaited instead of through rounds of yielding.
        await model.restartTask?.value
        await model.engineStartTask?.value

        // The start is the rebuild: same position, chosen track.
        // (``begin()`` does not run in this check, so the rebuild is the
        // only start.)
        //
        // **The track number has not been part of the decision since 2026-08-11**,
        // and that is no loss: it was an instruction to the
        // server, and nobody asks the server any more for a repackaged file. The choice
        // is now carried through the **language** — the repackager picks out the track
        // itself (see ``MatroskaRemuxer/Options/audioLanguage``).
        #expect(host.started.count == 1)
        #expect(model.target.decision.delivery == .remuxInApp)
        #expect(model.target.preferredAudioLanguage == "eng")
        #expect(model.target.startAt == 100)
        #expect(model.selectedAudioTrack == 7)
    }

    @Test("Selecting and switching off subtitles works without a rebuild")
    func subtitleChoiceNeverRestarts() async {
        // The app draws itself: the track arrives as WebVTT next to the stream,
        // the engine stays untouched. A rebuild would be the old server path that
        // failed on the device — exactly that must not come back.
        let (model, host, _) = makeServerManaged()
        host.engine.status = .playing
        await model.tick()

        model.selectSubtitleTrack(6)
        await model.tick()
        #expect(host.started.isEmpty, "no rebuild for switching on")
        #expect(model.selectedSubtitleTrack == 6, "the choice shows the track immediately")

        model.selectSubtitleTrack(nil)
        await model.tick()
        #expect(host.started.isEmpty, "no rebuild for switching off")
        #expect(model.selectedSubtitleTrack == nil)
        #expect(model.subtitleLine == nil, "no line left on screen")
    }

    @Test("The track choice survives a jump but is dropped with the next episode")
    func trackChoiceSurvivesSeeksButNotEpisodes() async {
        let (model, host, source) = makeServerManaged()
        host.engine.status = .playing
        await model.tick()

        model.selectAudioTrack(7)
        // First the rebuild through the server, then the repackager in front of it — both
        // explicitly awaited instead of through rounds of yielding.
        await model.restartTask?.value
        await model.engineStartTask?.value
        #expect(model.selectedAudioTrack == 7)

        // The next episode is a different file — its track number seven would be
        // something arbitrary. The choice applies per title.
        source.itemToReturn = MediaItem(
            id: "folge-2",
            kind: .episode,
            title: "Folge 2",
            runtime: 1400,
            source: Self.vendettaMedia
        )
        await model.play(
            MediaItem(id: "folge-2", kind: .episode, title: "Folge 2")
        )
        await model.tick()
        #expect(model.selectedAudioTrack == 5, "the server's default track again")
    }

}
