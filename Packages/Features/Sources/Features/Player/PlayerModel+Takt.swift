import Core
import DesignSystem
import Flows
import Foundation
import JellyfinKit
import Observation
import Playback
import PortalKit
import SwiftUI

extension PlayerModel {

    // MARK: - Tick

    /// Interval between two polls of the engine in seconds.
    ///
    /// Not the pacing of the progress reports — that lives in
    /// ``PlaybackReporter`` and is ten seconds. This is about how quickly a pause
    /// reaches the server and how smoothly the bar runs. Half a second matches what VLC reports on its own.
    nonisolated static let tickInterval: Duration = .milliseconds(500)

    /// How finely measurement happens during startup.
    ///
    /// Fifty milliseconds: the times being sought range from a few
    /// hundred milliseconds to several seconds, and a resolution of
    /// half a second (the ordinary tick) would turn them into a number
    /// that mostly measures the tick.
    static let startupProbeInterval: Duration = .milliseconds(50)

    /// How long to wait for a picture before the measurement gives up.
    ///
    /// A channel that shows no picture after thirty seconds will deliver none
    /// any more — and the incomplete measurement is then itself the result.
    static let startupProbeTimeout: TimeInterval = 30

    /// Watches startup closely until the first picture is up.
    ///
    /// **A tick of its own and not the ordinary one**, because the two do different
    /// things: the ordinary one keeps the UI current and may be leisurely;
    /// this one measures and ends as soon as there is nothing left to measure. After
    /// the first picture it costs nothing, because it no longer exists.
    func startStartupProbe() {
        startupProbe?.cancel()
        startupProbe = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: PlayerModel.startupProbeInterval)
                guard !Task.isCancelled, let self else { return }
                if self.sampleStartup() { return }
            }
        }
    }

    /// Which reported readiness belongs to **this** startup.
    ///
    /// **The host outlives the target.** ``PlayerModel`` holds a single
    /// `PlaybackHosting` for the whole session, and it only swaps its engine
    /// when it takes over the new target. On the remuxer path several seconds lie between the
    /// `stop()` in ``startEngine(_:)`` and the new start — in
    /// that gap the previous channel's engine still answers. A timestamp
    /// from before the own start is therefore not a measurement but the echo of the
    /// last target; taken as a mark it would yield a negative startup time,
    /// and a negative duration devalues the whole table.
    ///
    /// A function of its own and not a built-in condition, so the rule can be tested
    /// without an engine and without a clock — the same design as
    /// `NativePlaybackEngine.firstFrameVerdict(...)` in the playback package.
    static func readyMark(reported: Date?, startedAt: Date) -> Date? {
        guard let reported, reported >= startedAt else { return nil }
        return reported
    }

    /// One sample of startup. Returns `true` when there is nothing more to do.
    @discardableResult
    func sampleStartup(now: Date = Date()) -> Bool {
        guard var timing = startupTiming else { return true }

        let controller = engine.controller
        // **Readiness comes from the event, not from this sample.**
        // The state only changes to "playing" when the player really plays —
        // by then the picture is already up, and both marks carried the same `now`. The
        // argument is therefore `readyAt` and not `now`; otherwise only the source would
        // be swapped and the resolution would remain that of the sampling tick. The second mark
        // below still comes from the tick — the distortion that remains is
        // exactly one sampling period and no longer the whole measurement.
        let reportedReady = controller.readyToPlayAt
        if let readyAt = Self.readyMark(reported: reportedReady, startedAt: timing.startedAt) {
            timing.markReady(at: readyAt)
        }
        // **Visible, not merely announced.** `hasVideoOutput` is already set on the
        // system player when it has only read the metadata — the mark
        // thereby measured "description read" and called it "first picture"
        // (roadmap AP5: first the mark, then the speed). `firstFrameVisible`
        // attests the first **drawn** picture via the video layer.
        if controller.firstFrameVisible == true {
            timing.markFirstFrame(at: now)
        }
        startupTiming = timing

        if timing.isComplete {
            Diagnostics.probe(timing.line)
            // **The single line does not say whether startup fluctuates** — see
            // ``StartupTally``. The report gets the spread at the end.
            StartupTally.shared.take(timing)
            return true
        }
        // **No picture must not be recognisable by a MISSING line**
        // (check agent 2026-08-23): for "TR: NOKTA TV HQ" the startup line was missing as the
        // only channel of the whole session — and its absence was the only
        // hint that a picture was never drawn. An absence
        // is a poor measurement: it looks exactly like "the viewer
        // switched away beforehand".
        //
        // The interim status says so explicitly after five seconds, together with
        // what the engine has at that moment. Before the give-up deadline, because
        // that is thirty seconds — nobody stays seated that long.
        let waited = now.timeIntervalSince(timing.startedAt)
        if waited > 5, !reportedSlowStart {
            reportedSlowStart = true

            // **Correction of the same line, one build later.**
            //
            // The first version only asked the engine — and then reported
            // twice "engine idle, picture size no, ever drawn no". That was
            // true and still worthless: with ``PlaybackDelivery/remuxInApp``
            // the engine is **deliberately** started only once the remuxer
            // has a buffer (see ``startEngine(_:)``). As long as its task
            // runs, the line cannot say anything else — a state that
            // is fixed by design measures nothing.
            //
            // A check agent found it, and the control test was unambiguous:
            // both occurrences coincide to the second with the two
            // startups over five seconds, and next to them stood "piece 0
            // cut" — the remuxer had long been working.
            //
            // Now the two cases are separated. They demand
            // different things: one is a slow provider, the other an
            // engine that does not touch a finished target.
            // **Double safeguard.** The handle is now released again
            // (see ``startEngine(_:)``), but the sentence was in addition
            // factually wrong for `directPlay`: there is no remuxer at all there.
            // As long as the task runs, ``target`` still carries the original
            // decision — it is only updated at the end of the build.
            if engineStartTask != nil, target.decision.runsOverRepacker {
                Diagnostics.playbackProblem(
                    "Startup: after \(Int(waited)) s — the remuxer is still building, the engine "
                        + "is deliberately not started yet (delivery path "
                        + "\(target.decision.delivery))",
                    since: timing.startedAt
                )
            } else {
                Diagnostics.playbackProblem(
                    "Startup: after \(Int(waited)) s still no picture — engine \(controller.status), "
                        + "picture size present: \(controller.hasVideoOutput == true ? "yes" : "no"), "
                        + "ever drawn: \(controller.firstFrameVisible == true ? "yes" : "no"), "
                        + "delivery path \(target.decision.delivery)",
                    since: timing.startedAt
                )
            }
        }

        // Giving up is also a result, and an important one: the channel
        // delivered no picture.
        if waited > PlayerModel.startupProbeTimeout {
            // **The most important single finding of the startup measurement, and it was filed
            // as a check mark.** Thirty seconds without a single picture are a defect;
            // filed as a measurement it stays one — the line thereby keeps the
            // category of its successful sibling above, but is visible without `--info`
            // and does not wait for the diagnostics switch.
            Diagnostics.probe(timing.line + "  (given up without a picture)", verdict: .problem)
            StartupTally.shared.recordAbort(route: timing.opening)
            return true
        }
        return false
    }

    func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: PlayerModel.tickInterval)
                guard !Task.isCancelled, let self else { return }
                await self.tick()
            }
        }
    }

    /// Takes in the engine's state and draws all consequences from it.
    ///
    /// Explicitly public and without a timer inside, so the tests can
    /// advance it step by step. A model whose tick only
    /// comes from a real clock can only be tested with waiting — and tests
    /// with waiting get switched off as soon as they fail once by chance.
    public func tick() async {
        let controller = engine.controller

        // **The notification also goes out when the value is unchanged** (AP7 · L7,
        // expert pass 2026-08-24): the tick wrote `status`,
        // `position`, `duration` every 500 ms and via ``refreshTrackLists(from:)`` four
        // more — and every assignment re-evaluates the whole tree of the
        // playback view. The subtitle lines next to them were guarded from
        // the start; the others lacked it.
        let previous = status
        if status != controller.status { status = controller.status }
        // **The chosen speed survives pausing** — see ``applySpeed()``.
        // In the tick and not in ``togglePause()``: the system player also goes back to
        // `rate = 1` without a press, for example after a buffering stall at the live edge.
        if previous != status { applySpeed() }
        updateIdleGuard()
        NowPlayingBridge.shared.update(position: position, duration: duration, isPlaying: isPlaying)
        let window = (pictureInPicture?.isPossible ?? false) && PictureInPicture.isSupported
        if canPictureInPicture != window { canPictureInPicture = window }

        // A picture that stops without the viewer's doing needs an indicator.
        // Both can occur while the bar has long been hidden — and
        // ``hideBarIfIdle(now:)`` keeps it up then, but does not bring it back.
        // Without this line the picture would stand still and nothing would say why: when buffering
        // it looks like a pause you triggered yourself, on an error like
        // a crash.
        if status != previous, status == .buffering || status == .failed {
            noteInteraction()
        }
        // The supply watch counts every buffering message of the current
        // live target — rationale at ``settleSupplyVerdict()``.
        if status != previous, status == .buffering, supplyWatch != nil {
            supplyWatch?.dips += 1
        }

        // **The fallback level for live channels** (roadmap P8, "engine question"):
        // not every provider delivers every channel as a playlist — for the
        // one tested, Nergis HD plays over HLS, Nergis FHD only as a raw stream.
        // If the engine fails on a channel's `.m3u8` address, the same address
        // is tried ONCE as `.ts` over the VLC path — silently,
        // because for the viewer this is not an error but a channel switch
        // that takes a blink longer. Only one attempt per address:
        // if the raw stream fails too, the channel is really dead, and the
        // message says so honestly.
        if status == .playing, !hasPlayedSinceLoad {
            hasPlayedSinceLoad = true
        }

        if status != previous, status == .failed { noteEngineFailure() }

        noteBlindPlayback()
        noteListUsed()

        noteSluggishStart()

        if controller.status == .buffering, lastSeenStatus != .buffering {
            stallReport("buffer empty")
        }
        lastSeenStatus = controller.status
        noteStall(at: controller.position)

        // While seeking, the display stays at the targeted position. Otherwise
        // the engine's report pulls the slider back from under the viewer's hand. The same
        // applies while a jump through the server is running: the old engine still reports
        // from the abandoned position until the switch, and the bar would jerk back.
        if scrubPosition == nil, !isRestarting {
            // **The server's offset is added.** If the stream begins at 14:35,
            // the engine still reports from zero — it knows nothing about it. Without this
            // addition the bar would show 0:00 for a film that is running in the middle,
            // and the reported progress would reset it to the start on the server.
            let fresh = controller.position
            if position != fresh { position = fresh }

            // The sample for the recording — only here, where the position really
            // comes from the engine: during seeking and a server jump
            // ``position`` shows the target, and the measurement counted its own jump as a
            // finding. A jump within the loaded range stays visible as such anyway;
            // ``seek(to:)`` writes the line for it right next to it.
            // **The trace is always filled** (AP1, 2026-09-02). It used to sit behind
            // the debug switch, and so the summary at the end could know
            // nothing — lifting the guard around the message without
            // lifting this one would have been an empty gesture. It is only affordable
            // since ``PlaybackController/droppedVideoFrames`` reads a
            // stored value instead of reaching into the access log
            // twice a second.
            playbackTrace.sample(
                position: position,
                isPlaying: status == .playing,
                isBuffering: status == .buffering,
                date: Date(),
                // Without this line the trace measures everything except what the
                // viewer reported on 2026-08-22 — see
                // ``PlaybackController/droppedVideoFrames``.
                droppedFrames: controller.droppedVideoFrames
            )
        }
        // **The length comes from the server's metadata, not from the engine.** What
        // the engine reports depends on the delivery path — for a playlist that
        // the server is still writing, it can be shorter than the film. The
        // metadata know the full runtime from the start. Only where the server
        // carries no length does the engine's count — an unchanged file, for example,
        // has an honest one.
        if let known = target.duration {
            if duration != known { duration = known }
        } else if controller.duration > 0 {
            let fresh = controller.duration
            if duration != fresh { duration = fresh }
        }

        refreshTrackLists(from: controller)

        // The line for the current position — found by binary search, runs along with the tick.
        let lines = subtitleCues?.lines(at: position) ?? [:]
        if subtitleLine != lines[.bottom] { subtitleLine = lines[.bottom] }
        // **The upper line is a display of its own and not a second one below.**
        // A sign belongs where it stands in the picture; merged with the dialog
        // below, both would be unreadable.
        let above = lines[.top] ?? lines[.middle]
        if subtitleTopLine != above { subtitleTopLine = above }
        refreshSubtitleBitmaps()

        // **"Still watching?" holds the picture** (AP85): the new episode starts, and stands.
        if core.asksStillWatching, isPlaying { engine.controller.pause() }

        // **Intro and recap by themselves**, when the profile wants it (AP85 binge package).
        if let end = core.autoSkip(at: position) { seek(to: end) }

        let episode = core.episode(status: status, location: position, duration: duration)
        hideBarIfIdle(now: .now)

        if let report = episode.report {
            await send(report)
        }

        // At the end it does **not** wait for the counter, and a similar film never starts
        // by itself (F-026, 2026-09-05) — ``Flows/PlaybackCore/episode(status:location:duration:)`` decides both.
        switch episode.step {
        case .next:
            // **Counted only here** — the counter switched, nobody pressed (AP85).
            core.noteAutoAdvance()
            await advance()
        case .close: shouldClose = true
        case .sleep:
            // **The sleep timer** (AP85): stop and leave — the TV goes to its screen saver,
            // the position is signed off on the way out.
            engine.controller.pause()
            shouldClose = true
        case .none: break
        }
    }

    // MARK: - Reports to the server

    /// Sends a report through the source — the mapping onto sign-on, state and
    /// sign-off lives in ``Flows/PlaybackCore/send(_:duration:about:)``, the same one as on the
    /// phone.
    func send(_ report: PlaybackReporter.Report) async {
        guard let source, let itemID = target.itemID else { return }
        await PlaybackCore.send(report, duration: duration, about: Self.route(source, itemID))
    }

    /// The path to the server for a title.
    nonisolated static func route(
        _ source: any ContentSource, _ itemID: String
    ) -> PlaybackCore.ProgressRoute {
        PlaybackCore.ProgressRoute(
            begin: { try await source.beginSession(for: itemID) },
            notify: { state, isPaused in
                try await source.report(progress: state, for: itemID, isPaused: isPaused)
            },
            finish: { location in try await source.endSession(for: itemID, at: location) })
    }
}
