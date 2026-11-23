import Core
import CoreGraphics
import DesignSystem
import Foundation
import Testing

@testable import Features

/// Times, durations and jumps — what the bar shows and where seeking goes.
extension PlayerModelTests {

    // MARK: - Display

    @Test("The times read as they do in the reference design")
    func timeLabels() {
        // The numbers are taken from the UI template: 08:14 elapsed,
        // −15:46 remaining for a 24-minute runtime. If the construction deviates from that, the
        // bar no longer matches the design.
        #expect(PlayerModel.timeLabel(494) == "08:14")
        #expect(PlayerModel.remainingLabel(position: 494, duration: 1440) == "−15:46")
        // Hours only if there are any — a fixed hours digit would leave a zero in every
        // episode that says nothing.
        #expect(PlayerModel.timeLabel(6127) == "1:42:07")
    }

    @Test("Without a known length there is no remaining time")
    func remainingNeedsDuration() {
        // For a channel and for recordings not yet scanned, the server reports
        // null. "−00:00" would look as if the item were over.
        #expect(PlayerModel.remainingLabel(position: 10, duration: 0) == nil)
        #expect(PlayerModel.remainingLabel(position: 10, duration: -5) == nil)
        // Beyond the end the count does not continue negatively: at the
        // end the engine occasionally reports a position past the runtime.
        #expect(PlayerModel.remainingLabel(position: 1500, duration: 1440) == "−00:00")
    }

    @Test("A backward jump and a nonsensical position stay within the film")
    func seekStaysInsideFilm() async {
        // Jumping beyond the end ends playback with both engines,
        // and the title counts as watched afterwards. One keypress too many at the end
        // would thus have a consequence nobody expects.
        let (model, host, _) = make(duration: 1000)

        // Short hops go to the engine — those are the two skip buttons.
        model.skip(by: -60)
        #expect(host.engine.seeks.last == 0)

        // The long jump goes through the server and therefore does not reach the engine.
        // It is clamped anyway, and at the same place: the display stands on
        // the last point in the movie, not on the nonsensical number.
        model.seek(to: 99_999)
        #expect(model.position == 998)
    }

    @Test("If the picture stalls without an error, the wait ends in an explanation")
    func standstillBecomesAMessage() async {
        // **The case that was silent until now.** Neither VLC nor the system player report
        // anything when they make no progress — they report nothing at all, and the spinner
        // turns forever. The concept of this app says the opposite: every
        // wait ends in a result or a message.
        let (model, host, _) = make()
        host.engine.status = .playing
        host.engine.position = 40

        await model.tick()
        #expect(!model.isStalled)

        // The position no longer moves. Up to the limit it stays quiet — what
        // recovers does so well below it, and a message at every buffering pause would be
        // worse than none.
        for _ in 1..<PlayerModel.stallTicks {
            await model.tick()
        }
        #expect(!model.isStalled, "nothing is claimed before the threshold")

        await model.tick()
        #expect(model.isStalled)
        // The bar comes along: a hint one cannot see is none.
        #expect(model.isBarVisible)

        // And as soon as playback continues, the message disappears by itself — without
        // the viewer having to dismiss it.
        host.engine.position = 41
        await model.tick()
        #expect(!model.isStalled)
    }

    @Test("A pause is not a stall")
    func pauseIsNotAStall() async {
        // Otherwise after twelve seconds of pause the message "nothing is arriving" would stand over
        // a picture the viewer paused themselves.
        let (model, host, _) = make()
        host.engine.status = .paused
        host.engine.position = 40

        for _ in 0...PlayerModel.stallTicks {
            await model.tick()
        }
        #expect(!model.isStalled)
    }

