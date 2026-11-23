import Core
import Diagnose
import Foundation
import Observation

/// What is to be decided during playback **without an engine** — in one place for both
/// devices (AP58 R4, report A finding S1).
///
/// **Why it exists.** The TV connected the building blocks from `Core` in `PlayerModel`
/// (``Core/PlaybackReporter``, ``Core/NextUpPrompt``, ``Core/MediaSegment``,
/// ``Core/StallInterpretation``) with its beat; the phone rebuilt the report to the
/// server (without a total, before the first picture, without sign-off at `.ended`), knew
/// neither counter nor skipping, and watched for a stall at different gates. Here
/// the connection exists once: the platform holds engine and view and feeds in, every beat,
/// state and position; out come reports, the offer of the next episode, the
/// skip offer and the stall including its finding.
///
/// **Only what rarely changes is observed.** The beat runs two to one times per
/// second; what changes every time (clock, counter, last position) lies outside
/// the observation, otherwise every view over it would re-evaluate the whole tree (AP7 · L7).
@Observable
public final class PlaybackCore {

    /// How long a beat of the platform is — on the TV half a second, on the phone one.
    public let step: TimeInterval

    /// Whether the watch already counts **before the first picture**.
    ///
    /// **A deliberate platform decision** (R4): the TV has no display of its own for the
    /// startup; there the board after twelve seconds is the information, and the
    /// raw-stream fallback of a channel that never brings a picture hangs on it. The phone shows the
    /// startup itself (``PlaybackPhase/loadingLong``); a board above it would say the same twice.
    public let watchesDuringStartup: Bool

    public init(step: TimeInterval, watchesDuringStartup: Bool) {
        self.step = step
        self.watchesDuringStartup = watchesDuringStartup
    }

    // MARK: - Target

    /// Whether the running target is a recording — only it has sections and episodes.
    public private(set) var isRecording = false

    /// `nil` if no progress is reported for this target (channel, trailer).
    @ObservationIgnored private var reporter: PlaybackReporter?

    /// A new target takes over the core.
    ///
    /// **The counter of the reports starts anew as soon as the old one can no longer say anything** — with
    /// a different title, or if it has already signed off on the same title (after `.failed`,
    /// before a source change). **On the same title with an open session it stays** (player
    /// audit, finding S10): a jump through the server rebuilds the engine, but the session
    /// at the server is the same — a new counter registered it a second time without
    /// signing off the first. And conversely (finding S5): after a failure the old
    /// counter had signed off; without a new one, "Try again" on the TV never reported
    /// progress again.
    ///
    /// **What hangs on the title** (sections, things swiped away, the offer) goes only with a
    /// different title: after a jump through the server there was otherwise no intro button for the rest of the movie
    /// (roadmap AP4).
    public func newTarget(reportsProgress: Bool, isRecording: Bool, sameTitle: Bool) {
        if !Self.keepsReporter(reporter, reportsProgress: reportsProgress, sameTitle: sameTitle) {
            reporter = reportsProgress ? PlaybackReporter() : nil
        }
        if self.isRecording != isRecording { self.isRecording = isRecording }
        guard !sameTitle else { return }
        if !segments.isEmpty { segments = [] }
        if !swipedAway.isEmpty { swipedAway = [] }
        if autoSkipped != nil { autoSkipped = nil }
        nextAvailable = false
        nextSimilar = false
        if nextDismissed { nextDismissed = false }
        setOffer(nil)
        countdown = NextUpPrompt.Countdown()
    }

    /// Whether the running counter stays — see ``newTarget(reportsProgress:isRecording:sameTitle:)``.
    static func keepsReporter(
        _ counter: PlaybackReporter?, reportsProgress: Bool, sameTitle: Bool
    ) -> Bool {
        guard sameTitle, reportsProgress, let counter else { return false }
        return !counter.isSignedOff
    }

    /// The sign-off on leaving or before a title change — with the **last known**
    /// position; some engines report zero after stopping.
    public func finish(at location: TimeInterval) -> PlaybackReporter.Report? {
        reporter?.consider(position: location, status: .ended)
    }

