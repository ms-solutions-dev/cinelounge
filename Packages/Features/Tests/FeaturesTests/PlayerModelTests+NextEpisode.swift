import Core
import CoreGraphics
import DesignSystem
import Foundation
import Testing

@testable import Features

/// The next episode and the similar title — the flow after the end.
extension PlayerModelTests {

    // MARK: - Next episode

    @Test("The next episode is offered with a countdown and can be dismissed")
    func nextUpCanBeDismissed() async {
        // With anime the song is in the credits, with series the preview. Whoever wants to see
        // that must not be dragged along — without dismissing, the offer would be a
        // compulsion.
        let (model, host, source) = make(duration: 1400)
        source.segmentsToReturn = [
            MediaSegment(id: "outro", kind: .outro, start: 1360, end: 1400)
        ]
        source.nextEpisodeToReturn = MediaItem(id: "f2", kind: .episode, title: "Folge 2")
        await model.loadContext()

        // Five seconds of credits, in the tick of playback. The position alone no longer suffices
        // since the counter's own reference point — see ``play(_:_:from:seconds:)``.
        await play(model, host, from: 1360, seconds: 5)

        #expect(model.nextUp?.secondsLeft == 5)
        #expect(model.nextUp?.shouldAdvance == false)

        model.dismissNextUp()
        #expect(model.nextUp == nil)

        host.engine.position = 1370
        await model.tick()
        #expect(model.nextUp == nil, "dismissed means dismissed, even five seconds later")
    }

    @Test("Without a next episode there is no offer")
    func noNextEpisodeNoOffer() async {
        // Every movie and every last episode of a season falls under this. An offer
        // without a target would do nothing on a press.
        let (model, host, source) = make(duration: 1400)
        source.segmentsToReturn = [
            MediaSegment(id: "outro", kind: .outro, start: 1360, end: 1400)
        ]
        await model.loadContext()

        host.engine.status = .playing
        host.engine.position = 1380
        await model.tick()

        #expect(model.nextUp == nil)
    }

    @Test("The switch goes through the remuxer and not around it")
    func adoptRunsThroughTheRemuxer() async {
        // **The bug that no check could see** (on-device test 2026-08-11):
        // ``PlayerModel/begin()`` went through the repackager, ``adopt(_:)`` called the
        // engine directly. Every rebuild — long jump, channel switch,
        // next episode — thereby passed the raw Matroska on to AVFoundation,
        // which does not open it. On the TV: "starts, no longer works after
        // seeking". In the log a single missing line distinguished the two cases.
        //
        // What is checked is therefore the address that arrives at the engine — not THAT
        // it starts. Exactly this distinction was missing.
        let remux = RemuxSpy()
        let (model, host, source) = make(duration: 1400, remux: remux)
        source.nextEpisodeToReturn = MediaItem(id: "f2", kind: .episode, title: "Folge 2")
        source.itemToReturn = MediaItem(
            id: "f2",
            kind: .episode,
            title: "Folge 2",
            runtime: 1400,
            source: MediaSource(container: .mkv, audioTracks: [], subtitleTracks: [])
        )
        await model.loadContext()

        await play(model, host, from: 1360, seconds: NextUpPrompt.countdown)
        await model.engineStartTask?.value

        #expect(model.target.decision.delivery == .remuxInApp)
        // The repackager was asked with the server address …
        #expect(remux.asked.count == 1)
        #expect(remux.asked.first?.host == "server")
        // … and what the engine got is the local playlist.
        #expect(host.started.last?.url.host == "127.0.0.1")
    }

