import Core
import CoreGraphics
import DesignSystem
import Foundation
import Testing

@testable import Features

/// Live operation: channel switch, startup measurement, dropout, zapping and fallbacks.
extension PlayerModelTests {

    // MARK: - Channel switch across the remuxer

    /// **The finding of 2026-08-11: pressing up and down no longer navigates
    /// between channels.**
    ///
    /// The cause was not in the operation but in the target: as soon as the
    /// repackager is up, ``PlaybackTarget/url`` points to `127.0.0.1`. That was what
    /// got asked — and this address appears nowhere in the channel list, so
    /// there was no neighbor and nothing happened. Now the question is asked with
    /// ``PlaybackTarget/sourceURL``.
    @Test("The neighbour is looked up by origin, not by engine address")
    func neighbourIsAskedWithTheOrigin() async {
        let channels = URL(string: "http://anbieter/live/1234.m3u8")!
        let asked = Asked()
        let host = HostDouble()
        let remux = RemuxSpy()

        let model = PlayerModel(
            target: PlaybackTarget(
                itemID: nil,
                title: "TELVE 1 HEVC",
                url: channels,
                decision: PlaybackDecision(
                    engine: .native, delivery: .remuxInApp, reason: .nativeContainer),
                kind: .live
            ),
            engine: host,
            source: SourceSpy(),
            neighbourChannel: { url, _ in
                asked.urls.append(url)
                return nil
            },
            remux: remux.builder
        )

        await model.begin()
        await model.engineStartTask?.value

        // The repackager is up: the engine plays from the loopback …
        #expect(model.target.url.host == "127.0.0.1")
        // … and the origin is still the channel.
        #expect(model.target.sourceURL == channels)

        model.switchChannel(by: 1)
        #expect(asked.urls == [channels])
    }

    /// A memo for the addresses that were asked for.
    @MainActor
    final class Asked {
        var urls: [URL] = []
    }

    // MARK: - The startup measurement and the honest picture mark

    /// **The finding from AP5: the "first picture" mark fired too early.**
    ///
    /// `hasVideoOutput` is already set on the system player when it has merely read the
    /// metadata — the measurement called that "first picture" and was
    /// thereby half blind. This check nails down that the announced
    /// picture size no longer sets the mark.
    @Test("The announced picture size no longer sets the picture mark")
    func announcedSizeDoesNotMarkTheFirstFrame() async {
        let (model, host, _) = make()
        await model.begin()
        await model.engineStartTask?.value

        host.engine.status = .playing
        // **Readiness is a report of its own, not a by-product of "playing".**
        // Until 2026-08-26. `status = .playing` was enough here, because the mark came from
        // the same sample as the first picture — exactly the bug that kept the
        // "first picture" column at null in 156 of 156 measurements. Now
        // the engine stamps it in the event, and the double has to do the same.
        host.engine.readyToPlayAt = Date()
        // The lie of the system player, reproduced: size known, nothing drawn.
        host.engine.hasVideoOutput = true
        host.engine.firstFrameVisible = false

        let done = model.sampleStartup(now: Date())

        #expect(done == false, "the measurement continues until a picture really stands")
        #expect(model.startupTiming?.isComplete == false)
        // "Ready", by contrast, is rightly set — the engine reported it.
        #expect(model.startupTiming?.readyAt != nil)
    }

    @Test("The drawn picture sets the picture mark")
    func visibleFrameMarksTheFirstFrame() async {
        let (model, host, _) = make()
        await model.begin()
        await model.engineStartTask?.value

        host.engine.status = .playing
        host.engine.firstFrameVisible = true

        let done = model.sampleStartup(now: Date())

        #expect(done, "with the picture the measurement is complete")
        #expect(model.startupTiming?.isComplete == true)
    }

    /// Engines without a report — VLC before the first picture, the system engine without an
    /// attached surface — keep the measurement open instead of falsifying it.
    @Test("Without information the measurement stays open")
    func missingVerdictKeepsTheMeasurementOpen() async {
        let (model, host, _) = make()
        await model.begin()
        await model.engineStartTask?.value

        host.engine.status = .playing
        host.engine.firstFrameVisible = nil

        let done = model.sampleStartup(now: Date())

        #expect(done == false)
        #expect(model.startupTiming?.isComplete == false)
    }

    // MARK: - Disconnect during live playback

