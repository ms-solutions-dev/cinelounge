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

    // MARK: - When nothing progresses

    /// Whether playback is stalled without an error being present.
    ///
    /// **The case that used to stay silent.** Neither VLC nor the system player reports
    /// anything when they make no progress — they report nothing at all. For the viewer
    /// the spinner turns forever, and the concept of this app explicitly states the
    /// opposite: every wait ends in a result or in a message.
    ///
    /// The causes differ by kind, and so does the explanation — for a channel it is
    /// almost always the provider, for a recording it is the server or the file.
    public var isStalled: Bool { core.settled }

    /// What the connection carries and what the film needs — measured by the engine (AP69); the board
    /// uses it to say "Connection to the provider is tight" instead of "Nothing is arriving".
    public var lineFinding: LineFinding? { engine.controller.lineFinding }

    // MARK: - Picture in Picture (AP8)

    /// The host's window controller — only for the system-player host.
    var pictureInPicture: PictureInPicture? { (engine as? EngineHost)?.pictureInPicture }

    /// Opens the window and hands engine and model to the holder.
    public func startPictureInPicture() {
        noteInteraction()
        guard let pip = pictureInPicture, let host = engine as? EngineHost else { return }
        pip.onStarted = { [weak self] in
            guard let self else { return }
            PictureInPictureKeeper.shared.take(host: host, model: self, target: self.target)
            self.leavesForPictureInPicture = true
        }
        pip.onStopped = { [weak self] in
            self?.leavesForPictureInPicture = false
            PictureInPictureKeeper.shared.windowClosed()
        }
        pip.onRestore = { completion in
            PictureInPictureKeeper.shared.requestRestore(completion: completion)
        }
        if !pip.start() {
            Diagnostics.playbackStep("Picture in Picture: not possible right now", since: nil)
        }
    }

    /// How many ticks without movement count as a stall.
    ///
    /// **Counted rather than measured against the clock**, for the same reason as with
    /// progress: measured against a clock, the rule could only be tested by waiting
    /// twelve seconds — and what can only be tested by waiting does not get tested. The tick is
    /// half a second, twenty-four of them are twelve seconds: longer than any buffering
    /// pause a viewer puts up with, and short enough that nobody gives up beforehand.
    ///
    /// **The same twelve seconds as ``Core/StallInterpretation/window``** (check
    /// 2026-09-25, H2): when it flips, the interpretation judges over exactly the time the
    /// position stood still. The two numbers live in two packages; a test
    /// (`stallLimitIsTheInterpretationWindow`) keeps them together.
    static let stallTicks = 24

    /// How long that is in seconds — for the reason given in the log.
    static var stallLimit: TimeInterval { Double(stallTicks) * tickSeconds }

    /// The tick in seconds — for the ``core``, which counts in ticks times step.
    nonisolated static var tickSeconds: TimeInterval {
        Double(tickInterval.components.seconds)
            + Double(tickInterval.components.attoseconds) / 1e18
    }

    /// Watches the stall for one tick — **in the ``core``, as on the phone.**
    ///
    /// Only a channel through the app's own remuxer is interpreted: only ``LiveRemuxSession``
    /// carries a ``Core/RepackerPulse``, and a dead writer of the file reports
    /// itself.
    func noteStall(at enginePosition: TimeInterval) {
        let pulse = target.kind == .live ? remuxHandle as? RepackerPulse : nil
        let flipped = core.observeStall(
            status: status, location: enginePosition,
            loadedUntil: engine.controller.bufferedRange?.upperBound, pulse: pulse)

        // A live channel that has delivered not a single frame after eight seconds
        // gets the raw stream — long before the stall message appears.
        // Rationale at ``liveFallbackTicks``.
        if core.silentTicks == Self.liveFallbackTicks, position == 0 {
            fallBackToRawStream()
        }
        // The bar comes back when the message appears: it sits above it, and
        // a notice you cannot see is no notice.
        if flipped {
            noteInteraction()
            stallReport("picture frozen")
            noteLiveStall()
            // **Dried-up supply is requested again** — rationale at
            // ``Flows/PlaybackCore/resupplyLimit``. Through the same path as a
            // long jump: new address, new connection, same position.
            if let title = target.itemID,
                core.restartAfterSupplyRanDry(
                    title: title, location: enginePosition,
                    loadedUntil: engine.controller.bufferedRange?.upperBound,
                    live: target.kind == .live)
            {
                Diagnostics.playbackStep(
                    "Resupply ran dry at \(Int(enginePosition)) s — new fetch "
                        + "(\(core.resupplyAttempts) von \(PlaybackCore.resupplyLimit))",
                    since: nil)
                scheduleRestart(at: enginePosition)
            }
        }
    }

    /// What is behind the current stall — the board picks its sentence accordingly.
    /// `nil` while nothing is stalled, and for every target without its own remuxer.
    public var stallFinding: StallInterpretation.Finding? { core.stallFinding }

    /// The lines that went into the error trace for this target — the test's tap.
    var stallLines: [String] { core.stallLines }

    /// **The congestion report** — one line that says where it jams, at the
    /// moment it jams: player position, how far it has loaded,
    /// and what the remuxer has to say (``LiveRemuxSession/state``,
    /// ``MatroskaFileSession/state``).
    func stallReport(_ reason: String) {
        var split = ["Player at \(String(format: "%.1f", engine.controller.position)) s"]
        if let loaded = engine.controller.bufferedRange {
            split.append(
                "loaded up to \(String(format: "%.1f", loaded.upperBound)) s (\(String(format: "%.1f", loaded.upperBound - engine.controller.position)) s lead)"
            )
        } else {
            split.append("nothing loaded")
        }
        if let session = remuxHandle as? LiveRemuxSession {
            split.append("Remuxer: " + session.state)
        } else if let file = remuxHandle as? MatroskaFileSession {
            split.append("Remuxer: " + file.state)
        }
        if let dropped = engine.controller.droppedVideoFrames, dropped > 0 {
            split.append("\(dropped) frames dropped")
        }
        Diagnostics.playbackStep("Stall (\(reason)): " + split.joined(separator: ", "), since: nil)
    }

    /// **A channel that stalls repeatedly gets a buffer
    /// instead of proximity to the live edge on its next start** (F-029: Varo HQ, ten jumps in four
    /// minutes; TELE MOOS HQ likewise — the German HQ channels deliver in bursts,
    /// the Turkish ones evenly). The writer reports no drift; the
    /// jumps are the player catching up to the live edge after every "clock waiting".
    /// With the playlist without parts it keeps a distance of three segments, and
    /// a burst in the supply falls into the buffer, not into the picture.
    func noteLiveStall() {
        guard target.kind == .live, target.decision.delivery == .remuxInApp else { return }
        liveStalls += 1
        guard liveStalls == 3, !LowLatencyMemory.shared.isRejected(target.sourceURL) else { return }
        LowLatencyMemory.shared.reject(target.sourceURL)
        Diagnostics.playbackStep(
            "Channel stalls for the third time — from the next start with a buffer instead of staying near the live edge",
            since: nil)
    }

    /// From what distance a jump requests the stream anew — the fallback for
    /// engines that do not know their loaded range.
    ///
    /// Ninety seconds is well above what the two skip buttons
    /// move — ten back, thirty forward — and those paths should keep working without
    /// waiting. It is also far below what counts on a TV as
    /// "seeked somewhere", where a moment of loading time is expected anyway.
    static let localSeekLimit: TimeInterval = 90

    /// Whether this jump is better served through the server.
    ///
    /// **Never with HLS.** The playlist covers the full runtime; the engine
    /// requests the target segment, and the server restarts its ffmpeg there
    /// itself. Requesting the playlist again would only add waiting — and be the way back into
    /// the old bug where every new address triggered a new encode.
    ///
    /// **Likewise with the app's own remuxer, and there it is not a convenience
    /// but a requirement.** Its playlist covers the full runtime and
    /// every piece can be fetched individually — as stated at
    /// ``PlaybackEngineSelector/resumeDelivery(for:)``. The server has nothing to do with this
    /// jump; a new address from it would lead to the raw
    /// Matroska, and Apple's engine does not open that (on-device test 2026-08-11: after a
    /// long jump the picture stayed away, the log said `Start: …
    /// remuxInApp`, but not `Umpacker steht`).
    ///
    /// The system engine also leaves a file delivered unchanged alone:
    /// the endpoint answers range requests there, it seeks everywhere itself.
    ///
    /// That leaves VLC on a raw file. If the engine knows its loaded range,
    /// that decides; otherwise the fixed distance. And everything before the point where the
    /// stream begins at all MUST be requested again: someone who joins at 14:35
    /// and wants to go back to the start asks for a position that does not occur in this
    /// stream at all.
    func needsRestart(for destination: TimeInterval) -> Bool {
        guard source?.canStartAtOffset == true, target.itemID != nil else { return false }

        if target.decision.delivery == .hls || target.decision.delivery == .remuxInApp {
            return false
        }
        let buffered = engine.controller.bufferedRange
        if target.decision.delivery == .directPlay, buffered != nil { return false }
        // **Without offset** (AP8): the server-side start point was dropped with the
        // VLC removal — it has been zero since, and every calculation
        // with it was a ±0.
        if let buffered {
            return !buffered.contains(destination)
        }
        return abs(destination - position) > Self.localSeekLimit
    }

    func scheduleRestart(at destination: TimeInterval) {
        restartGeneration += 1
        let generation = restartGeneration
        restartTask?.cancel()
        isRestarting = true
        restartTask = Task { [weak self] in
            await self?.restart(at: destination, generation: generation)
        }
    }

    /// Fordert denselben Titel ab einer anderen Stelle an.
    func restart(at destination: TimeInterval, generation: Int) async {
        defer {
            // Only the most recent jump may release the lock: a superseded one that
            // is still finishing here would otherwise take the display calm away from the current one.
            if generation == restartGeneration { isRestarting = false }
        }
        guard let source, let itemID = target.itemID else { return }
        guard generation == restartGeneration else { return }
        guard let full = try? await source.item(id: itemID), let media = full.source else { return }
        guard generation == restartGeneration else { return }

        // **The same planning as at start** (``Core/PlaybackPlan``), with the selected
        // tracks instead of the start choice — a rebuild that forgot them would jump back to
        // the default track in the middle of the film. The plan reads the ASS choice and the connection
        // itself; until 2026-09-24 no ASS choice was passed here, and the default `false`
        // switched the engine in the middle of the film.
        let plan = PlaybackPlan.build(
            title: full, media: media, source: PlaybackPlan.Source(source), preference: preference,
            device: .thisDevice,
            reason: .jump(from: destination, audio: chosenAudioIndex, subtitles: chosenSubtitleIndex))
        let decision = plan.decision
        let url: URL
        do {
            url = try await source.streamURL(for: itemID, decision: decision)
        } catch {
            // **With reason and into the error trace** (user request 2026-08-29).
            // `Diagnostics.network` is a pure logger — it creates no
            // entry the viewer can submit. This message therefore never
            // reached the diagnostics, and the `try?` condensed every
            // refusal by the source into "No address received".
            Diagnostics.playbackProblem(
                "Seek not possible: \(Diagnostics.explain(error)) — identifier \(itemID), "
                    + "delivery path \(decision.delivery)",
                since: nil
            )
            return
        }
        guard generation == restartGeneration else { return }

        // The counter stays: it is the same title, just at a different position. A new one
        // would hold the server at the old position for the duration of its timeout — and
        // register the session a second time. It is kept in the ``core`` as long as it
        // has not signed off (player check, finding S10).
        adopt(
            PlaybackTarget(
                itemID: target.itemID,
                title: target.title,
                subtitle: target.subtitle,
                url: url,
                decision: decision,
                startAt: destination,
                duration: target.duration,
                seriesID: target.seriesID,
                media: media,
                chapters: target.chapters,
                // The language of the selected tracks as a preference for engines that
                // select within the stream themselves: if the subtitle choice changes the engine
                // (image subtitles → VLC), it finds the track only through this — the
                // number in the address would have no recipient there.
                preferredAudioLanguage: plan.audioLanguage ?? target.preferredAudioLanguage,
                preferredSubtitleLanguage: plan.subtitleLanguage ?? target.preferredSubtitleLanguage,
                kind: target.kind
            )
        )
    }

    /// Whether a new target keeps the context of the old one.
    ///
    /// **The difference between "somewhere else" and "somewhere else in the same film".**
    /// A long jump rebuilds the engine and goes through the same path as
    /// an episode change; for everything attached to the **title** — sections,
    /// cast, preview images — it is not a change, though. It was cleared away
    /// every time anyway, and it is only fetched again on an episode change:
    /// after the first jump through the server there was no intro-skip button
    /// for the rest of the film (roadmap AP4).
    ///
    /// **Without an identifier it counts as "different title", and that is intentional:** channels carry
    /// none, and two channels in a row are two different things — there
    /// things must be cleared, otherwise the cast of the previous one would sit above the
    /// new picture.
    nonisolated static func keepsContext(
        from current: PlaybackTarget, to next: PlaybackTarget
    )
        -> Bool
    {
        guard let id = current.itemID else { return false }
        return next.itemID == id
    }

    /// What the person prefers for this playback — **with the level the player
    /// received.** The rest is read by ``Core/PlaybackPlan/Preference/effective(interfaceLanguage:device:)``
    /// from the person's compartment, at the same place as the start and the phone.
    var preference: PlaybackPlan.Preference {
        var preference = PlaybackPlan.Preference.effective(interfaceLanguage: interfaceLanguage)
        preference.quality = quality
        return preference
    }

    /// Clamps a position to the film.
    ///
    /// Jumping past the end ends playback in both engines,
    /// and the title counts as watched afterwards — one key press too many at the end
    /// would therefore have a consequence nobody expects. The last two seconds stay
    /// free for that reason.
    func clamp(_ value: TimeInterval) -> TimeInterval {
        if let window = timeShiftWindow { return window.target(value) }
        guard duration > 0 else { return max(0, value) }
        return min(max(0, value), max(0, duration - 2))
    }
}