    @Test("The next episode takes over without an engine change and with a new countdown")
    func advanceStartsFreshTarget() async {
        // Two traps in one: the decision must get ALL the details of the first start
        // again — before, the media server switch was missing, and an episode two present as
        // an MKV fell back to VLC with raw Matroska in the middle of the series,
        // with all the proven bugs of that path. And the counter
        // must be new: the old one has signed off and stays silent for good, so the
        // new episode would never appear under "Continue Watching".
        let (model, host, source) = make(duration: 1400)
        source.nextEpisodeToReturn = MediaItem(id: "f2", kind: .episode, title: "Folge 2")
        source.itemToReturn = MediaItem(
            id: "f2",
            kind: .episode,
            title: "Folge 2",
            parentTitle: "Hollowmark",
            seasonNumber: 1,
            episodeNumber: 2,
            runtime: 1400,
            source: MediaSource(container: .mkv, audioTracks: [], subtitleTracks: [])
        )
        await model.loadContext()

        // The switch happens in the tick and not on demand: the counter is queried at every
        // position report, and at zero the time is up. Without a reported
        // credits section the trigger point lies forty seconds before the end, i.e. at 1360;
        // from there to expiry it is ten seconds of movie played. A single
        // report of 1399 no longer does it since the counter's own reference point —
        // it used to stand for "the time is up", and exactly this equation was the
        // finding.
        await play(model, host, from: 1360, seconds: NextUpPrompt.countdown)
        // The MKV goes through the repackager, and it builds up — it is awaited
        // explicitly and not through rounds of yielding.
        await model.engineStartTask?.value

        #expect(model.target.itemID == "f2")
        // The MKV goes chunked to the same engine as episode one — an
        // engine switch in the middle of the series would be exactly the old bug.
        #expect(model.target.decision.delivery == .remuxInApp)
        #expect(host.started.last?.itemID == "f2")
        #expect(model.target.subtitle == "Hollowmark · \(EpisodeIdentifier.text(season: 1, episode: 2))")
        // The old title was signed off, and exactly once.
        #expect(source.ended.map(\.itemID) == ["film"])

        host.engine.status = .playing
        host.engine.position = 5
        await model.tick()
        #expect(source.begun == ["film", "f2"], "the new episode needs its own registration")
    }

    @Test("A dismissed offer still lets the view close at the end")
    func dismissedOfferStillClosesAtEnd() async {
        // Whoever wants to see the credits dismisses the offer — and still has
        // a next episode afterwards. If closing depends on whether there is one, the
        // view stays on a black picture with a standing bar, and the way back
        // can only be guessed through the menu button.
        let (model, host, source) = make(duration: 1400)
        source.segmentsToReturn = [
            MediaSegment(id: "outro", kind: .outro, start: 1360, end: 1400)
        ]
        source.nextEpisodeToReturn = MediaItem(id: "f2", kind: .episode, title: "Folge 2")
        await model.loadContext()

        host.engine.status = .playing
        host.engine.position = 1365
        await model.tick()
        model.dismissNextUp()

        host.engine.status = .ended
        await model.tick()

        #expect(model.shouldClose)
        #expect(model.target.itemID == "film", "dismissed means: no switch")
    }

    @Test("At the end the switch happens without waiting for the rest of the countdown")
    func endAdvancesWithoutWaitingForCountdown() async {
        // Some files end a few seconds before the reported runtime. The counter
        // counts at the position in the movie, and that does not advance after the end —
        // whoever waits for its expiry sits forever on a black picture with
        // "Next episode in 4 s".
        let (model, host, source) = make(duration: 1400)
        source.segmentsToReturn = [
            MediaSegment(id: "outro", kind: .outro, start: 1360, end: 1400)
        ]
        source.nextEpisodeToReturn = MediaItem(id: "f2", kind: .episode, title: "Folge 2")
        source.itemToReturn = MediaItem(
            id: "f2",
            kind: .episode,
            title: "Folge 2",
            runtime: 1400,
            source: MediaSource(container: .mp4, audioTracks: [], subtitleTracks: [])
        )
        await model.loadContext()

        host.engine.status = .playing
        host.engine.position = 1366
        await model.tick()
        #expect(model.nextUp?.shouldAdvance == false, "the countdown is still running")

        host.engine.status = .ended
        await model.tick()

        #expect(model.target.itemID == "f2")
        #expect(!model.shouldClose)
    }

    @Test("If the switch fails, the view closes instead of staying on a black screen")
    func failedAdvanceClosesView() async {
        // The server can know the next episode and still not hand out an address
        // for it — for instance for a file it technically knows nothing about. If
        // closing depends on whether there is a successor, nothing happens afterwards
        // any more: no switch, no closing, and the way back can only
        // be guessed through the menu button.
        let (model, host, source) = make(duration: 1400)
        source.nextEpisodeToReturn = MediaItem(id: "f2", kind: .episode, title: "Folge 2")
        // Without ``SourceSpy/itemToReturn`` there are no technical details for the next
        // episode, and without those no target arises.
        await model.loadContext()

        // As above in the tick and not with a single position: the counter must
        // really expire for the switch to be attempted at all.
        await play(model, host, from: 1360, seconds: NextUpPrompt.countdown)
        #expect(model.target.itemID == "film", "without a target there is no switch")
        #expect(model.nextEpisode != nil, "the successor is known — just not playable")

        host.engine.status = .ended
        await model.tick()

        #expect(model.shouldClose)
    }