    /// - Parameter rohstromablage: **A store of its own per check** (2026-09-11).
    ///
    /// Until then ``PlayerModel`` took the memo of the raw streams hard-wired through
    /// `SecureStore()` — that is, from the **real** Keychain. Three checks here
    /// therefore had to use it and heal it afterwards; Swift Testing runs
    /// concurrently, and so the `save` of one overwrote the entry of another.
    ///
    /// **It was visible only in the release build and only in the full run.** Called
    /// alone, each of the three was always green — the kind of bug one looks for
    /// in the wrong place. Now each has its own memo, and none heals anything any more.
    /// Waits **until** the rebuild has happened — at most twenty seconds.
    ///
    /// **Five were not enough in the parallel full run** (2026-09-28): sequentially everything was
    /// green, in parallel the main thread stood so long at other checks that the app's 400 ms
    /// came up only after seconds. With twenty the parallel run is green too —
    /// congestion, not a bug of the app.
    ///
    /// **Instead of a fixed 700 ms** (2026-09-28): the app waits 400 ms for the mark from the
    /// error log. At the end of the full run, when a hundred and twenty checks stand around the
    /// main thread, the 300 ms of slack did not always suffice, and which build of the
    /// test program was unlucky was chance. The same thing is still checked; only the deadline
    /// no longer depends on luck.
    @MainActor
    static func wait(_ condition: @MainActor () -> Bool) async {
        let end = Date().addingTimeInterval(20)
        while !condition(), Date() < end {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func liveRemuxModel(
        remux: RemuxSpy,
        channels: URL = URL(string: "http://anbieter/live/1234.m3u8")!,
        rawStreamStore: any KeyValueStore = InMemoryStore()
    ) -> (PlayerModel, HostDouble) {
        let host = HostDouble()
        let model = PlayerModel(
            target: PlaybackTarget(
                itemID: nil,
                title: "TELVE 1 HEVC",
                url: channels,
                decision: PlaybackDecision(
                    engine: .native, delivery: .remuxInApp, reason: .nativeContainer),
                kind: .live
            ),
            engine: host,
            source: SourceSpy(),
            remux: remux.builder,
            rawStreamStore: rawStreamStore
        )
        return (model, host)
    }

    /// **The stall case from AP1 (`-12888`):** if the feed stands for longer
    /// than one and a half segment lengths, AVFoundation discards the playback target —
    /// the silent rebuild of the connection alone does not rescue that. A
    /// channel that **was running** gets the same path set up again instead of a
    /// switch of path: three seconds of broadcast pause are no reason to create a permanently
    /// wrong memory.
    @Test("A drop after a running picture rebuilds the same route")
    func failureAfterPlaybackRebuildsTheSamePath() async {
        let remux = RemuxSpy()
        let (model, host) = liveRemuxModel(remux: remux)

        await model.begin()
        await model.engineStartTask?.value
        #expect(remux.asked.count == 1)

        host.engine.status = .playing
        await model.tick()

        host.engine.status = .failed
        await model.tick()
        // The rebuild waits a moment for the mark from the
        // error log (see ``PlayerModel/noteEngineFailure``).
        await Self.wait { remux.asked.count >= 2 }
        await model.engineStartTask?.value

        // The repackager was rebuilt — from the source, not from the
        // dead loopback.
        #expect(remux.asked.count == 2)
        #expect(remux.asked.last?.absoluteString == "http://anbieter/live/1234.m3u8")
        // And the requested path is still what plays, no raw stream.
        #expect(host.started.last?.url.host == "127.0.0.1")
    }

    /// **Repackager check, finding 7, 2026-09-27:** The delayed rebuild from
    /// ``PlayerModel/noteEngineFailure()`` was until then tied to nobody — if the
    /// view disappeared (`finish()`) during the 400 ms in which the task waits for the mark from the
    /// error log, it reconnected anyway and occupied the only
    /// provider connection for a screen nobody saw any more.
    @Test("finish() during the wait after a drop prevents the rebuild")
    func finishDuringRestartWaitPreventsRebuild() async {
        let remux = RemuxSpy()
        let (model, host) = liveRemuxModel(remux: remux)

        await model.begin()
        await model.engineStartTask?.value
        #expect(remux.asked.count == 1)

        host.engine.status = .playing
        await model.tick()

        host.engine.status = .failed
        await model.tick()

        // The view disappears WHILE the 400 ms wait is still running.
        model.finish()

        try? await Task.sleep(for: .milliseconds(700))

        #expect(remux.asked.count == 1, "no rebuild after finish() during the wait")
    }

    /// A rebuild must first earn the next "has played": the
    /// second dropout without a picture does **not** set up the same path again,
    /// but runs into the known fallback to the raw stream — the path
    /// switches instead of rebuilding in circles.
    @Test("After the one rebuild comes the fallback, no loop")
    func secondFailureFallsBackInsteadOfLooping() async {
        let channels = URL(string: "http://anbieter/live/5678.m3u8")!
        let remux = RemuxSpy()
        let (model, host) = liveRemuxModel(remux: remux, channels: channels)

        await model.begin()
        await model.engineStartTask?.value
        host.engine.status = .playing
        await model.tick()
        host.engine.status = .failed
        await model.tick()
        // The rebuild waits a moment for the mark from the
        // error log (see ``PlayerModel/noteEngineFailure``).
        await Self.wait { remux.asked.count >= 2 }
        await model.engineStartTask?.value
        #expect(remux.asked.count == 2)

        // The rebuild never gets to play and drops out again.
        host.engine.status = .opening
        await model.tick()
        host.engine.status = .failed
        await model.tick()
        // The rebuild waits a moment for the mark from the
        // error log (see ``PlayerModel/noteEngineFailure``).
        await Self.wait { model.target.sourceURL.pathExtension.lowercased() == "ts" }
        await model.engineStartTask?.value

        // No third attempt through the playlist: the target is now
        // the raw stream of the same channel.
        #expect(model.target.sourceURL.pathExtension.lowercased() == "ts")
        #expect(model.target.sourceURL.deletingPathExtension() == channels.deletingPathExtension())
    }

    /// **The second kind of blindness** (on-device finding 2026-08-15: Mercan TV UHD and
    /// Lodos TV UHD, sound only, and the app never switched): a repackaged
    /// stream carries its picture size in the header — `hasVideoOutput` never becomes
    /// false again, even if the decoder never draws a picture. Only the honest
    /// layer report makes this case visible.
    @Test("Announced but never drawn: after eight seconds the raw stream takes over")
    func announcedButNeverDrawnFallsBack() async {
        let channels = URL(string: "http://anbieter/live/8811.m3u8")!
        let remux = RemuxSpy()
        let (model, host) = liveRemuxModel(remux: remux, channels: channels)

        await model.begin()
        await model.engineStartTask?.value

        host.engine.status = .playing
        // The lie of the repackaged stream: size known, never drawn.
        host.engine.hasVideoOutput = true
        host.engine.firstFrameVisible = false

        for _ in 0..<PlayerModel.blindDrawTicks {
            // The clock runs along — otherwise the stall watchdog would judge
            // first, and the check would see the wrong trigger.
            host.engine.position += 0.5
            await model.tick()
        }
        await model.engineStartTask?.value

        #expect(model.target.sourceURL.pathExtension.lowercased() == "ts")
    }

    /// **The short deadline was never checked** (AP12, 2026-09-02). Only the long one
    /// was checked (``PlayerModel/blindDrawTicks``, eight seconds) — and
    /// it is precisely the short one that the work package was about:
    /// "Instead of waiting several seconds for a picture that never comes, switch after
    /// about one and a half seconds."
    ///
    /// If even the **picture size** is missing, the decoder cannot handle the track;
    /// nobody has to wait eight seconds for that. Five ticks of 500 ms are
    /// two and a half seconds — and this check fails as soon as someone ties the
    /// deadline to the long one again.
    @Test("Without a picture size the raw stream takes over after two and a half seconds")
    func missingVideoSizeFallsBackEarly() async {
        let channels = URL(string: "http://anbieter/live/8844.m3u8")!
        let remux = RemuxSpy()
        let (model, host) = liveRemuxModel(remux: remux, channels: channels)

        await model.begin()
        await model.engineStartTask?.value

        host.engine.status = .playing
        // The decoder cannot handle the track: no size, never drawn.
        host.engine.hasVideoOutput = false
        host.engine.firstFrameVisible = false

        // **One tick before the deadline the path still stands.** Without this half
        // the check would also be green with the long deadline — it would just run
        // longer.
        for _ in 0..<(PlayerModel.blindTicks - 1) {
            host.engine.position += 0.5
            await model.tick()
        }
        await model.engineStartTask?.value
        #expect(model.target.sourceURL.pathExtension.lowercased() == "m3u8")

        host.engine.position += 0.5
        await model.tick()
        await model.engineStartTask?.value

        #expect(model.target.sourceURL.pathExtension.lowercased() == "ts")
        #expect(PlayerModel.blindTicks * 500 == 2500, "five ticks of 500 ms")
    }

    /// **F-033 (2026-10-03, Apple TV 4K from 2017):** every new HEVC channel fell
    /// back individually, although over a hundred were already remembered. The rule counted "list"
    /// as soon as anything played — but the blind startup plays sound, and the raw stream
    /// afterwards plays too. One visit thus gave 2 × list and 1 × raw.
    @Test("A blind channel counts only as raw, even if the raw stream plays afterwards")
    func blindChannelCountsRawOnly() async {
        let store = InMemoryStore()
        let remux = RemuxSpy()
        let (model, host) = liveRemuxModel(
            remux: remux, channels: URL(string: "http://anbieter/live/8845.m3u8")!, rawStreamStore: store)

        await model.begin()
        await model.engineStartTask?.value
        host.engine.status = .playing
        host.engine.hasVideoOutput = false
        host.engine.firstFrameVisible = false
        for _ in 0..<PlayerModel.blindTicks {
            host.engine.position += 0.5
            await model.tick()
        }
        await model.engineStartTask?.value
        #expect(model.target.sourceURL.pathExtension.lowercased() == "ts")

        // The raw stream carries the picture.
        host.engine.status = .playing
        host.engine.hasVideoOutput = true
        host.engine.firstFrameVisible = true
        for _ in 0..<4 {
            host.engine.position += 0.5
            await model.tick()
        }

        let tally = RawStreamRule.load(from: store).state(
            RawStreamRule.pair(counterpart: "anbieter", name: "TELVE 1 HEVC"))
        #expect(tally.raw == 1)
        #expect(
            tally.list == 0, "neither the blind startup nor the raw stream counts as a success of the list")
    }

    @Test("A playlist with a drawn picture counts as a success, once")
    func listWithPictureCounts() async {
        let store = InMemoryStore()
        let remux = RemuxSpy()
        let (model, host) = liveRemuxModel(
            remux: remux, channels: URL(string: "http://anbieter/live/8846.m3u8")!, rawStreamStore: store)

        await model.begin()
        await model.engineStartTask?.value
        host.engine.status = .playing
        host.engine.hasVideoOutput = true
        host.engine.firstFrameVisible = true
        for _ in 0..<4 {
            host.engine.position += 0.5
            await model.tick()
        }
        let tally = RawStreamRule.load(from: store).state(
            RawStreamRule.pair(counterpart: "anbieter", name: "TELVE 1 HEVC"))
        #expect(tally.list == 1)
        #expect(tally.raw == 0)
    }

    /// The counter-test: a sluggish startup is not blindness. If the
    /// layer does draw shortly before the deadline, the path stays.
    @Test("A late first picture prevents the fallback")
    func lateFirstFrameCancelsTheFallback() async {
        let remux = RemuxSpy()
        let (model, host) = liveRemuxModel(
            remux: remux, channels: URL(string: "http://anbieter/live/8822.m3u8")!)

        await model.begin()
        await model.engineStartTask?.value

        host.engine.status = .playing
        host.engine.hasVideoOutput = true
        host.engine.firstFrameVisible = false

        for _ in 0..<(PlayerModel.blindDrawTicks - 1) {
            host.engine.position += 0.5
            await model.tick()
        }
        host.engine.firstFrameVisible = true
        host.engine.position += 0.5
        await model.tick()
        host.engine.position += 0.5
        await model.tick()
        await model.engineStartTask?.value

        #expect(model.target.sourceURL.pathExtension.lowercased() == "m3u8")
    }

    /// Without a report no verdict: `nil` — no drawing surface, AirPlay — never
    /// triggers a fallback.
    @Test("No information does not mean blind")
    func missingVerdictIsNotBlindness() async {
        let remux = RemuxSpy()
        let (model, host) = liveRemuxModel(
            remux: remux, channels: URL(string: "http://anbieter/live/8833.m3u8")!)

        await model.begin()
        await model.engineStartTask?.value

        host.engine.status = .playing
        host.engine.hasVideoOutput = nil
        host.engine.firstFrameVisible = nil

        for _ in 0..<(PlayerModel.blindDrawTicks + 2) {
            host.engine.position += 0.5
            await model.tick()
        }
        await model.engineStartTask?.value

        #expect(model.target.sourceURL.pathExtension.lowercased() == "m3u8")
    }

    /// **The zapping race of 2026-08-15, nailed down as a check:** a
    /// repackager that builds slowly was overtaken by the viewer — and in the
    /// old cleanup (`releaseRemux()` in the overtaken branch) the
    /// straggler released the handles of the NEXT session: its server died, the
    /// engine played against a dead port, and the trace said "Raw
    /// stream dead without ever playing" — on every fast channel switch.
    @Test("When zapping, the successor's session survives")
    func lateRemuxDoesNotKillTheSuccessor() async {
        let flags = RaceFlags()
        let host = HostDouble()

        let model = PlayerModel(
            target: PlaybackTarget(
                itemID: nil,
                title: "Sender A",
                url: URL(string: "http://anbieter/live/1111.ts")!,
                decision: PlaybackDecision(
                    engine: .native, delivery: .remuxInApp, reason: .remuxedInApp),
                kind: .live
            ),
            engine: host,
            source: SourceSpy(),
            remux: { @MainActor target in
                if target.url.lastPathComponent.hasPrefix("1111") {
                    // The slow setup of the first channel: hangs until the
                    // check lets it continue.
                    await withCheckedContinuation { continuation in
                        flags.holdFirst = continuation
                    }
                    return PlayerModel.StartedRemux(
                        url: URL(string: "http://127.0.0.1:60001/media.m3u8")!,
                        handle: NSObject(),
                        stop: { flags.firstStopped = true }
                    )
                }
                return PlayerModel.StartedRemux(
                    url: URL(string: "http://127.0.0.1:60002/media.m3u8")!,
                    // The canary: in operation the handle keeps the server
                    // alive. The old bug did not call stop() — it let
                    // the handle FALL, and the server died through
                    // memory management. That is exactly what the deinit reports.
                    handle: DeinitCanary { flags.secondHandleDied = true },
                    stop: { flags.secondStopped = true }
                )
            }
        )

        await model.begin()
        let firstBuild = model.engineStartTask
        // The old engine is shut down before the build — the provider allows
        // one connection, and the repackager now needs it.
        #expect(host.stopCount >= 1)

        // The viewer keeps switching while the first repackager is still building.
        model.play(
            PlaybackTarget(
                itemID: nil,
                title: "Sender B",
                url: URL(string: "http://anbieter/live/2222.ts")!,
                decision: PlaybackDecision(
                    engine: .native, delivery: .remuxInApp, reason: .remuxedInApp),
                kind: .live
            )
        )
        await model.engineStartTask?.value
        #expect(model.target.url.port == 60002, "the successor's remuxer plays")

        // Now the straggler finishes — and may tear down only itself.
        flags.holdFirst?.resume()
        flags.holdFirst = nil
        await firstBuild?.value

        #expect(flags.firstStopped, "the overtaken session tears itself down")
        #expect(!flags.secondStopped, "the playing session stays alive")
        #expect(!flags.secondHandleDied, "its handle is not overwritten by any straggler")
        #expect(host.started.last?.url.port == 60002)
    }

    /// **The second half of the zapping race** (on-device finding 2026-08-15,
    /// fifth evening test): the generation check devalues the overtaken build
    /// only when it is DONE — until then it held a connection of its own
    /// to the provider, and the provider allows one. Two repackagers cut
    /// their piece 0 at the same time and tore the line away from each other:
    /// "starts, hangs after seconds, works on the second open". Since then
    /// the running build is CANCELLED on switching onward; its
    /// `CancellationError` is no problem and triggers no fallback.
    @Test("When zapping, the build in progress is cancelled, not merely overtaken")
    func zappingCancelsTheBuildInFlight() async {
        let host = HostDouble()

        let model = PlayerModel(
            target: PlaybackTarget(
                itemID: nil,
                title: "Sender A",
                url: URL(string: "http://anbieter/live/1111.ts")!,
                decision: PlaybackDecision(
                    engine: .native, delivery: .remuxInApp, reason: .remuxedInApp),
                kind: .live
            ),
            engine: host,
            source: SourceSpy(),
            remux: { @MainActor target in
                if target.url.lastPathComponent.hasPrefix("1111") {
                    // Like the real build: sleeps between steps — and
                    // exactly out of this sleep the cancellation tears it.
                    while true {
                        try await Task.sleep(for: .milliseconds(5))
                    }
                }
                return PlayerModel.StartedRemux(
                    url: URL(string: "http://127.0.0.1:60002/media.m3u8")!,
                    handle: NSObject(),
                    stop: {}
                )
            }
        )

        await model.begin()
        let firstBuild = model.engineStartTask

        // The viewer keeps switching while the first repackager is still building.
        model.play(
            PlaybackTarget(
                itemID: nil,
                title: "Sender B",
                url: URL(string: "http://anbieter/live/2222.ts")!,
                decision: PlaybackDecision(
                    engine: .native, delivery: .remuxInApp, reason: .remuxedInApp),
                kind: .live
            )
        )

        #expect(
            firstBuild?.isCancelled == true,
            "the overtaken build is cancelled and frees the provider connection")

        await firstBuild?.value
        await model.engineStartTask?.value

        // The cancellation is not a failure: no fallback, no second start —
        // exactly the successor's repackager plays.
        #expect(host.started.count == 1)
        #expect(host.started.last?.url.port == 60002)
    }