    // MARK: - Skipping

    /// The sections of the title (intro, recap, credits).
    public private(set) var segments: [MediaSegment] = []

    /// Sections that have already been skipped or dismissed. Without this memory
    /// the button appears again after the jump if it lands shortly before the end.
    public private(set) var swipedAway: Set<String> = []

    public func setSegments(_ incoming: [MediaSegment]) {
        if segments != incoming { segments = incoming }
    }

    /// The section for which a button is shown at this position — **only in the window of the
    /// section**, otherwise every movie without an intro would show a pointless button on screen.
    public func skipOffer(at location: TimeInterval) -> MediaSegment? {
        guard isRecording, let section = segments.skippable(at: location),
            !swipedAway.contains(section.id)
        else { return nil }
        return section
    }

    /// Accepts the offer: remembers the section and names the jump target.
    public func skip(at location: TimeInterval) -> TimeInterval? {
        guard let section = skipOffer(at: location) else { return nil }
        swipedAway.insert(section.id)
        return section.end
    }

    // MARK: - Skipping by itself (AP85 binge package, 2026-11-09)

    /// Which sections are skipped without a press — from the profile
    /// (``Core/BingePreferences/autoSkipKinds``), set by the player on every new title.
    public var autoSkipKinds: Set<MediaSegment.Kind> = []

    /// The last section skipped by itself, and when — for the hint "Intro skipped · Back".
    public private(set) var autoSkipped: (segment: MediaSegment, at: Date)?

    /// How long the hint with "Back" stays.
    public static let autoSkipHintDuration: TimeInterval = 6

    /// How far into a section the jump still happens. **Only at its beginning:** whoever
    /// winds back into the intro on purpose, or resumes in the middle of it, wants to see it.
    static let autoSkipLead: TimeInterval = 3

    /// Skips the section at this position by itself — or `nil`.
    ///
    /// Only at the beginning of a section (``autoSkipLead``), only once per section (the same
    /// memory as the button), only kinds from ``autoSkipKinds``.
    public func autoSkip(at location: TimeInterval, now: Date = .now) -> TimeInterval? {
        guard !autoSkipKinds.isEmpty, isRecording,
            let section = segments.skippable(at: location),
            autoSkipKinds.contains(section.kind),
            !swipedAway.contains(section.id),
            location - section.start < Self.autoSkipLead
        else { return nil }
        swipedAway.insert(section.id)
        autoSkipped = (section, now)
        return section.end
    }

    /// The section of the hint, while it is shown.
    public func autoSkipHint(now: Date = .now) -> MediaSegment? {
        guard let autoSkipped, now.timeIntervalSince(autoSkipped.at) < Self.autoSkipHintDuration
        else { return nil }
        return autoSkipped.segment
    }

    /// "Back": the start of the section skipped last. It stays done — the intro then runs
    /// and is not skipped again.
    public func undoAutoSkip() -> TimeInterval? {
        guard let section = autoSkipped?.segment else { return nil }
        autoSkipped = nil
        return section.start
    }

    // MARK: - Sleep timer (AP85 binge package, 2026-11-09)

    /// What the sleep timer is set to.
    public enum SleepChoice: Sendable, Hashable {
        case off
        /// At the end of this episode — before the next one would start.
        case endOfEpisode
        case minutes(Int)
    }

    /// The choices offered, in this order.
    public static let sleepChoices: [SleepChoice] = [.off, .endOfEpisode, .minutes(30), .minutes(60)]

    public private(set) var sleepChoice: SleepChoice = .off
    /// When the minutes run out. **Survives the title change**: thirty minutes are thirty
    /// minutes, however many episodes fit in.
    @ObservationIgnored private var sleepDeadline: Date?

    public func setSleep(_ choice: SleepChoice, now: Date = .now) {
        sleepChoice = choice
        if case .minutes(let minutes) = choice {
            sleepDeadline = now.addingTimeInterval(TimeInterval(minutes * 60))
        } else {
            sleepDeadline = nil
        }
    }