    @Test("A jump past the countdown window does not switch the episode immediately")
    func jumpOverCountdownStillCounts() async {
        // At the end of a movie a jump is the normal case. Without a reference point of its own,
        // a single press of +30 shortly before the credits gives `secondsLeft` of
        // zero, and the next tick — half a second later — switches: no
        // counter on screen, no chance to cancel. Whoever still wanted to look something
        // up at the end sits in the next episode.
        let (model, host, source) = make(duration: 1400)
        source.segmentsToReturn = [
            MediaSegment(id: "outro", kind: .outro, start: 1360, end: 1400)
        ]
        source.nextEpisodeToReturn = MediaItem(id: "f2", kind: .episode, title: "Folge 2")
        source.itemToReturn = MediaItem(
            id: "f2",
            kind: .episode,
            title: "Folge 2",
            runtime: 1400,
            source: MediaSource(container: .mp4, audioTracks: [], subtitleTracks: [])
        )
        await model.loadContext()

        host.engine.status = .playing
        host.engine.position = 1355
        await model.tick()
        #expect(model.nextUp == nil, "there is no offer before the credits")

        // A press of +30 carries beyond the whole window.
        model.skip(by: 30)
        host.engine.position = model.position
        await model.tick()

        #expect(model.nextUp?.secondsLeft == 10, "the countdown starts instead of being expired")
        #expect(model.target.itemID == "film", "and no switch happens yet")

        // And from there it really counts down, instead of staying at ten
        // — a counter that does not expire would be only the other half of the
        // bug.
        await play(model, host, from: 1385, seconds: 5)
        #expect(model.nextUp?.secondsLeft == 5)
        #expect(model.target.itemID == "film")
    }

    @Test("The next episode starts with its own countdown")
    func advanceResetsCountdown() async {
        // The switch happens at the end of the counter, so at zero. If it stayed,
        // it would stand at zero again at once for the new episode — and as soon as its
        // credits are reached, the viewer would be dragged on without a counter. In a
        // season this continues through every episode.
        let (model, host, source) = make(duration: 1400)
        source.segmentsToReturn = [
            MediaSegment(id: "outro", kind: .outro, start: 1360, end: 1400)
        ]
        source.nextEpisodeToReturn = MediaItem(id: "f2", kind: .episode, title: "Folge 2")
        source.itemToReturn = MediaItem(
            id: "f2",
            kind: .episode,
            title: "Folge 2",
            runtime: 1400,
            source: MediaSource(container: .mp4, audioTracks: [], subtitleTracks: [])
        )
        await model.loadContext()

        await play(model, host, from: 1360, seconds: NextUpPrompt.countdown)

        #expect(model.target.itemID == "f2", "the countdown has expired")
        #expect(model.nextUp == nil, "the new episode starts without an offer")

        // The new episode carries the same sections — the double returns them for every
        // ID. At the start of its credits the counter must again stand at ten
        // and not at zero, where the old one left off.
        await play(model, host, from: 1360, seconds: 0)
        #expect(model.nextUp?.secondsLeft == 10)
    }

    // MARK: - Similar film after the end

    @Test("After a film a similar title is on offer — honestly labelled")
    func movieGetsSimilarOffer() async {
        // Movies have no next episode; the offer was nevertheless called
        // "Next episode" there and stayed empty. Now the related title takes
        // the same place, and the label says what it is.
        let host = HostDouble()
        let source = SourceSpy()
        source.similarToReturn = MediaItem(id: "wiredancer-2", kind: .movie, title: "Wire-Dancer 2")

        let model = PlayerModel(
            target: PlaybackTarget(
                itemID: "wiredancer",
                title: "Wire-Dancer",
                url: URL(string: "https://server/Videos/wiredancer/main.m3u8")!,
                decision: PlaybackDecision(
                    engine: .native, delivery: .hls, reason: .containerNotNativelySupported
                ),
                duration: 7200,
                kind: .recording
            ),
            engine: host,
            source: source
        )

        await model.loadContext()

        #expect(model.nextEpisode?.id == "wiredancer-2")
        #expect(model.nextIsSimilar)
    }

    @Test("For an episode it stays the next episode, not a similar title")
    func episodeKeepsItsSuccessor() async {
        let (model, _, source) = make()
        source.nextEpisodeToReturn = MediaItem(id: "f2", kind: .episode, title: "Folge 2")
        source.similarToReturn = MediaItem(id: "fremd", kind: .movie, title: "Etwas anderes")

        await model.loadContext()

        #expect(model.nextEpisode?.id == "f2")
        #expect(!model.nextIsSimilar)
    }

}