    /// **The fallback asks only a house that knows the title** (on-device finding
    /// 2026-08-15, evening: "VOD content no longer plays at all"): if the
    /// repackager fails on a provider movie, the fallback fetched from the
    /// MEDIA SERVER an address for an ID it had never seen —
    /// the result was a playlist into nothing. A source that only hands out
    /// files as they lie (`canStartAtOffset == false`) cannot
    /// chunk either — it is not even asked.
    @Test("The server fallback does not ask a source that cannot segment")
    func fallbackSkipsSourcesThatCannotRepackage() async {
        let host = HostDouble()
        let spy = SourceSpy()
        spy.startsAtOffset = false

        enum Broken: Error { case noLength }
        let model = PlayerModel(
            target: PlaybackTarget(
                itemID: "38500AEE#movie#821479#mkv",
                title: "Anbieter-Film",
                url: URL(string: "http://anbieter/movie/821479.mkv")!,
                decision: PlaybackDecision(
                    engine: .native, delivery: .remuxInApp, reason: .remuxedInApp),
                kind: .recording
            ),
            engine: host,
            source: spy,
            remux: { @MainActor _ in throw Broken.noLength }
        )

        await model.begin()
        await model.engineStartTask?.value

        #expect(spy.streamRequests.isEmpty, "the provider has no segmenting — no request")
        #expect(host.started.count == 1, "it plays anyway — via the last resort")
    }

