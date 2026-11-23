import Core
import Foundation
import Testing

@testable import Flows

/// **The playback core, without an engine** (AP58 R4, report A S1). What is stated here
/// applies equally on the TV (`PlayerModel`) and the phone (`PlayerModel`); their checks
/// show that it is wired in.
@MainActor
@Suite("Playback core")
struct PlaybackCoreTests {

    static func recording(step: TimeInterval = 1, inStartup: Bool = false) -> PlaybackCore {
        let core = PlaybackCore(step: step, watchesDuringStartup: inStartup)
        core.newTarget(reportsProgress: true, isRecording: true, sameTitle: false)
        return core
    }

    // MARK: - Reports

    @Test("Sign-in happens with the first frame, sign-out at the end — once")
    func registerAndDeregister() {
        let core = Self.recording()
        #expect(core.episode(status: .opening, location: 0, duration: 1_000).report == nil)
        #expect(core.episode(status: .playing, location: 0, duration: 1_000).report?.kind == .start)
        #expect(core.episode(status: .ended, location: 990, duration: 1_000).report?.kind == .stop)
        #expect(core.finish(at: 990) == nil, "whoever has signed out stays silent")
    }

    @Test("A failure signs out too")
    func failureReportsOut() {
        let core = Self.recording()
        _ = core.episode(status: .playing, location: 0, duration: 1_000)
        #expect(core.episode(status: .failed, location: 12, duration: 1_000).report?.kind == .stop)
    }

    /// **The distance as an absolute value** — until R4 the phone measured without `abs`, and
    /// a jump backwards went out only ten seconds later.
    @Test("A jump back leaves immediately, a pause too")
    func rewindAndPause() {
        let core = Self.recording()
        _ = core.episode(status: .playing, location: 600, duration: 1_000)
        #expect(core.episode(status: .playing, location: 605, duration: 1_000).report == nil)
        #expect(core.episode(status: .playing, location: 300, duration: 1_000).report?.kind == .progress)
        #expect(core.episode(status: .paused, location: 300, duration: 1_000).report?.kind == .pause)
        #expect(core.episode(status: .playing, location: 300, duration: 1_000).report?.kind == .resume)
    }

    @Test("A channel reports nothing")
    func channelReportsNothing() {
        let core = PlaybackCore(step: 1, watchesDuringStartup: false)
        core.newTarget(reportsProgress: false, isRecording: false, sameTitle: false)
        #expect(core.episode(status: .playing, location: 0, duration: 0).report == nil)
        #expect(core.finish(at: 30) == nil)
    }

    /// Remembers what went out.
    actor Transcript {
        var rows: [String] = []
        func note(_ row: String) { rows.append(row) }
    }

