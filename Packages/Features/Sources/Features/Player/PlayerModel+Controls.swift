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

    // MARK: - Controls

    /// Seeking is allowed for anyone watching a recording — or a channel with a disk ring
    /// (AP9): then the list holds minutes, and AVPlayer seeks within it by itself.
    public var isSeekable: Bool { target.isSeekable || hasLiveTimeShift }

    /// Whether the running channel can be rewound — **the shared switch**
    /// (AP58 G1, ``Flows/TimeShift/applies(kind:deliveryRoute:session:)``).
    public var hasLiveTimeShift: Bool {
        TimeShift.applies(
            kind: target.kind, deliveryRoute: target.decision.delivery, session: remuxHandle)
    }

    /// The window in the buffer while a channel with time shift is playing.
    public var timeShiftWindow: TimeShift.Window? {
        guard hasLiveTimeShift else { return nil }
        return TimeShift.Window(engine.controller.timeShiftWindow)
    }

    /// Whether the position lies behind the running programme — then the label reads
    /// "Time-shifted" instead of "Live".
    public var isBehindLive: Bool {
        guard let window = timeShiftWindow else { return false }
        return !window.atEdge(at: displayPosition)
    }

    /// Back to the live edge — a jump far past the end, which AVPlayer trims to the edge of the
    /// window.
    public func jumpToLive() {
        noteInteraction()
        guard hasLiveTimeShift else { return }
        Diagnostics.verbose("Back to live")
        cancelScrub()
        engine.controller.seekToLiveEdge()
    }

    // MARK: - Background

    /// The app goes to the background (Home screen, other content): tvOS pauses the player —
    /// what is remembered is whether it was playing.
    public func noteBackground() {
        wasPlayingBeforeBackground = isPlaying
        Diagnostics.verbose("Background: player \(isPlaying ? "was playing" : "was paused")")
    }

    /// Back in the foreground: what was playing keeps playing — a channel at the live edge, not
    /// where it was stopped (F-041: "does not play immediately from live").
    public func noteForeground() {
        guard wasPlayingBeforeBackground else { return }
        wasPlayingBeforeBackground = false
        if target.kind == .live {
            // **A channel is set up anew, not resumed** (F-008: "foreground: keeps playing" — and 30 s
            // later the teardown, because the connection to the provider had broken in the
            // background). The same move as with the live teardown: same address, fresh startup.
            Diagnostics.verbose("Foreground: channel is set up again")
            startEngine(target.rerouted(to: target.sourceURL))
            return
        }
        Diagnostics.verbose("Foreground: player keeps playing")
        engine.controller.play()
    }

    /// Whether playback is running — **including "buffering"**.
    ///
    /// The difference decides the symbol on the middle button and what a press on it does.
    /// "Buffering" means: the engine is playing, the data just does not keep up. Anyone who
    /// reads that as "stopped" turns both around — on the button the play symbol appears when it
    /// stalls, and the press on it calls `play()` on a running engine instead of pausing. The
    /// viewer could not pause precisely when the picture is already standing still.
    ///
    /// This computation stood **before** the callback in the VLC engine; the order is reasoned
    /// at ``VLCPlaybackEngine``.
    public var isPlaying: Bool {
        status == .playing || status == .buffering
    }

    /// Whether data is currently being waited for.
    ///
    /// Separate from ``isPlaying``, because the viewer has to be told: over a thin line —
    /// measured 0.3 Mbit/s through the tunnel — a standing picture cannot otherwise be told
    /// apart from a self-triggered pause, and one presses around on the remote while the line is
    /// working.
    public var isBuffering: Bool { status == .buffering }

    /// Whether the engine has given up.
    public var hasFailed: Bool { status == .failed }

    // MARK: - Playback rate

    /// The speed steps on offer.
    ///
    /// **Five and not ten.** A phone's slider can be finer — there a finger slides. Here one
    /// presses, and every step costs a press; offering 1.1× costs five presses up to 2 and
    /// answers no question. The steps are the ones there are reasons for: slower for a hard to
    /// understand passage, faster for an intro one knows.
    ///
    /// **Without 0.25 and without 3.** Below half, speech becomes unintelligible, and above it
    /// does too — and the system's pitch correction only carries in between.
    public nonisolated static let speedSteps: [Double] = SpeedChoice.slots

    /// Whether this engine can change the speed at all.
    ///
    /// **The answer comes from the engine and is not guessed** — see
    /// ``Core/PlaybackController/supportsSpeed``. The system player can; whoever cannot does not get
    /// to see the item at all. An item that does nothing is worse than none: one presses and
    /// looks for the fault in oneself.
    /// **Never for a channel since AP58 G1** (``Flows/SpeedChoice/isOffered(supportsSpeed:kind:)``).
    public var supportsSpeed: Bool {
        SpeedChoice.isOffered(supportsSpeed: engine.controller.supportsSpeed, kind: target.kind)
    }

    /// Changes the speed.
    ///
    /// **On the TV it is a choice and not a gesture** (AP31, 2026-09-11). On the phone a long
    /// press holds the film at double speed; that does not work here — an edge press only
    /// arrives as its own event from the 2021 remote on, and this project has already seen nine
    /// places die of this property (see "Two remotes, two behaviours"). So an item in the track
    /// choice that every remote can reach.
    ///
    /// **It applies to this title and not to the next.** The contract says so explicitly: an
    /// engine that remembers the speed carries it over to the next title — and nobody would find
    /// the switch again that they never consciously flipped. Resetting therefore happens here,
    /// when the next engine starts.
    public func setRate(_ fresh: Double) {
        noteInteraction()
        guard supportsSpeed, fresh != rate else { return }
        rate = fresh
        engine.controller.setRate(fresh)
        Diagnostics.probe("Playback rate: \(fresh)×")
    }

    /// Puts the chosen speed back on the running picture.
    ///
    /// **Necessary because `rate` is also the switch for start and stop.** The system player
    /// sets the rate to 1 when resuming — anyone who had chosen 1.5× before would see normal
    /// speed after every pause, without the display having changed. Two truths about the same
    /// question.
    func applySpeed() {
        guard rate != 1, supportsSpeed, isPlaying else { return }
        engine.controller.setRate(rate)
    }

    public func togglePause() {
        noteInteraction()
        // **One press, one switch** (F-042: "clock waiting" and "clock running" in the same
        // second). Since Now Playing, the play/pause key arrives twice — via SwiftUI and via the
        // system commands of Control Center. The second call within a quarter second is the same
        // press and is discarded.
        let now = Date()
        guard now.timeIntervalSince(lastToggleAt) > 0.25 else {
            Diagnostics.verbose("Play/Pause: second call for the same press — discarded")
            return
        }
        lastToggleAt = now
        if isPlaying {
            engine.controller.pause()
        } else {
            engine.controller.play()
        }
    }

    /// Leaves playback at the viewer's request.
    ///
    /// Exists so that the error case has a visible way out. Silent closing would be no solution:
    /// a picture that disappears without any action cannot be told apart from a swallowed key
    /// press — and the viewer starts the same title again right away.
    /// Once more — same title, same path, from the start.
    ///
    /// **The finding** (AP5 · B5, expert pass 2026-08-24): the error screen says "A second attempt
    /// is usually worthwhile", and the only button read "Back". The second attempt cost four
    /// presses — with a provider that allows **one** connection, retrying is the most frequent
    /// operation of all.
    ///
    /// Via ``PlaybackTarget/sourceURL`` and not via `url`: when the remuxer is running, `url`
    /// points to `127.0.0.1` — a retry there would run against a server that has just failed.
    /// The same move as with the silent rebuild after a live teardown.
    ///
    /// **With a new counter if the old one has signed off** (player check, finding S5): after
    /// `.failed` it closed the session and stays silent for good. Until then the film ran after
    /// the second attempt without sign-in, without progress and without sign-off, and the resume
    /// point on the server stayed at the failure point.
    public func retry() {
        Diagnostics.playbackStep("Second attempt on press", since: startupTiming?.startedAt)
        core.newTarget(
            reportsProgress: target.tracksProgress, isRecording: target.kind == .recording,
            sameTitle: true)
        startEngine(target.rerouted(to: target.sourceURL))
    }

    public func close() {
        shouldClose = true
    }

    /// Jump by a fixed amount, for the two outer buttons.
    public func skip(by seconds: TimeInterval) {
        noteInteraction()
        guard isSeekable else { return }
        seek(to: position + seconds)
    }

    public func seek(to newPosition: TimeInterval) {
        guard isSeekable else { return }
        let clamped = clamp(newPosition)

        // **Only VLC needs the detour through the server.** With HLS, Apple's engine simply
        // requests the segment in which the target position lies, and the server restarts its
        // ffmpeg there by itself; with unchanged delivery the engine jumps via range requests. For
        // VLC on a raw Matroska the old rule still applies: the jump depends on the seek index at
        // the end of the file, and the stream is requested anew instead — with the target position
        // as `startTimeTicks`.
        if needsRestart(for: clamped) {
            // Which of the two kinds of jump took effect belongs in the detailed recording: in the
            // ``PlaybackTrace`` an intentional jump looks like a finding, and only with this line next
            // to it can the two be told apart.
            Diagnostics.verbose(
                "Seek to \(Int(clamped)) s — outside what is loaded, new request to the server"
            )
            position = clamped
            scheduleRestart(at: clamped)
            return
        }

        Diagnostics.verbose("Seek to \(Int(clamped)) s — within what is loaded, the engine seeks itself")
        position = clamped
        // The engine counts in its own stream, and that starts at zero even when it lies in the
        // middle of the film in terms of content.
        engine.controller.seek(to: clamped)
    }

    // MARK: - Chapters

    /// Whether there are chapter jump targets.
    ///
    /// From two marks: a single one almost always sits at zero and would offer only the start of
    /// the film — for that there is "from the start" on the detail page.
    public var hasChapters: Bool {
        ChapterJump.hasChapters(kind: target.kind, chapters: target.chapters)
    }

    /// The chapter starts as a fraction of the runtime — for the marks on the rail. The edges
    /// stay free: a mark at zero would lie under the handle, one at one under the remaining time.
    public var chapterFractions: [Double] {
        ChapterJump.fractions(kind: target.kind, chapters: target.chapters, duration: duration)
    }

    /// Jumps to the next or previous chapter start respectively.
    ///
    /// The rules — lead-in when skipping ahead, grace period when going back — are tested
    /// functions at ``Chapter``.
    public func jumpToChapter(forward: Bool) {
        guard hasChapters, isSeekable else { return }
        noteInteraction()

        guard
            let destination = ChapterJump.target(
                kind: target.kind, chapters: target.chapters, location: displayPosition, forward: forward)
        else { return }

        cancelScrub()
        seek(to: destination)
    }

    // MARK: - Showing and hiding the bar

    /// How long the bar stays without input.
    ///
    /// Four seconds: long enough to read the remaining time, short enough that it does not stay
    /// in the picture permanently. The template shows a film without interaction — that is the
    /// normal case, not the exception.
    public static let barTimeout: TimeInterval = 4

    /// Every input brings the bar back and resets the deadline.
    public func noteInteraction() {
        isBarVisible = true
        barShownAt = .now
    }

    /// Hides the bar when the deadline has passed.
    ///
    /// The deadline is checked on the tick and not counted by a task of its own: a second timer
    /// next to the tick keeps running while playback stands still, and the bar then disappears
    /// in the middle of pausing.
    func hideBarIfIdle(now: Date) {
        guard isBarVisible, Self.shouldHideBar(shownAt: barShownAt, now: now, status: status) else {
            return
        }
        // With the selection or the info area open, the focus has a target there. If the bar below
        // it disappears, it jumps into nothing, and tvOS puts it at an arbitrary place.
        guard !isChoosingTracks, !isInfoVisible else { return }

        // A seek in progress lapses with the bar. Without this line, ``scrubPosition`` would stay
        // set, and because the tick only takes over the engine's position when ``scrubPosition`` is
        // empty, the position would stand still from then on: the film keeps running, the bar
        // stands, the offer of the next episode never comes, and on the server the resume point
        // would stay at the position that was never taken over. The cleanup in ``TransportBar``
        // does not apply here — the bar has disappeared together with its observer.
        cancelScrub()
        isBarVisible = false
    }

    /// Hides the bar on request — the Back press (requirement 2026-09-04: close the bar with Back
    /// as well). If the player is paused, it keeps running meanwhile: a standing picture without
    /// a bar would look like a hang.
    public func hideBar() {
        cancelScrub()
        isBarVisible = false
        if !isPlaying, status != .failed {
            engine.controller.play()
        }
    }

    static func shouldHideBar(shownAt: Date, now: Date, status: PlaybackStatus) -> Bool {
        // Only with a running picture. A standing picture without any display looks like a crash,
        // and nobody knows whether the remote still does anything.
        guard status == .playing else { return false }
        return now.timeIntervalSince(shownAt) >= barTimeout
    }

    // MARK: - Scrubbing on the rail

    /// Width of one step when seeking — the first level.
    ///
    /// Deliberately coarse: on the remote a direction key is one step, and with five seconds it
    /// would take three hundred presses for half an hour.
    public static let scrubStep: TimeInterval = 30

    /// The levels at which a held press gets faster.
    ///
    /// **Why they exist** (viewer finding 2026-08-28: "when I have a film two to three hours long
    /// and want to fast-forward, I otherwise keep pressing forever"): with a fixed width of 30
    /// seconds, an hour costs 120 presses. On a TV one holds the direction pressed, and the
    /// remote repeats it — then it should also get faster, as in tvOS's built-in player.
    ///
    /// **A custom rebuild and no system feature.** tvOS accelerates only in
    /// `AVPlayerViewController`; whoever draws their own bar — and this one shows chapter
    /// notches, preview images and the jump offers — builds the behaviour themselves.
    ///
    /// **A ladder and not a formula.** A continuous acceleration cannot be controlled at three
    /// metres' distance: one cannot see how fast one currently is, and overshoots the target.
    /// Four fixed levels can be counted in one's head, and the jump between them is visible.
    ///
    ///     Presses  1– 4      30 s     the first two seconds stay fine
    ///     Presses  5– 8      60 s
    ///     Presses  9–12     120 s
    ///     from press 13     300 s     an hour in twelve presses
    ///
    /// Calculated for the remote's repeat rate of around two presses per second: after two
    /// seconds of holding it jumps by minutes, after six in five-minute steps.
    public static func scrubStep(at pressCount: Int) -> TimeInterval {
        switch pressCount {
        case ..<5: 30
        case ..<9: 60
        case ..<13: 120
        default: 300
        }
    }

    /// How long after a press the next still counts as "held".
    ///
    /// More generous than the remote's repeat rate (around 0.5 s), so that an irregularity does
    /// not break the chain — but short enough that two separate presses start again at thirty
    /// seconds.
    static let scrubChain: TimeInterval = 0.9

    /// Moves the targeted position by steps.
    ///
    /// Starts by itself at the running position if no seek is in progress. A separate "begin
    /// seeking" would have an order to keep, and the first key press would be lost whenever it
    /// is not kept.
    ///
    /// - Parameter now: Only for the test suite. An acceleration that cannot be recomputed is a
    ///   claim.
    public func moveScrub(by steps: Int, now: Date = Date()) {
        guard isSeekable, steps != 0 else { return }
        noteInteraction()

        let direction = steps > 0 ? 1 : -1
        if direction == scrubDirection, now.timeIntervalSince(lastScrub) <= Self.scrubChain {
            scrubPressCount += 1
        } else {
            scrubPressCount = 1
        }
        scrubDirection = direction
        lastScrub = now

        let current = scrubPosition ?? position
        scrubPosition = clamp(current + Double(steps) * Self.scrubStep(at: scrubPressCount))
    }

    /// Takes over the targeted position.
    public func commitScrub() {
        endScrubChain()
        guard let wanted = scrubPosition else { return }
        scrubPosition = nil
        seek(to: wanted)
    }

    public func cancelScrub() {
        endScrubChain()
        scrubPosition = nil
    }

    /// Break the chain — after every take-over and discard.
    ///
    /// Without it the next seek would begin where the last one left off: anyone who has just
    /// fast-forwarded an hour would, on the next tap, immediately be back at five-minute jumps.
    func endScrubChain() {
        scrubPressCount = 0
        scrubDirection = 0
        lastScrub = .distantPast
    }

    // MARK: - Display

    public var fraction: Double {
        if let window = timeShiftWindow { return window.portion(at: displayPosition) }
        guard duration > 0 else { return 0 }
        return min(1, max(0, displayPosition / duration))
    }

    /// The position that is displayed — while seeking, the targeted one.
    public var displayPosition: TimeInterval {
        scrubPosition ?? position
    }

    public var elapsedLabel: String {
        Self.timeLabel(displayPosition)
    }

    /// The remaining time as `−MM:SS`, or `nil` if the length is unknown.
    /// For a channel in the buffer: the lag behind the running programme (AP58 G1, A1).
    public var remainingLabel: String? {
        if let window = timeShiftWindow {
            return "−" + Self.timeLabel(window.lag(at: displayPosition))
        }
        return Self.remainingLabel(position: displayPosition, duration: duration)
    }

    /// Time value with equal-width digits in mind.
    ///
    /// Hours only if there are any: `1:42:07` for a film, `21:57` for an episode. A fixed hours
    /// digit would leave a zero in every episode that says nothing.
    public static func timeLabel(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }

    /// - Returns: `nil` if no length is known.
    ///
    /// For a channel and for recordings not yet scanned the server reports zero. Writing
    /// `−00:00` would be worse than nothing: it looks as if the item were over.
    public static func remainingLabel(position: TimeInterval, duration: TimeInterval) -> String? {
        guard duration > 0 else { return nil }
        return "−" + timeLabel(max(0, duration - position))
    }
}
