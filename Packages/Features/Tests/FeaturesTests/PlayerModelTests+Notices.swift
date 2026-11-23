import Core
import CoreGraphics
import DesignSystem
import Foundation
import Testing

@testable import Features

/// Progress, session and skipping — what the player reports to the server.
extension PlayerModelTests {

    // MARK: - Progress

    @Test("The first tick reports the playback to the server")
    func firstTickBeginsSession() async {
        // Without the sign-in the server does not count the session, and in the
        // web console it cannot be seen that the TV is currently playing something.
        let (model, host, source) = make()
        host.engine.status = .playing

        await model.tick()

        #expect(source.begun == ["film"])
        // Right afterwards the position: ``beginSession`` passes no position through,
        // so on resuming the server would otherwise show the start.
        #expect(source.reports.count == 1)
    }

    @Test("Progress goes out at the counter's cadence and not on every tick")
    func progressKeepsCadence() async {
        // The engine reports twice per second. If every report were passed on, there would be
        // a five-digit number of requests for two hours of movie — the server is
        // then busy counting instead of delivering.
        let (model, host, source) = make()
        host.engine.status = .playing

        await model.tick()
        let afterStart = source.reports.count

        host.engine.position = 4
        await model.tick()
        #expect(source.reports.count == afterStart, "four seconds are not yet worth a report")

        host.engine.position = 12
        await model.tick()
        #expect(source.reports.count == afterStart + 1)
    }

    @Test("A pause is reported immediately, without waiting for the cadence")
    func pauseIsReportedAtOnce() async {
        // Otherwise the server keeps showing "playing". Whoever checks on the phone why
        // the picture on the TV is frozen finds no explanation there.
        let (model, host, source) = make()
        host.engine.status = .playing
        await model.tick()

        host.engine.position = 2
        host.engine.status = .paused
        await model.tick()

        #expect(source.reports.last?.isPaused == true)
        #expect(source.reports.last?.progress.position == 2)
    }

    @Test("The end reports the session out exactly once")
    func endReportsOnce() async {
        // A second sign-out ends on the server a session that by now belongs to a
        // different title — then the display vanishes in the middle of the next movie.
        let (model, host, source) = make()
        host.engine.status = .playing
        await model.tick()

        host.engine.position = 3500
        host.engine.status = .ended
        await model.tick()
        await model.tick()
        model.finish()

        #expect(source.ended.count == 1)
        // The handed-over position counts, not that of the engine after stopping: some
        // report null there, and the title would then be back at the start under
        // "Continue Watching".
        #expect(source.ended.first?.position == 3500)
    }

    @Test("On leaving the view the session is reported out at the last position")
    func leavingEndsSession() async {
        // Without this sign-out the session stays on the server for hours as "playing"
        // and hides what the other devices are currently playing.
        let (model, host, source) = make()
        host.engine.status = .playing
        host.engine.position = 900
        await model.tick()

        model.finish()
        // The sign-out runs in a task of its own, because the view is
        // disappearing — awaited through its handle, not through a pass.
        await model.deregistration?.value

        #expect(source.ended.first?.position == 900)
        #expect(host.stopCount == 1)
    }

    @Test("No progress is reported for a trailer")
    func trailerReportsNothing() async {
        // A trailer that ends up on Home as "40% watched" is a
        // bug you only notice once it is there. The ID is set on purpose:
        // the kind decides, not its absence.
        let (model, host, source) = make(kind: .trailer, itemID: "trailer")
        host.engine.status = .playing

        await model.tick()
        host.engine.position = 60
        await model.tick()
        host.engine.status = .ended
        await model.tick()
        model.finish()
        await model.deregistration?.value

        #expect(source.begun.isEmpty)
        #expect(source.reports.isEmpty)
        #expect(source.ended.isEmpty)
    }

    @Test("A channel reports no progress and cannot be scrubbed")
    func liveHasNoSeeking() async {
        // With a running channel there is nothing to seek and nothing to remember. A
        // jump would tear the stream down, and a remembered position would be
        // a different show tomorrow.
        let (model, host, source) = make(kind: .live, itemID: nil, duration: nil)
        host.engine.status = .playing
        await model.tick()

        model.skip(by: 30)
        model.moveScrub(by: 1)
        model.seek(to: 500)

        #expect(!model.isSeekable)
        #expect(host.engine.seeks.isEmpty)
        #expect(model.scrubPosition == nil)
        #expect(source.reports.isEmpty)
    }

    // MARK: - Skipping

    @Test("Skipping appears only within the reported window")
    func skipOnlyInsideWindow() async {
        // A permanent button on the picture gets clicked on the TV because it is simply there
        // — and for a movie without an intro it just stands around pointlessly.
        let (model, host, source) = make()
        source.segmentsToReturn = [
            MediaSegment(id: "intro", kind: .intro, start: 0, end: 104)
        ]
        await model.loadContext()

        host.engine.status = .playing
        host.engine.position = 40
        await model.tick()
        #expect(model.skipOffer?.kind == .intro)

        host.engine.position = 120
        await model.tick()
        #expect(model.skipOffer == nil, "no button may remain after the window")
    }