    /// Minutes left, rounded up — for the label; `nil` without a running clock.
    public func sleepMinutesLeft(now: Date = .now) -> Int? {
        guard let sleepDeadline else { return nil }
        return max(0, Int((sleepDeadline.timeIntervalSince(now) / 60).rounded(.up)))
    }

    /// Whether the timer has run out at this beat. "After this episode" is due where the
    /// episode would hand over: at its end, or when the counter of the offer runs out.
    func sleepIsDue(now: Date, ended: Bool) -> Bool {
        switch sleepChoice {
        case .off: return false
        case .endOfEpisode: return ended || (nextOffer?.shouldAdvance == true && !nextSimilar)
        case .minutes: return sleepDeadline.map { now >= $0 } ?? false
        }
    }

    // MARK: - Still watching? (AP85 binge package, 2026-11-09)

    /// After how many episodes switched **by themselves** in a row the player asks — from the
    /// profile (``Core/BingePreferences/stillWatchingAfter``); `0` never.
    public var stillWatchingAfter = 0

    /// Episodes switched by the counter since the last press. **Survives the title change** —
    /// that is the whole point; only a press resets it.
    public private(set) var unattendedEpisodes = 0

    /// The player stands paused and asks "Still watching?". Someone who fell asleep should
    /// not wake up four episodes later — and the server should not mark them as watched.
    public private(set) var asksStillWatching = false

    /// A press of the viewer — any. Called from the views, **not** from the model's own
    /// paths: a stall or a title change also show the bar, and they are no proof of anyone.
    public func noteViewerPresent() {
        if unattendedEpisodes != 0 { unattendedEpisodes = 0 }
    }

    /// The counter has switched to the next episode by itself.
    public func noteAutoAdvance() {
        unattendedEpisodes += 1
        if stillWatchingAfter > 0, unattendedEpisodes >= stillWatchingAfter {
            asksStillWatching = true
        }
    }

    /// "Keep watching": the question goes, counting starts anew.
    public func confirmStillWatching() {
        asksStillWatching = false
        unattendedEpisodes = 0
    }

    // MARK: - Next episode

    /// The running offer of the next episode — seconds until the switch.
    public private(set) var nextOffer: NextUpPrompt.State?

    /// Whether the offer for this title has been dismissed.
    ///
    /// It has to exist: whoever wants to watch the credits — in anime the song is there —
    /// must not be dragged along.
    public private(set) var nextDismissed = false

    @ObservationIgnored private var nextAvailable = false
    /// Whether the offer is a **similar movie**. It is offered, but never starts by
    /// itself (F-026, 2026-09-05): an episode has a successor, a movie a suggestion.
    @ObservationIgnored private var nextSimilar = false

    /// Carries its reference point itself, so that a jump does not skip it.
    @ObservationIgnored private var countdown = NextUpPrompt.Countdown()

    /// Whether there is anything to offer — as soon as the source has answered. **The calculation uses
    /// the position the platform names**: after a title change the last
    /// position seen is that of the previous episode, and the offer would be back immediately.
    public func setNext(
        available: Bool, similar: Bool = false, location: TimeInterval, duration: TimeInterval
    ) {
        nextAvailable = available
        nextSimilar = similar
        updateNext(location: location, duration: duration)
    }

    /// Dismisses the offer for this title.
    public func dismissNext() {
        if !nextDismissed { nextDismissed = true }
        setOffer(nil)
    }

    /// Recalculates the offer at a position.
    ///
    /// **Via the counter and not via the rule without memory**: otherwise a
    /// jump of +30 shortly before the trigger point would immediately yield null, and the next episode would begin
    /// with no chance to cancel.
    public func updateNext(location: TimeInterval, duration: TimeInterval) {
        guard isRecording, !nextDismissed else {
            setOffer(nil)
            return
        }
        setOffer(
            countdown.update(
                at: location, duration: duration, outro: segments.outro, hasNext: nextAvailable))
    }

    private func setOffer(_ fresh: NextUpPrompt.State?) {
        if nextOffer != fresh { nextOffer = fresh }
    }