    /// Memo for the zapping race.
    ///
    /// `@unchecked Sendable`, because the stop closures are `@Sendable` and are meant to
    /// write synchronously — in operation the main actor calls them, and
    /// a detour through a task would make the check itself a race.
    final class RaceFlags: @unchecked Sendable {
        var holdFirst: CheckedContinuation<Void, Never>?
        var firstStopped = false
        var secondStopped = false
        var secondHandleDied = false
    }

    /// Reports its own demise — for handles whose loss is the actual bug.
    final class DeinitCanary: @unchecked Sendable {
        private let onDeinit: () -> Void
        init(_ onDeinit: @escaping () -> Void) { self.onDeinit = onDeinit }
        deinit { onDeinit() }
    }

    /// The raw stream fails without ever playing — the app starts nothing
    /// new: for this visit the channel has honestly failed, and the
    /// memo is healed so that the next visit tries the
    /// playlist again (on-device finding 2026-08-15, Telve 1 HEVC).
    @Test("A dead raw stream triggers no further start")
    func deadRawStreamStartsNothingNew() async {
        let host = HostDouble()
        let model = PlayerModel(
            target: PlaybackTarget(
                itemID: nil,
                title: "TELVE 1 HEVC",
                url: URL(string: "http://anbieter/live/1234.ts")!,
                decision: PlaybackDecision(
                    engine: .native, delivery: .directPlay,
                    reason: .containerNotNativelySupported),
                kind: .live
            ),
            engine: host,
            source: SourceSpy(),
            remux: RemuxSpy().builder
        )

        await model.begin()
        await model.engineStartTask?.value
        let startsAfterBegin = host.started.count

        host.engine.status = .failed
        await model.tick()

        #expect(host.started.count == startsAfterBegin)
    }
}
