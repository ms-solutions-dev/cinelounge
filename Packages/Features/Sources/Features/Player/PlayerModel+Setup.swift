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

    // MARK: - Setup

    // No `deinit`. It would run without actor binding, and Swift 6 refuses access to the
    // engine and the running task there. The teardown is in ``finish()`` and is called when
    // the view disappears — the full reasoning is in ``NativePlaybackEngine``.

    /// A built remuxer: the address it serves from, the thing that keeps it alive, and the way
    /// to tear it down.
    public struct StartedRemux {
        /// The local playlist the engine receives.
        public let url: URL
        /// To be held as long as playback runs — see ``PlayerModel/remuxHandle``.
        public let handle: AnyObject
        public let stop: @Sendable () -> Void
        /// The measured frame rate, if the remuxer already knows it — it travels from here into
        /// ``PlaybackTarget/contentFrameRate``.
        public let frameRate: Double?
        /// The marks of the startup, for the breakdown in the startup line.
        public let marks: StartupMarks?
        /// The cache for the direct renderer — instead of an address. See
        /// ``PlaybackDelivery/renderInApp``.
        public let samples: SampleQueue?
        /// A corrected start position, if the remuxer cannot serve the requested one — see
        /// ``MatroskaFileSession/totalDuration``.
        public let startAt: TimeInterval?
        /// A note for the bar — for example, that the file is truncated.
        public let hint: String?

        public init(
            url: URL, handle: AnyObject, stop: @escaping @Sendable () -> Void,
            frameRate: Double? = nil, marks: StartupMarks? = nil, samples: SampleQueue? = nil,
            startAt: TimeInterval? = nil, hint: String? = nil
        ) {
            self.url = url
            self.handle = handle
            self.stop = stop
            self.frameRate = frameRate
            self.marks = marks
            self.samples = samples
            self.startAt = startAt
            self.hint = hint
        }

        /// From the shared build.
        public init(_ started: RemuxStart.Started) {
            self.init(
                url: started.address, handle: started.handle, stop: started.finish,
                frameRate: started.frameRate, marks: started.marks, samples: started.samples,
                startAt: started.startAt, hint: started.hint)
        }
    }

    /// Who builds the remuxer.
    ///
    /// **As an input from outside and not hard-wired in the model**, and the reason is in this
    /// morning's bug history: as long as ``PlayerModel`` created its remuxers itself, the whole
    /// path could not be tested — it needed a server, a file and a network. That is exactly why
    /// it went unnoticed that ``adopt(_:)`` skipped it: no test could see it.
    public typealias RemuxBuilder = @MainActor (PlaybackTarget) async throws -> StartedRemux

    /// The real remuxer — **the shared build** (AP58 R4, ``Flows/RemuxStart``):
    /// continuous transport stream for channels, Matroska with partial requests for everything
    /// else. Only the TV adopts a running preview (``LiveHandover``).
    ///
    /// - Parameter ablage: where the memory of the tight suppliers lives — the same store that
    ///   ``settleSupplyVerdict()`` writes to.
    public static func liveOrFileRemux(store: any KeyValueStore) -> RemuxBuilder {
        { target in
            StartedRemux(
                try await RemuxStart.build(
                    target,
                    environment: RemuxStart.Context(
                        store: store, takesOverPreview: true,
                        timeOffset: TimeShift.capacity(.tv))))
        }
    }

    /// Accepts a later-supplied, measured frame rate.
    ///
    /// It reaches the engine via the host; whether it is registered is decided by
    /// ``FrameRateRegistration`` — a better source may always.
    func adoptFrameRate(_ rate: Double) {
        Diagnostics.verbose("Frame rate supplied late: \(rate) Hz from the built segment")
        engine.adopt(contentFrameRate: rate)
    }

    /// Starts the engine for this target — **with the remuxer in front, if the decision calls
    /// for it.**
    ///
    /// **The one place where the engine starts up.** There used to be two: ``begin()`` went
    /// through the remuxer, ``adopt(_:)`` called `engine.start` directly. As a result every
    /// rebuild — resume jump, channel switch, next episode — got the **raw** address: a
    /// Matroska or a transport stream that Apple's engine does not open. On the device that
    /// looked like "starts, no longer after seeking" (finding 2026-08-11); the log showed
    /// `Start: … remuxInApp` without the line `Umpacker settled` above it — the only visible
    /// difference.
    ///
    /// The old remuxer is torn down first. It holds a server on `127.0.0.1` and a connection to
    /// the source; having both open twice is the end of playback with the provider and, with
    /// the media server, a second session that stays listed there as "playing" for hours.
    /// **Without a remuxer the start stays synchronous**, and that is a guarantee and not a
    /// subtlety: after ``adopt(_:)`` the engine runs, not "soon". Three checks rest on it —
    /// next episode, audio track switch, fast seeking —, and on the TV a detour through a task
    /// would mean a pass of the event loop between key press and picture.
    func startEngine(_ next: PlaybackTarget) {
        engineStartGeneration += 1
        let generation = engineStartGeneration
        // **Cancel the running build, not only overtake it.** The generation check below does
        // invalidate its result — but only once it is finished. Until then the overtaken build
        // holds its own connection to the provider, and the provider allows ONE: two remuxers
        // snatched the line away from each other (device finding 2026-08-15, fifth evening test: two
        // sessions cut piece 0 at the same time, both starve, "starts, hangs, works on the second
        // open"). The cancellation pulls the build out of its sleep at the next wait point; its
        // session tears itself down via the zombie lock.
        engineStartTask?.cancel()
        // **And the handle is released, not only the build cancelled.** The cancelled build
        // returns through the generation check without nulling anything; if the new delivery is
        // `directPlay`, the exit just below jumps out and nobody would get to it any more. What
        // would remain is a handle on a long-dead task — and the startup report reads from it
        // "the remuxer is still building".
        engineStartTask = nil
        // Every run has to earn its "has played" anew — that decides whether a teardown gets a
        // rebuild or the fallback.
        hasPlayedSinceLoad = false
        isListInUse = false
        startTicks = 0
        // The guard starts anew with every run — the handle drops, the interpretation only for a
        // different target (finding H1).
        core.newStartup(target: next.sourceURL.absoluteString)
        // The verdict on the departing supply, then the new guard.
        settleSupplyVerdict()
        if next.kind == .live { supplyWatch = (next.sourceURL, 0) }
        releaseRemux()
        // For the crash watcher: if the app dies from here on, the trace says at which target and
        // with which engine.
        CrashGuard.note(
            activity: "Wiedergabe „\(next.title)“ — Motor \(next.decision.engine), "
                + "Lieferweg \(next.decision.delivery)")

        guard next.decision.runsOverRepacker || Self.wantsStartRelay(next) else {
            engine.start(next)
            return
        }

        // **First shut down the old engine, then build.** The provider allows ONE connection — as
        // long as the old player holds its playlist, the remuxer gets no data and runs into
        // `noContentInTime` (device finding 2026-08-15, second evening test: exactly in the handoff
        // from the silent playlist to the raw stream). During the build the viewer sees the still
        // frame anyway; continuing sound from the old channel would also be wrong.
        engine.stop()

        engineStartTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await remuxedIfNeeded(next)
            // Overtaken: the viewer switched on while the remuxer was building. **Only the OWN
            // session is torn down** — `releaseRemux()` was here, and that was a race (device finding
            // 2026-08-15, "raw stream dead without ever playing", while zapping): by then the stored
            // handles may already belong to the NEXT session, and whoever releases them lets its
            // server die while the engine plays against the dead port.
            // The cancellation counts like a new generation: ``finish()`` cancels without a successor,
            // and a cancelled build must no longer give the engine a half-finished address.
            guard generation == engineStartGeneration, !Task.isCancelled else {
                outcome.remux?.stop()
                return
            }
            // Only remember after the check — before it, the handles belonged to nobody and were
            // overwritten by every straggler.
            if let started = outcome.remux {
                remuxHandle = started.handle
                stopRemux = started.stop
                // The remuxer's marks into the startup line — see ``StartupMarks``.
                if var timing = startupTiming {
                    timing.remux = started.marks
                    startupTiming = timing
                }
            }
            // **The target is kept up to date, and that is no cosmetics.** If the remuxer fails, the
            // fallback takes over — until then the overlay still claimed `native/remuxInApp`, and
            // exactly this line pointed in the wrong direction here for half a morning.
            target = outcome.target
            engine.start(outcome.target, samples: outcome.remux?.samples)
            // **Done means done.** The handle used to be released only in ``finish()``; after the
            // first remux start it stayed set for the rest of the session, and the startup report
            // concluded from it "the remuxer is still building" — in the device log of 2026-08-23 three
            // seconds after the engine had demonstrably started. Inside the generation guard, because
            // the early exit above already belongs to the next generation and must not delete its
            // handle.
            engineStartTask = nil
        }
    }

    /// Builds the remuxer if the decision calls for it.
    ///
    /// **And falls back if it cannot.** An MKV file without a seek table cannot be split into
    /// pieces; a provider without partial requests even less. Both occur, neither is a reason
    /// for a black picture — then the second engine takes over again, as before.
    /// Builds the remuxer and returns it **instead of remembering it** — remembering is decided
    /// by the caller after its generation check. Previously this function wrote the handles
    /// itself, and a straggler thereby overwrote the successor's session (the zapping race of
    /// 2026-08-15).
    /// Whether a target gets the playlist with a start mark: a recording via the server's
    /// chunking, continued at a position.
    nonisolated static func wantsStartRelay(_ target: PlaybackTarget) -> Bool {
        RemuxStart.needsStartMark(target)
    }

    func remuxedIfNeeded(
        _ target: PlaybackTarget
    ) async -> (target: PlaybackTarget, remux: StartedRemux?) {
        // **Continue Watching via the playlist with a start mark** — see ``HLSStartRelay``.
        if Self.wantsStartRelay(target) {
            do {
                let relay = StartedRemux(try await RemuxStart.startMark(target))
                return (target.rerouted(to: relay.url), relay)
            } catch {
                Diagnostics.playbackProblem(
                    "Continue Watching: playlist not rewritten (\(Diagnostics.explain(error))) — "
                        + "the engine fetches it itself", since: nil)
                return (target, nil)
            }
        }
        guard target.decision.runsOverRepacker else { return (target, nil) }

        do {
            let started = try await remux(target)
            // **The measured frame rate travels along** (AP2 · U4). The remuxer's build plan is
            // `static` and has no model at hand; so it is connected here, where there is one. Only the
            // file path measures: the live session already counts its intervals at startup and brings
            // the number with it.
            if let file = started.handle as? MatroskaFileSession {
                file.onFrameRate = { [weak self] rate in
                    Task { @MainActor in self?.adoptFrameRate(rate) }
                }
            }
            // **`since: Date()` is not a measurement.** ``Diagnostics/elapsed(since:)`` computes
            // against the moment of reporting; a reference point created one line earlier yields, by
            // construction, `[  0.0s]` — and exactly that appeared here 131 times in the session of
            // 2026-08-23. The startup has a real zero point: ``startupTiming`` is set in ``begin()`` and in
            // ``adopt(_:)``, both times before ``startEngine(_:)``.
            //
            // After a live teardown the engine is set up again without a new startup measurement; the
            // field then counts from the original start. That is intended — it is the viewer's waiting
            // time —, but has to be kept in mind when reading.
            //
            // The number only becomes visible in the system log (`log show`):
            // ``Diagnostics/Trace/Entry/reportLine`` does not carry the elapsed time, so it is still
            // not in the submitted report.
            Diagnostics.playbackStep(
                started.samples != nil
                    ? "Remuxer is up — buffer for the renderer"
                    : "Remuxer is up — \(started.url.absoluteString)",
                since: startupTiming?.startedAt)
            return (
                target.rerouted(
                    to: started.url, frameRate: started.frameRate, startAt: started.startAt,
                    subtitle: started.hint.map { hint in
                        [target.subtitle, hint].compactMap { $0 }.filter { !$0.isEmpty }
                            .joined(separator: " · ")
                    }),
                started
            )
        } catch {
            // **The chain is shared** (``Flows/RemuxStart/fallback(after:target:sourceIsChunked:)``);
            // here only what the TV makes of it.
            let sourceIsChunked =
                source?.canStartAtOffset == true && target.itemID != nil
            switch RemuxStart.fallback(
                after: error, target: target, sourceIsChunked: sourceIsChunked)
            {
            case .superseded:
                // Cancelled means overtaken: ``startEngine(_:)`` stopped this build itself, and nobody
                // looks at the result any more.
                return (target, nil)

            case .rejection(let status):
                // **A refusal gets no fallback.** The engine runs on the raw address, fails there at once
                // honestly, and the viewer gets the notice instead of twenty seconds of loading circle.
                Diagnostics.playbackProblem(
                    "The provider refuses this channel (\(status)) — no fallback",
                    since: startupTiming?.startedAt)
                return (
                    target.rerouted(to: target.url, decision: RemuxStart.raw(target.decision)),
                    nil
                )

            case .serverChunks(let served):
                // **Via `playbackProblem`, not merely into the system log** — the failure reason belongs in
                // the trace (Draikliak, 2026-08-15). **`explain`**, because the raw dump of an `NSError` carries
                // the stream address including credentials.
                Diagnostics.playbackProblem(
                    "Remuxing not possible — \(Diagnostics.explain(error))",
                    since: startupTiming?.startedAt)
                if let source, let itemID = target.itemID,
                    let url = try? await source.streamURL(for: itemID, decision: served)
                {
                    Diagnostics.playbackStep(
                        "Falling back to the server's chunking — native, without remuxer",
                        since: startupTiming?.startedAt)
                    let chunked = target.rerouted(to: url, decision: served)
                    // The fallback also starts at that position (F-008: without the start mark the player
                    // first fetched piece 0, 40 s without a picture).
                    if Self.wantsStartRelay(chunked),
                        let relay = try? await RemuxStart.startMark(chunked)
                    {
                        return (chunked.rerouted(to: relay.address), StartedRemux(relay))
                    }
                    return (chunked, nil)
                }
                return (
                    target.rerouted(
                        to: target.url,
                        decision: RemuxStart.raw(target.decision, reason: .containerNotNativelySupported)),
                    nil
                )

            case .lastAttempt(let raw):
                Diagnostics.playbackProblem(
                    "Remuxing not possible — \(Diagnostics.explain(error))",
                    since: startupTiming?.startedAt)
                // **No more VLC** (user decision, final on 2026-08-16): the native attempt on the raw address is
                // the last straw and reports its failure visibly.
                if target.kind == .live {
                    Diagnostics.playbackProblem(
                        "Channel could not be remuxed — no VLC fallback any more, "
                            + "the error belongs at the root", since: startupTiming?.startedAt)
                }
                return (target.rerouted(to: target.url, decision: raw), nil)
            }
        }
    }

    /// Starts playback and fetches what the server knows about it.
    public func begin() async {
        if resumesFromPictureInPicture {
            resumesFromPictureInPicture = false
            Diagnostics.playbackStep("Picture in Picture: engine taken over, no restart", since: nil)
            startTicker()
            return
        }
        // **Release the image cache before the player starts up.**
        //
        // The upper limit of the cache is explicitly derived under the assumption that it is
        // released here — except that it was never done; the method was dead code. During
        // playback up to 160 MB of decoded images thus sat next to the player's buffers. tvOS
        // answers that with memory pressure, and `NSCache` then evicts uncontrolled: on returning
        // from the film the overview was empty and reloaded everything.
        await ImageCache.shared.releaseMemory()
        // **The clock runs from here, not from the first tick.** What should be measured is what
        // the viewer experiences: from the press to the picture. The usual tick beats every
        // 500 ms — far too coarse for a number on which a decision about a second playback engine
        // hangs.
        // A new startup, so also a new interim result — see ``reportedSlowStart``.
        reportedSlowStart = false
        startupTiming = StartupTiming(
            opening: "\(target.decision.engine.rawValue)/\(target.decision.delivery.rawValue)",
            startedAt: Date()
        )
        startEngine(target)
        startStartupProbe()
        // **The system controls know what is playing** (AP8): title in Control Center, play/pause
        // via Siri and the TV app. The poster, if the source has one — channels have none.
        announceNowPlaying()
        // From now on a picture is playing (or opening) — the screen saver has to wait. The tick
        // keeps the lock up to date afterwards; set here so that it applies already while
        // opening and not only at the first tick.
        updateIdleGuard()
        if DebugMode.current.isOn {
            playbackTrace.begin(
                "\(target.decision.engine.rawValue)/\(target.decision.delivery.rawValue): "
                    + target.title,
                at: Date(),
                isLive: target.kind == .live
            )
        }
        startTicker()
        await loadContext()
    }

    /// Ends playback and reports.
    ///
    /// Must be called from outside when the view disappears: otherwise the sound keeps playing,
    /// and on the server a session stays listed as "playing" for hours and hides what the other
    /// devices are playing at that moment.
    public func finish() {
        // **First advance the number, then tear down.** A remuxer that is just still building
        // would otherwise run to its end after the view has disappeared and start an engine for a
        // screen nobody sees any more — including a connection to the provider, which allows only
        // one.
        engineStartGeneration += 1
        engineStartTask?.cancel()
        engineStartTask = nil
        releaseRemux()
        ticker?.cancel()
        ticker = nil
        // Also the startup measurement — with a channel that never delivers a picture it would
        // otherwise keep running for another thirty seconds for a view nobody sees any more.
        startupProbe?.cancel()
        startupProbe = nil
        // A jump still running through the server would, after the view has disappeared, have
        // nobody left to start for.
        restartTask?.cancel()
        restartTask = nil
        // The same reason as with `restartTask` — only for the delayed rebuild after a live
        // teardown (remuxer check, finding 7, 2026-09-27).
        dropRestartTask?.cancel()
        dropRestartTask = nil

        // The sign-off carries the **last known** position and not the one the engine reports
        // after stopping — some report null there, and the title would then appear again from the
        // start under "Continue Watching".
        let last = position
        if let report = core.finish(at: last) {
            // Without waiting: the view is disappearing, there is nobody left who could react to the
            // server's answer. The task keeps itself alive until the report is out.
            deregistration = Task { await send(report) }
        }

        // The finding of the recording, before the engine disappears. As a measurement into the
        // trace, not into the bare system log — from there it travels with the report to the
        // server, where someone reads it.
        //
        // **Without a debug bracket, and that is the point** (AP1, 2026-09-02): `if DebugMode.current.isOn`
        // was here, and so a session with dropouts produced **zero** error lines — the diagnostics
        // knew the defect only if one already suspected it. If the summary reports a defect, it now
        // goes out as such; if it says "ran through", ``Diagnostics/probe(_:verdict:)`` still files
        // it only with the switch flipped.
        reportTrack()

        settleSupplyVerdict()
        // **The picture of the place where playback continues** — for "Continue Watching", before
        // the engine goes (2026-10-01). Only for titles with progress and only once something has
        // really been watched: the first seconds mostly show the intro or black.
        if target.kind == .recording, last > 30, let identifier = target.itemID,
            let image = engine.stillFrame()
        {
            StillFrameStore.create(image, forItem: identifier)
            // The shelf on the home screen shows the same picture — tvOS otherwise only asks again when
            // the app goes to the background.
            HomeShelf.reportChange()
        }
        engine.stop()
        releaseIdleGuard()
        CrashGuard.note(activity: nil)
        NowPlayingBridge.shared.end()
    }

    /// Delivers the verdict on the supply of the departing live target.
    ///
    /// **The ALPA mitigation** (2026-08-16): channels whose supply runs only barely in real time (75
    /// buffer reports in 79 s) get a large startup buffer at the next start — a few seconds of
    /// later start against a cushion that carries the fluctuations. A clean run heals the entry
    /// again: if the channel runs smoothly, it should also start fast again.
    func settleSupplyVerdict() {
        guard let watch = supplyWatch else { return }
        supplyWatch = nil

        var memory = SlowSourceMemory.load(from: rawStreamStore)
        if watch.dips >= SlowSourceMemory.stallThreshold {
            memory.remember(watch.source)
            memory.save(to: rawStreamStore)
            // As a defect and not as a tick: the line names a channel whose supply ran only barely in
            // real time.
            Diagnostics.playbackProblem(
                "Supply tight (\(watch.dips) buffer reports) — the next start "
                    + "takes the large startup buffer. \(memory.count) channels remembered.",
                since: nil)
        } else if watch.dips < SlowSourceMemory.stallThreshold,
            memory.needsGenerousWarmup(watch.source)
        {
            // **Forgotten under the same threshold under which it is remembered.** `dips == 0` was here,
            // and this imbalance made entries sticky: remembering began at six reports, forgetting only
            // at flawless zero — a channel with a single report stayed permanently listed as "tight"
            // and started for fifteen seconds forever, although by our own rule it is not tight at all.
            //
            // Noticed 2026-08-23: the slow audio decoder produced 11 to 22 buffer reports per channel on
            // the evening of 2026-08-22 — far above the threshold. These channels would have been branded
            // permanently afterwards, although the cause with the C port is long gone.
            memory.forget(watch.source)
            memory.save(to: rawStreamStore)
            Diagnostics.probe(
                "Supply back to normal (\(watch.dips) buffer reports) — "
                    + "the large startup buffer is dropped")
        }
    }
}