    /// What happens to playback after a beat.
    public enum NextStep: Sendable, Equatable {
        case none
        /// Take over the next episode.
        case next
        /// The title has ended, and nothing follows it.
        case close
        /// The sleep timer has run out — stop, do not switch (AP85).
        case sleep
    }

    /// Report and next step of a beat.
    public struct Episode: Sendable, Equatable {
        public let report: PlaybackReporter.Report?
        public let step: NextStep
    }

    /// A beat of playback: offer, report, and whether it continues.
    ///
    /// **At the end the counter is not waited for.** It counts at the position in the movie, and
    /// after `.ended` that no longer advances; some files demonstrably end a few
    /// seconds before the reported runtime. **A similar movie never starts by itself.**
    public func episode(
        status: PlaybackStatus, location: TimeInterval, duration: TimeInterval, now: Date = .now
    ) -> Episode {
        updateNext(location: location, duration: duration)
        let report = reporter?.consider(position: location, status: status)
        let step: NextStep
        if sleepIsDue(now: now, ended: status == .ended) {
            // **The sleep timer goes before everything** (AP85): whoever set it wants quiet,
            // not the next episode and not a question.
            sleepChoice = .off
            sleepDeadline = nil
            // And this title hands over to nothing any more — otherwise the next beat would
            // find the counter at zero and switch after all.
            dismissNext()
            step = .sleep
        } else if asksStillWatching {
            // **Nothing switches while the player asks** (AP85) — not the counter, not the end.
            step = .none
        } else if status == .ended {
            step =
                !nextDismissed && nextAvailable && !nextSimilar
                ? .next : .close
        } else if nextOffer?.shouldAdvance == true, !nextSimilar {
            step = .next
        } else {
            step = .none
        }
        return Episode(report: report, step: step)
    }

    // MARK: - Reports to the server

    /// How a report gets to the server — **one source per platform, the same mapping.**
    nonisolated public struct ProgressRoute: Sendable {
        public let begin: @Sendable () async throws -> Void
        public let notify: @Sendable (_ state: PlaybackProgress, _ isPaused: Bool) async throws -> Void
        public let finish: @Sendable (_ location: TimeInterval) async throws -> Void

        public init(
            begin: @escaping @Sendable () async throws -> Void,
            notify:
                @escaping @Sendable (_ state: PlaybackProgress, _ isPaused: Bool) async throws
                -> Void,
            finish: @escaping @Sendable (_ location: TimeInterval) async throws -> Void
        ) {
            self.begin = begin
            self.notify = notify
            self.finish = finish
        }
    }