    @Test("A skipped segment is not offered again")
    func skippedSegmentStaysGone() async {
        // The jump lands on the end of the segment, and the end no longer counts
        // as part of it. Without memory the button would come back with the next position
        // report anyway if the engine reports a second earlier.
        let (model, host, source) = make()
        source.segmentsToReturn = [
            MediaSegment(id: "intro", kind: .intro, start: 0, end: 104)
        ]
        await model.loadContext()

        host.engine.status = .playing
        host.engine.position = 40
        await model.tick()
        model.skipCurrentSegment()

        #expect(host.engine.seeks.last == 104)

        host.engine.position = 40
        await model.tick()
        #expect(model.skipOffer == nil)
    }

    @Test("Ads are not offered for skipping")
    func commercialIsNotOffered() async {
        // In a library of one's own there is no advertising. If the server finds
        // any there, that is a false find — and a button in the middle of the movie would be the result.
        let (model, host, source) = make()
        source.segmentsToReturn = [
            MediaSegment(id: "ad", kind: .commercial, start: 0, end: 60)
        ]
        await model.loadContext()

        host.engine.status = .playing
        host.engine.position = 30
        await model.tick()

        #expect(model.skipOffer == nil)
    }

    // MARK: - The false fallback (AP3 · V3b)

    private static func target(
        kind: PlaybackTarget.Kind, delivery: Delivery,
        reason: PlaybackDecision.Reason
    ) -> PlaybackTarget {
        PlaybackTarget(
            itemID: "x", title: "Film", url: URL(string: "http://x/y.mkv")!,
            decision: PlaybackDecision(engine: .native, delivery: delivery, reason: reason),
            kind: kind)
    }

    /// **The information that was wrong twice.** If the repackager fails on
    /// a Matroska, the app tries the system engine on the raw file —
    /// an attempt that fails by construction. Above it stood "The server
    /// does not deliver, or the file cannot be read from this point":
    /// both wrong, and both send the viewer looking for a
    /// bug that does not exist.
    @Test("The impossible fallback says what is really going on")
    @MainActor
    func apparentFallbackSaysSo() {
        let target = Self.target(
            kind: .recording, delivery: .directPlay, reason: .containerNotNativelySupported)

        #expect(PlayerScreen.stalledTitleKey(for: target, finding: nil) == "player.stalledContainer")
        #expect(PlayerScreen.stalledHintKey(for: target, finding: nil) == "player.stalledContainerHint")
    }

    /// And the counter-test: an ordinary hang stays an ordinary
    /// hang. Whoever declares every stall a format error trades one
    /// wrong message for another.
    @Test("An ordinary hang stays a hang")
    @MainActor
    func ordinaryStall() {
        let target = Self.target(kind: .recording, delivery: .hls, reason: .containerNotNativelySupported)
        #expect(PlayerScreen.stalledTitleKey(for: target, finding: nil) == "player.stalled")

        let channels = Self.target(
            kind: .live, delivery: .directPlay, reason: .containerNotNativelySupported)
        #expect(PlayerScreen.stalledTitleKey(for: channels, finding: nil) == "player.stalledLive")
    }

    /// **A tight line gets a sentence of its own** (AP69, 2026-10-11): for a file
    /// that the engine has measured as "line ≈ bitrate", the stall does not mean "Nothing is
    /// arriving" but "The connection to the provider is tight" — with the numbers.
    @Test("A tight connection on a file says so with numbers")
    @MainActor
    func lineTight() {
        let file = Self.target(kind: .recording, delivery: .directPlay, reason: .nativeContainer)
        let tight = LineFinding(line: 500_000, demand: 500_000)
        #expect(
            PlayerScreen.stalledTitleKey(for: file, finding: nil, line: tight)
                == "player.stillstandLeitungKnapp")
        #expect(PlayerScreen.stalledHintKey(for: file, finding: nil, line: tight) == nil)
        #expect(PlayerScreen.lineTight(file, tight))

        // Enough headroom: the ordinary sentence.
        let good = LineFinding(line: 1_250_000, demand: 500_000)
        #expect(PlayerScreen.stalledTitleKey(for: file, finding: nil, line: good) == "player.stalled")
        // A finding of the repackager takes precedence.
        #expect(
            PlayerScreen.stalledTitleKey(for: file, finding: .sourceSilent, line: tight)
                == "player.stillstandQuelle")
        // Live and HLS: not this sentence.
        let channels = Self.target(kind: .live, delivery: .directPlay, reason: .nativeContainer)
        #expect(
            PlayerScreen.stalledTitleKey(for: channels, finding: nil, line: tight) == "player.stalledLive")
        let hls = Self.target(kind: .recording, delivery: .hls, reason: .nativeContainer)
        #expect(!PlayerScreen.lineTight(hls, tight))
    }

    // MARK: - The second attempt (AP5 · B5)

    /// **The error screen recommends a second try and offered none.** "A
    /// second try is usually worth it" stood above a single button, and
    /// that was "Back" — the second try cost four presses.
    @Test("The second attempt rebuilds the same route")
    @MainActor
    func secondAttempt() async {
        let (model, host, _) = make()
        await model.begin()
        let previous = host.started.count

        model.retry()

        #expect(host.started.count == previous + 1)
        // **Via the source address and not via `url`:** when the repackager is up,
        // `url` points to 127.0.0.1 — a retry against that would run into
        // a server that has just failed.
        #expect(host.started.last?.url == model.target.sourceURL)
    }
}