    @Test("The report is mapped to sign-in, progress and sign-out")
    func mapping() async {
        let transcript = Transcript()
        let route = PlaybackCore.ProgressRoute(
            begin: { await transcript.note("begin") },
            notify: { state, isPaused in
                await transcript.note("report \(Int(state.position)) \(isPaused) \(state.isWatched)")
            },
            finish: { location in await transcript.note("end \(Int(location))") })
        await PlaybackCore.send(.init(kind: .start, position: 10), duration: 100, about: route)
        await PlaybackCore.send(.init(kind: .pause, position: 95), duration: 100, about: route)
        await PlaybackCore.send(.init(kind: .stop, position: 96), duration: 100, about: route)
        #expect(
            await transcript.rows == [
                "begin", "report 10 false false", "report 95 true true", "end 96",
            ])
    }

    // MARK: - Next episode

    static let credits = MediaSegment(id: "credits", kind: .outro, start: 1_300, end: 1_400)

    @Test("The counter starts at the credits and switches at zero")
    func reporterAndSwitch() {
        let core = Self.recording()
        core.setSegments([Self.credits])
        core.setNext(available: true, location: 0, duration: 1_400)
        #expect(core.episode(status: .playing, location: 1_299, duration: 1_400).step == .none)
        #expect(core.nextOffer == nil)
        _ = core.episode(status: .playing, location: 1_300, duration: 1_400)
        #expect(core.nextOffer?.secondsLeft == 10)
        var step = PlaybackCore.NextStep.none
        for second in 1...10 {
            step = core.episode(status: .playing, location: 1_300 + Double(second), duration: 1_400).step
        }
        #expect(step == .next)
    }

    @Test("At the end it continues — except rejected, similar or without a successor")
    func atEnd() {
        let next = Self.recording()
        next.setNext(available: true, location: 0, duration: 1_400)
        #expect(next.episode(status: .ended, location: 1_390, duration: 1_400).step == .next)

        let dismissed = Self.recording()
        dismissed.setNext(available: true, location: 0, duration: 1_400)
        dismissed.dismissNext()
        #expect(dismissed.episode(status: .ended, location: 1_390, duration: 1_400).step == .close)

        let similar = Self.recording()
        similar.setNext(available: true, similar: true, location: 0, duration: 7_200)
        for location in stride(from: 7_160.0, through: 7_190, by: 1) {
            #expect(similar.episode(status: .playing, location: location, duration: 7_200).step == .none)
        }
        #expect(similar.episode(status: .ended, location: 7_190, duration: 7_200).step == .close)

        let without = Self.recording()
        #expect(without.episode(status: .ended, location: 1_390, duration: 1_400).step == .close)
    }

    @Test("A new title starts without an offer; the same one keeps what was swiped away")
    func newTarget() {
        let core = Self.recording()
        core.setSegments([MediaSegment(id: "intro", kind: .intro, start: 30, end: 90)])
        #expect(core.skip(at: 40) == 90)
        core.newTarget(reportsProgress: true, isRecording: true, sameTitle: true)
        #expect(core.skipOffer(at: 40) == nil, "not again after a jump")
        core.newTarget(reportsProgress: true, isRecording: true, sameTitle: false)
        #expect(core.segments.isEmpty)
        #expect(core.swipedAway.isEmpty)
    }

    // MARK: - Skipping by itself (AP85 binge package)

    @Test("Skips intro and recap by itself — only at their beginning, only once, only when on")
    func autoSkip() {
        let core = Self.recording()
        core.setSegments([
            MediaSegment(id: "recap", kind: .recap, start: 0, end: 45),
            MediaSegment(id: "intro", kind: .intro, start: 60, end: 150),
            MediaSegment(id: "credits", kind: .outro, start: 1_300, end: 1_400),
        ])
        #expect(core.autoSkip(at: 1) == nil, "off unless the profile switches it on")

        core.autoSkipKinds = BingePreferences(skipsIntro: true).autoSkipKinds
        let start = Date(timeIntervalSince1970: 1_000)
        #expect(core.autoSkip(at: 1, now: start) == 45)
        #expect(core.autoSkipHint(now: start.addingTimeInterval(2))?.id == "recap")
        #expect(core.autoSkipHint(now: start.addingTimeInterval(7)) == nil, "the hint goes by itself")

        #expect(core.autoSkip(at: 100) == nil, "in the middle of the intro: wound back on purpose")
        #expect(core.autoSkip(at: 61) == 150)
        #expect(core.autoSkip(at: 1_301) == nil, "never the credits — the offer has its counter")
    }

    @Test("Back: the start of the section, and it is not skipped again")
    func undoAutoSkip() {
        let core = Self.recording()
        core.setSegments([MediaSegment(id: "intro", kind: .intro, start: 60, end: 150)])
        core.autoSkipKinds = [.intro]
        #expect(core.autoSkip(at: 60) == 150)
        #expect(core.undoAutoSkip() == 60)
        #expect(core.autoSkipHint() == nil)
        #expect(core.autoSkip(at: 60) == nil)
        #expect(core.skipOffer(at: 70) == nil, "no button either — it was decided")
    }

    // MARK: - Sleep timer (AP85)

    @Test("After this episode: stops where the next one would start, then is off")
    func sleepAfterEpisode() {
        let core = Self.recording()
        core.setSegments([Self.credits])
        core.setNext(available: true, location: 0, duration: 1_400)
        core.setSleep(.endOfEpisode)
        var steps: [PlaybackCore.NextStep] = []
        for second in 0...12 {
            steps.append(
                core.episode(status: .playing, location: 1_300 + Double(second), duration: 1_400).step)
        }
        #expect(!steps.contains(.next))
        #expect(steps.filter { $0 == .sleep }.count == 1)
        #expect(core.sleepChoice == .off)
    }

    @Test("Minutes survive the title change and stop when they run out")
    func sleepMinutes() {
        let core = Self.recording()
        let start = Date(timeIntervalSince1970: 0)
        core.setSleep(.minutes(30), now: start)
        #expect(core.sleepMinutesLeft(now: start.addingTimeInterval(61)) == 29)
        core.newTarget(reportsProgress: true, isRecording: true, sameTitle: false)
        #expect(
            core.episode(
                status: .playing, location: 10, duration: 1_400, now: start.addingTimeInterval(1_799)
            ).step == .none)
        #expect(
            core.episode(
                status: .playing, location: 11, duration: 1_400, now: start.addingTimeInterval(1_800)
            ).step == .sleep)
        #expect(core.sleepMinutesLeft() == nil)
    }

    @Test("Off: the counter switches as always")
    func sleepOff() {
        let core = Self.recording()
        core.setSegments([Self.credits])
        core.setNext(available: true, location: 0, duration: 1_400)
        var step = PlaybackCore.NextStep.none
        for second in 0...12 {
            step = core.episode(status: .playing, location: 1_300 + Double(second), duration: 1_400).step
            if step == .next { break }
        }
        #expect(step == .next)
    }

    // MARK: - Still watching? (AP85)

    @Test("Asks after three switches by the counter, a press resets, the title change does not")
    func stillWatching() {
        let core = Self.recording()
        core.stillWatchingAfter = 3
        core.noteAutoAdvance()
        core.newTarget(reportsProgress: true, isRecording: true, sameTitle: false)
        core.noteAutoAdvance()
        core.noteViewerPresent()
        #expect(core.unattendedEpisodes == 0, "a press resets")
        core.noteAutoAdvance()
        core.noteAutoAdvance()
        #expect(!core.asksStillWatching)
        core.noteAutoAdvance()
        #expect(core.asksStillWatching)
        core.confirmStillWatching()
        #expect(!core.asksStillWatching && core.unattendedEpisodes == 0)
    }

    @Test("Off never asks; while asking, the counter does not switch")
    func stillWatchingOffAndHolding() {
        let off = Self.recording()
        for _ in 0..<10 { off.noteAutoAdvance() }
        #expect(!off.asksStillWatching)

        let core = Self.recording()
        core.stillWatchingAfter = 1
        core.noteAutoAdvance()
        core.setSegments([Self.credits])
        core.setNext(available: true, location: 0, duration: 1_400)
        var steps: [PlaybackCore.NextStep] = []
        for second in 0...12 {
            steps.append(
                core.episode(status: .playing, location: 1_300 + Double(second), duration: 1_400).step)
        }
        steps.append(core.episode(status: .ended, location: 1_399, duration: 1_400).step)
        #expect(!steps.contains(.next))
    }

    @Test("A new title forgets the hint")
    func autoSkipNewTitle() {
        let core = Self.recording()
        core.setSegments([MediaSegment(id: "intro", kind: .intro, start: 0, end: 90)])
        core.autoSkipKinds = [.intro]
        #expect(core.autoSkip(at: 0) == 90)
        core.newTarget(reportsProgress: true, isRecording: true, sameTitle: false)
        #expect(core.autoSkipHint() == nil)
    }

    // MARK: - Skipping

    @Test("Skipping only within the window and only for a recording")
    func skip() {
        let core = Self.recording()
        core.setSegments([MediaSegment(id: "intro", kind: .intro, start: 30, end: 90)])
        #expect(core.skipOffer(at: 10) == nil)
        #expect(core.skipOffer(at: 40)?.id == "intro")
        #expect(core.skipOffer(at: 95) == nil)

        let channels = PlaybackCore(step: 1, watchesDuringStartup: false)
        channels.newTarget(reportsProgress: false, isRecording: false, sameTitle: false)
        channels.setSegments([MediaSegment(id: "intro", kind: .intro, start: 30, end: 90)])
        #expect(channels.skipOffer(at: 40) == nil)
    }

    @Test("Every section kind has its sentence in the shared catalog")
    func labels() {
        #expect(PlaybackWording.skip(.outro) == "player.skip" + "Outro")
        #expect(PlaybackWording.skip(.recap) == "player.skip" + "Recap")
        #expect(PlaybackWording.skip(.preview) == "player.skip" + "Intro")
        #expect(!PlaybackWording.nextIn(7).contains("player."), "the sentence is in the catalog")
    }

    // MARK: - Stillstand

    /// **H2 in one place:** The limit is the window of the interpretation, in ticks.
    @Test("The deadline is twelve seconds, however long the tick is")
    func limit() {
        #expect(PlaybackCore(step: 0.5, watchesDuringStartup: true).silenceLimit == 24)
        #expect(PlaybackCore(step: 1, watchesDuringStartup: false).silenceLimit == 12)
    }

    private func settled(
        _ core: PlaybackCore, status: PlaybackStatus, ticks: Int, location: TimeInterval = 5
    ) -> Bool {
        var flipped = false
        for _ in 0..<ticks {
            if core.observeStall(status: status, location: location, loadedUntil: nil, pulse: nil) {
                flipped = true
            }
        }
        return flipped
    }

    @Test("Before the first frame only whoever counts the startup watches")
    func startup() {
        let tv = PlaybackCore(step: 1, watchesDuringStartup: true)
        #expect(settled(tv, status: .opening, ticks: 13))
        let phone = PlaybackCore(step: 1, watchesDuringStartup: false)
        #expect(!settled(phone, status: .opening, ticks: 30))
    }

    @Test("After the first frame the board flips after twelve seconds, a pause never")
    func afterFirstFrame() {
        let core = PlaybackCore(step: 1, watchesDuringStartup: false)
        core.observeStall(status: .playing, location: 4, loadedUntil: nil, pulse: nil)
        #expect(!settled(core, status: .buffering, ticks: 11, location: 4))
        #expect(settled(core, status: .buffering, ticks: 1, location: 4))
        #expect(core.settled)
        #expect(core.stallFinding == nil, "no pulse, no finding")

        let pause = PlaybackCore(step: 1, watchesDuringStartup: false)
        pause.observeStall(status: .playing, location: 4, loadedUntil: nil, pulse: nil)
        #expect(!settled(pause, status: .paused, ticks: 30))
    }

    @Test("A new startup removes the board and counts from the start")
    func newStartup() {
        let core = PlaybackCore(step: 1, watchesDuringStartup: true)
        #expect(settled(core, status: .buffering, ticks: 13), "the first tick sets the position")
        core.newStartup(target: "b")
        #expect(!core.settled)
        #expect(core.silentTicks == 0)
        #expect(!settled(core, status: .buffering, ticks: 11))
    }

    // MARK: - Dried-up supply (F-047)

    /// Leaves the picture at `location` until the board tips — **one tick more than the
    /// limit**: The first tick at the new position only remembers it; counting starts after.
    static func flip(_ core: PlaybackCore, at location: TimeInterval) {
        core.observeStall(status: .playing, location: location - 1, loadedUntil: nil, pulse: nil)
        for _ in 0...core.silenceLimit {
            core.observeStall(status: .playing, location: location, loadedUntil: nil, pulse: nil)
        }
    }

    /// The on-device finding: `Player at 1287.5 s, loaded until 1287.6 s` — and nothing after
    /// that.
    @Test("Dried-up supply restarts, at most three times per title")
    func drySupply() {
        let core = PlaybackCore(step: 1, watchesDuringStartup: false)
        for attempt in 1...PlaybackCore.resupplyLimit {
            Self.flip(core, at: 1287.5)
            #expect(core.settled)
            #expect(
                core.restartAfterSupplyRanDry(
                    title: "folge-1", location: 1287.5, loadedUntil: 1287.6, live: false))
            #expect(core.resupplyAttempts == attempt)
            core.newStartup(target: "adresse-\(attempt)")
        }
        Self.flip(core, at: 1287.5)
        #expect(
            !core.restartAfterSupplyRanDry(
                title: "folge-1", location: 1287.5, loadedUntil: 1287.6, live: false),
            "the fourth attempt would be a storm against an account with one connection")
        #expect(
            core.restartAfterSupplyRanDry(
                title: "folge-2", location: 1287.5, loadedUntil: 1287.6, live: false),
            "another title counts from the start")
    }

    @Test("With lead, with Live or without a stall nothing restarts")
    func noRestart() {
        let core = PlaybackCore(step: 1, watchesDuringStartup: false)
        #expect(
            !core.restartAfterSupplyRanDry(
                title: "t", location: 100, loadedUntil: 100, live: false),
            "never without a flipped board")
        Self.flip(core, at: 463.9)
        #expect(
            !core.restartAfterSupplyRanDry(
                title: "t", location: 463.9, loadedUntil: 507.1, live: false),
            "43 s loaded before: the engine is stuck, not the line")
        #expect(
            !core.restartAfterSupplyRanDry(
                title: "t", location: 463.9, loadedUntil: 464, live: true),
            "Live has its own remuxer")
    }

    @Test("Two minutes of running after the restart give the attempts back")
    func recovery() {
        let core = PlaybackCore(step: 1, watchesDuringStartup: false)
        Self.flip(core, at: 600)
        _ = core.restartAfterSupplyRanDry(
            title: "t", location: 600, loadedUntil: 600, live: false)
        #expect(core.resupplyAttempts == 1)
        core.newStartup(target: "neu")
        core.observeStall(
            status: .playing, location: 600 + PlaybackCore.resupplyRecovery, loadedUntil: nil,
            pulse: nil)
        #expect(core.resupplyAttempts == 0)
    }
}