    @Test("Short jumps stay with the engine, long ones go through the server")
    func longSeeksGoThroughTheServer() async {
        // **The reason has been measured against our own catalog.** In a raw
        // delivered Matroska file a jump needs its seek index, and that
        // lies at the end of the file — for the checked episode 796 MB away. Short hops
        // land in the already loaded buffer and succeed; everything beyond stalls,
        // with a black picture and no error message. Ten and thirty
        // seconds ran flawlessly, several minutes never.
        let (model, host, _) = make(duration: 3600)
        host.engine.status = .playing

        model.seek(to: 60)
        #expect(host.engine.seeks.last == 60, "one minute still belongs to the engine")

        model.seek(to: 1800)
        #expect(
            host.engine.seeks.last == 60,
            "half an hour further the engine must not seek by itself"
        )
        #expect(model.position == 1800, "the display still follows immediately")
    }

    @Test("With HLS EVERY jump stays with the engine — even across the whole film")
    func hlsSeeksAlwaysStayLocal() async {
        // The playlist covers the full runtime: the engine requests the
        // target segment, and the server restarts its ffmpeg there on its own.
        // Re-requesting the list would be nothing but waiting time — and the way back
        // into the old bug, in which every new address triggered a new
        // encoding.
        let (model, host, _) = make(duration: 7200, delivery: .hls)
        host.engine.status = .playing

        model.seek(to: 3000)

        #expect(host.engine.seeks.last == 3000, "the engine jumps, not the server")
        #expect(model.position == 3000)
    }

    @Test("Within the loaded range even a long jump stays with the engine")
    func seeksInsideTheBufferStayLocal() async {
        // The fallback path for engines on a repackaged stream: what is already
        // loaded, the engine reaches immediately. Re-requesting would be pure
        // waiting time here — the server would re-encode what is long since on the device.
        let (model, host, _) = make(duration: 7200, delivery: .remux)
        host.engine.status = .playing
        host.engine.bufferedRange = 0...600

        model.seek(to: 400)

        #expect(host.engine.seeks.last == 400, "four hundred seconds away, but loaded")
        #expect(model.position == 400)
    }

    @Test("Outside the loaded range even a short jump goes through the server")
    func seeksOutsideTheBufferRestart() async {
        // The fixed jump distance of the past did not know the buffer: ninety
        // seconds ahead counted as "local" even if only ten were loaded — and the
        // engine then waited for the stream to catch up to that point. The
        // limit is the buffer, not the distance.
        let (model, host, _) = make(duration: 7200, delivery: .remux)
        host.engine.status = .playing
        host.engine.bufferedRange = 0...100
        host.engine.position = 90
        await model.tick()

        model.seek(to: 150)

        #expect(host.engine.seeks.isEmpty, "fifty seconds away, but not loaded")
        #expect(model.position == 150, "the display already sits at the target")
    }

    @Test("For an unchanged file the system engine seeks by itself everywhere")
    func directPlaySeeksLocally() async {
        // With unmodified delivery the server answers range queries —
        // the engine fetches the target position itself, and immediately. Re-requesting
        // would cost the server an ffmpeg run for nothing.
        let (model, host, _) = make(duration: 7200, delivery: .directPlay)
        host.engine.status = .playing
        host.engine.bufferedRange = 0...100

        model.seek(to: 3000)

        #expect(host.engine.seeks.last == 3000)
    }

    @Test("Fast scrubbing starts exactly one rebuild — the last one")
    func rapidSeeksCollapseIntoOneRestart() async {
        // Two long jumps in quick succession used to mean two parallel
        // rebuilds: two encodings on the server, two engine starts, and which one
        // won was decided by chance. The new jump cancels the running one.
        let (model, host, source) = make(duration: 7200, delivery: .remux)
        source.itemToReturn = MediaItem(
            id: "film",
            kind: .movie,
            title: "Zirkel der Uhrmacher",
            runtime: 7200,
            source: MediaSource(container: .mkv, audioTracks: [], subtitleTracks: [])
        )
        host.engine.status = .playing

        model.seek(to: 3000)
        model.seek(to: 5000)

        // The tasks run on the main actor; a few rounds of yielding
        // let the surviving rebuild arrive.
        for _ in 0..<50 where host.started.isEmpty { await Task.yield() }

        #expect(host.started.count == 1, "the first jump was overtaken and discarded")
        // The rebuild decides anew — and lands on HLS for the MKV: there
        // the player jumps itself, so the target carries the point as its own
        // start request. The last request won. (The server offset no longer
        // exists since the VLC removal, AP8.)
        #expect(model.target.startAt == 5000)
        #expect(model.target.decision.delivery == .remuxInApp)
    }

    @Test("During the jump the tick does not pull the display back")
    func restartDoesNotFightTheTicker() async {
        // Until the switch, the old engine still reports from the abandoned position.
        // If the tick took it over, the bar would first jump back and, after the
        // switch, forward again — exactly the twitch that unsettles when seeking.
        let (model, host, source) = make(duration: 7200, delivery: .remux)
        source.itemToReturn = MediaItem(
            id: "film",
            kind: .movie,
            title: "Zirkel der Uhrmacher",
            runtime: 7200,
            source: MediaSource(container: .mkv, audioTracks: [], subtitleTracks: [])
        )
        host.engine.status = .playing

        model.seek(to: 3000)
        host.engine.position = 12
        await model.tick()

        #expect(model.position == 3000)
    }

    @Test("The server's length beats a growing engine length")
    func metadataDurationBeatsTheEngine() async {
        // A playlist the server is still writing reports to the engine, at best,
        // the part delivered so far. A bar built from that would show the
        // movie constantly as "almost over".
        let (model, host, _) = make(duration: 3600, delivery: .hls)
        host.engine.status = .playing
        host.engine.duration = 500

        await model.tick()

        #expect(model.duration == 3600)
    }

    @Test("With an unknown length the bar sits at zero rather than at something arbitrary")
    func fractionWithoutDuration() async {
        let (model, host, _) = make(kind: .live, itemID: nil, duration: nil)
        host.engine.status = .playing
        host.engine.position = 600
        await model.tick()

        // A fraction without a length cannot be formed. Guessed, the track would look as if
        // the show were almost over.
        #expect(model.fraction == 0)
        #expect(model.remainingLabel == nil)
    }

    @Test("The server's length is not overwritten by a zero from the engine")
    func durationSurvivesEmptyEngine() async {
        // Before opening, the engine reports null. Whoever takes that over lets the bar
        // jump back from its end position to null as soon as the next tick arrives.
        let (model, host, _) = make(duration: 1440)
        host.engine.duration = 0
        await model.tick()

        #expect(model.duration == 1440)
    }

    // MARK: - Chapters

    @Test("The chapter buttons jump by the verified rules")
    func chapterJumpsUseTheRules() async {
        let host = HostDouble()
        let model = PlayerModel(
            target: PlaybackTarget(
                itemID: "film",
                title: "Film",
                url: URL(string: "https://server/Videos/film/main.m3u8")!,
                decision: PlaybackDecision(engine: .native, delivery: .hls, reason: .nativeContainer),
                duration: 5400,
                chapters: [
                    Chapter(start: 0), Chapter(start: 600), Chapter(start: 1800),
                ],
                kind: .recording
            ),
            engine: host,
            source: SourceSpy()
        )
        host.engine.status = .playing
        host.engine.position = 100
        await model.tick()

        #expect(model.hasChapters)

        model.jumpToChapter(forward: true)
        #expect(host.engine.seeks.last == 600, "forward to the next start")

        // Back shortly after the start: the grace period leads to the start before it.
        host.engine.position = 602
        await model.tick()
        model.jumpToChapter(forward: false)
        #expect(host.engine.seeks.last == 0)

        // Without chapters there are neither buttons nor jumps — that case is the rule.
        let (bare, bareHost, _) = make()
        bareHost.engine.status = .playing
        #expect(!bare.hasChapters)
        bare.jumpToChapter(forward: true)
        #expect(bareHost.engine.seeks.isEmpty)
    }

}