    /// Sends a report out.
    ///
    /// **The start carries the state right away:** the registration passes no position through, and
    /// when resuming the server would show the start until the first progress report.
    /// **A failure costs the resume point, not the movie** — the server demonstrably answers
    /// progress reports with an error even when the state
    /// has arrived; hence only one step in the log.
    public static func send(
        _ report: PlaybackReporter.Report, duration: TimeInterval, about route: ProgressRoute
    ) async {
        let state = PlaybackProgress(
            position: report.position, duration: duration,
            isWatched: PlaybackReporter.isWatched(position: report.position, duration: duration))
        do {
            switch report.kind {
            case .start:
                try await route.begin()
                try await route.notify(state, false)
            case .stop:
                try await route.finish(report.position)
            case .progress, .pause, .resume:
                try await route.notify(state, report.kind == .pause)
            }
        } catch {
            Diagnose.step(
                .playback,
                "Progress report \(report.kind.rawValue) failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Stall (stall concept, decisions 11–13)

    /// Whether the picture is frozen although it should be running — **the same twelve seconds on both
    /// devices** (``Core/StallInterpretation/window``), counted in beats times ``step``.
    public private(set) var settled = false

    /// What is behind the stall — `nil` without a remuxer pulse. **Set on the flip**
    /// and not continuously, so that the sentence does not jump before one's eyes; the one exception is
    /// case A, which matures over bytes and becomes more precise in the process, nothing else.
    public private(set) var stallFinding: StallInterpretation.Finding?

    /// The lines that went into the error trace for this target — **the tap of the
    /// check.** The trace itself is process-wide and cannot be attributed in concurrent checks;
    /// this list is created at exactly the point where the line goes out.
    public private(set) var stallLines: [String] = []

    /// How many beats the position has been standing while it should be running.
    @ObservationIgnored public private(set) var silentTicks = 0

    /// How many beats count as a stall — the interpretation window in beats.
    public var silenceLimit: Int { Int((StallInterpretation.window / step).rounded(.up)) }

    /// Whether a picture has played since the last startup.
    @ObservationIgnored public private(set) var hasPlayed = false

    @ObservationIgnored private var interpretation = StallInterpretation()
    /// For which target the interpretation counts — its lock ("once per finding") applies per target.
    @ObservationIgnored private var interpretationTarget: String?
    /// Which remuxer was counted last — a new one starts at zero.
    @ObservationIgnored private var mutate: ObjectIdentifier?
    /// The clock of the interpretation: beats times ``step``. **Counted, not read** — a
    /// calculation on the wall clock could only be checked by waiting.
    @ObservationIgnored private var clock: TimeInterval = 0
    @ObservationIgnored private var seen: TimeInterval = -1

    // MARK: - Dried-up supply (on-device finding 30.09.2026, F-047)

    /// How often a title is requested anew after the supply dries up, before the board
    /// stays up.
    ///
    /// **The case:** "Laitkrutbai Gezougros", episode 1 through the IPTV provider, stood at 21:27 —
    /// `Player at 1287.5 s, loaded to 1287.6 s`, after that not another byte came, and the app
    /// watched until the viewer gave up. No error, no end: the provider's line
    /// was silent, and the system engine does not re-request a silent line. A fresh
    /// fetch from the same position gets a new address along with a new connection.
    ///
    /// **Three and not arbitrarily often:** the provider has an account with one connection and
    /// throttles connection storms for minutes — the program queries too. If the
    /// title does not deliver after three fresh fetches, it is not the line.
    public static let resupplyLimit = 3

    /// How little lead is called "dried up". If the picture is frozen with more loaded ahead of it,
    /// it is the engine that jams and not the line — a new fetch would not help there.
    public static let resupplyLeadTime: TimeInterval = 2

    /// How far playback has to run after a fresh start until the attempts are full again.
    /// A stall after ten minutes is a new case, not a fourth attempt at the old one.
    public static let resupplyRecovery: TimeInterval = 120

    @ObservationIgnored public private(set) var resupplyAttempts = 0
    @ObservationIgnored private var resupplyPosition: TimeInterval?
    @ObservationIgnored private var resupplyTitle: String?

    /// Whether a stall that **has just flipped** is a dried-up supply that a new
    /// fetch from `location` heals — and counts the attempt if so.
    ///
    /// Never for live: there the own remuxer has its interpretation and its fallbacks.
    ///
    /// - Parameter titel: **The identifier of the title, not the address** — a new fetch
    ///   gets a new session in the address with the media server, and a counter per
    ///   address would start over with every attempt.
    public func restartAfterSupplyRanDry(
        title: String, location: TimeInterval, loadedUntil: TimeInterval?, live: Bool
    ) -> Bool {
        if title != resupplyTitle {
            resupplyTitle = title
            resupplyAttempts = 0
            resupplyPosition = nil
        }
        guard !live, settled, let loadedUntil, loadedUntil - location < Self.resupplyLeadTime,
            resupplyAttempts < Self.resupplyLimit
        else { return false }
        resupplyAttempts += 1
        resupplyPosition = location
        return true
    }

    /// A new startup — **every engine start, also on the same title.**
    ///
    /// The interpretation starts anew only for a different target (its lock applies per target). The
    /// **handle always drops**, though (finding H1): it is an address, and a new remuxer
    /// can get the same one. **The balance first**, otherwise the stretch of the old run
    /// is already replaced.
    public func newStartup(target: String) {
        settleAccount()
        hasPlayed = false
        silentTicks = 0
        seen = -1
        mutate = nil
        if settled { settled = false }
        if stallFinding != nil { stallFinding = nil }
        if interpretationTarget != target {
            interpretationTarget = target
            interpretation = StallInterpretation()
            if !stallLines.isEmpty { stallLines = [] }
        }
    }

    /// The remuxer is torn down — **and with it the run of the interpretation** (finding H1).
    public func remuxerTornDown() {
        settleAccount()
        interpretation.newRun()
        mutate = nil
    }

    /// Watches over the stall for one beat.
    ///
    /// - Parameter puls: the counters of the remuxer, where there is one to be interpreted
    ///   — otherwise `nil`, and the board stands without a finding.
    /// - Returns: whether the board flips in this beat.
    ///
    /// **The interpretation is fed only while it should be running** (finding H3): after `.failed`
    /// and `.ended` bytes kept coming, and case A matured over a playback nobody
    /// expects any more. **The pause goes in** — the interpretation clears its history on it;
    /// a pause before the stall is not a stretch without a piece.
    @discardableResult
    public func observeStall(
        status: PlaybackStatus, location: TimeInterval, loadedUntil: TimeInterval?,
        pulse: (any RepackerPulse)?
    ) -> Bool {
        clock += step
        if status == .playing { hasPlayed = true }
        let expectedValue = [PlaybackStatus.playing, .buffering, .opening].contains(status)
        if let pulse, expectedValue || status == .paused {
            feed(status: status, location: location, loadedUntil: loadedUntil, pulse: pulse)
        }
        defer { if !settled, stallFinding != nil { stallFinding = nil } }

        if let since = resupplyPosition, location - since >= Self.resupplyRecovery {
            resupplyAttempts = 0
            resupplyPosition = nil
        }
        let isWatching = expectedValue && (watchesDuringStartup || hasPlayed)
        guard isWatching, location == seen else {
            seen = location
            silentTicks = 0
            if settled { settled = false }
            return false
        }
        silentTicks += 1
        guard silentTicks >= silenceLimit, !settled else { return false }
        settled = true
        interpret(pulse: pulse)
        return true
    }

    private func feed(
        status: PlaybackStatus, location: TimeInterval, loadedUntil: TimeInterval?,
        pulse: any RepackerPulse
    ) {
        let new = ObjectIdentifier(pulse)
        if mutate != new {
            mutate = new
            interpretation.newRun()
        }
        let probe = StallInterpretation.Sample(
            time: clock, status: status, position: location, loadedUntil: loadedUntil,
            hasPlayed: hasPlayed, pulse: pulse.pulseState)
        if interpretation.take(probe) == .cutterStalled {
            notify(.cutterStalled)
            if settled, stallFinding != .cutterStalled { stallFinding = .cutterStalled }
        }
    }

    /// **Interpretation, not action.** Case A does not restart anything either — the line says
    /// "would restart", and whether that would be right only the device shows (stage 3).
    private func interpret(pulse: (any RepackerPulse)?) {
        guard pulse != nil, hasPlayed else {
            stallFinding = nil
            return
        }
        let finding = interpretation.interpret()
        stallFinding = finding
        notify(finding)
    }

    /// The line of a finding — **once per finding and target**, as an error: on the phone into the
    /// error log, on the TV into the error trace (``Diagnose/LogRoute``).
    private func notify(_ finding: StallInterpretation.Finding) {
        guard let row = interpretation.report(forItem: finding) else { return }
        stallLines.append(row)
        Diagnose.error(.playback, row)
    }

    /// The longest stretch without a piece — **the measure for stage 3** (concept §8.1), precisely
    /// from the healthy runs that never show a board.
    private func settleAccount() {
        guard mutate != nil else { return }
        let stretch = interpretation.longestStretchWithoutChunk
        guard stretch > 0 else { return }
        Diagnose.step(
            .playback,
            "Remuxer: longest stretch without a piece ≈ \(String(format: "%.1f", stretch)) s of broadcast "
                + "(deadline for case A: \(Int(StallInterpretation.deadline)) s)")
    }
}
