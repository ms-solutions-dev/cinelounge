import Core
import Foundation
import Testing

@testable import PlaylistKit

/// The test rig of the schedule: a whole programme guide through the
/// **real** stretch — parser, time window, detection, filter,
/// merge — with a counter at every station.
///
/// **Why this test rig has to exist at all.** Until 2026-08-29 there was only
/// ``SportProbeTests`` for the schedule, and it stayed silent without
/// `CINELOUNGE_EPG` (see the reasoning there). That left every number in the
/// sports area unproven: one could change a filter and not know whether
/// it had gained ten events or lost a hundred. This is exactly what
/// the finding of 2026-08-24 warns against — *a counter that can never go up is no
/// evidence.*
///
/// **Two guides** (``SportRecording``). The synthetic one (`Fixtures/sport/epg.xml`)
/// carries every case below on purpose: tournaments and stage races without
/// opponents, "Home / Away", three races of one weekend, the same tournament
/// written twice, a stream that began yesterday. The real one is a capture
/// of the tested provider, trimmed to sports channels, and runs where the
/// checkout has it.
///
/// **The cut of the real capture is NOT lossless — finding of the acceptance
/// review of 2026-08-29.** What was kept was what the recognizer hit **before**
/// E2; every sport added since can become visible only on channels that the cut
/// kept anyway. A rugby international on a general entertainment channel is a
/// real event the probe does not see. The probe thus measures the
/// filters, no longer the provider; whoever adds a new sport must counter-check
/// against the untrimmed file until the cut is redrawn.
///
/// **The fixed clock** sits in the recording and nowhere else. `Core` calculates
/// clock-free; whoever wants to know the day has to pass it in. Without the fixed
/// clock the same file measures something different tomorrow, and then a changed
/// number no longer says whether it was the change or the calendar.
@Suite("Schedule probe on the recorded guide")
struct SchedulePrototypeTests {

    /// **How the figures of the real recording came about** — one step per
    /// change since E2, each measured against the same capture — is written down
    /// next to that capture (`expected.json`), not here.
    ///
    /// **The five rows that E7 takes out are all rights packages** ("Fußball:
    /// DFB-Pokal", "Fußball: Frauen-Bundesliga" and the like). The bare hyphen had made
    /// pairings out of them, and §2 of the concept forbids exactly that. Not a single
    /// real event is lost in the process — recalculated in
    /// ``SportPlanTests/bareHyphenDoesNotSplitCompetitions()``.
    ///
    /// **The parser row.** Hundreds of rows used to drop out at the ID made of channel and
    /// start time, and not a single one of them carried the same title as the one
    /// kept: they were real entries that this provider puts simultaneously on the
    /// same channel. Since the ID carries the title, they come in — the synthetic
    /// guide carries such a minute on purpose (two Süper Lig matches and a show on
    /// one channel).
    @Test("The parser takes in the guide completely", arguments: SportRecording.all)
    func evaluatorReadsTheRecording(_ recording: SportRecording) {
        #expect(recording.broadcasts.count == recording.expected.read)
        #expect(recording.names.count == recording.expected.channels)
        #expect(recording.dayWindow.count == recording.expected.onDay)
    }

    @Test("The stages count: detected, passed through, merged", arguments: SportRecording.all)
    func stationsCount(_ recording: SportRecording) {
        let state = Self.state(recording)
        print(state.report)
        #expect(state.detected == recording.expected.detected)
        #expect(state.passedThrough == recording.expected.passedThrough)
        #expect(state.events.count == recording.expected.events)
    }

    /// A rebuild of what `SportModel.load()` does: read two days before the
    /// window as well, so that the first broadcast swallows its reruns —
    /// then cut back to the day.
    ///
    /// **The finding that E2 fixes** (2026-08-29): with the timeless
    /// first-wins rule, a good part of the rows without look-back was gone with
    /// look-back. Today's matches vanished behind a
    /// broadcast of yesterday, among them the evening games of the Turkish
    /// channels. Now the look-back costs nothing any more — it gains a row
    /// on both guides: on the real one because a morning canned recording lets its
    /// evening broadcast through, on the synthetic one because a stream that began
    /// yesterday evening is still running at 15:00. The synthetic guide also shows
    /// yesterday's evening airing of a Süper Lig pairing 22 hours before today's
    /// match — today's row survives it.
    @Test("The lookback no longer costs any of today's events", arguments: SportRecording.all)
    func lookbackCostsNothing(_ recording: SportRecording) {
        let now = recording.at(hour: 15)
        func rows(lookbackHours: Double) -> Int {
            let from = recording.dayStart.addingTimeInterval(-lookbackHours * 3600)
            let window = recording.broadcasts.filter {
                $0.start >= from && $0.start < recording.dayEnd
            }
            return SportPlan.events(from: window, channelNames: recording.names)
                .filter {
                    $0.end > now && $0.start < recording.dayEnd
                        && ($0.start >= recording.dayStart || $0.isRunning(at: now))
                }
                .count
        }
        #expect(rows(lookbackHours: 0) == recording.expected.rowsWithoutLookback)
        #expect(rows(lookbackHours: 48) == recording.expected.rowsWithLookback)
        #expect(rows(lookbackHours: 48) >= rows(lookbackHours: 0))
    }

    /// The missing ones from the concept — tournament and stage formats without
    /// opponents, which the event evidence did not know until 2026-08-29 — and
    /// the French market's "Home / Away", which without the slash as a separator
    /// never appeared in the schedule. And what must stay outside: a break, all
    /// goals, a "World Cup" of no sport, a highlight show, the pre-match studio, the
    /// pitchside report.
    @Test("The acceptance from the concept: this is there, that is not", arguments: SportRecording.all)
    func acceptanceList(_ recording: SportRecording) {
        let title = Self.state(recording).events.map { "\($0.competition ?? "") \($0.title)" }
        func settled(_ part: String) -> Bool {
            title.contains { SportKind.normalized($0).contains(SportKind.normalized(part)) }
        }
        for part in recording.expected.settled {
            #expect(settled(part), "\(part)")
        }
        for part in recording.expected.notSettled {
            #expect(!settled(part), "\(part)")
        }
    }

    /// **Why this check was recut (acceptance review 2026-08-29).** It
    /// keyed on `kind#title#start` — and thereby could not find a
    /// single one of the duplications that really are in the list:
    /// two rows of the same event always have different
    /// start times, because equal ones would already have been merged in the merge window.
    /// The counter could not go up.
    ///
    /// It is therefore keyed on sport and title **without** time and
    /// without competition. What then appears several times is named:
    ///
    /// - **Justified:** three classes, three races on the same weekend. Exactly for
    ///   this the key has carried the competition since E2.
    /// - **Finding, not fixed:** one tournament twice, because one channel writes
    ///   "Tennis: … Open" and another only "… Open" — the competition in the key
    ///   separates what used to coincide, the flip side of the change that separates
    ///   Moto2 from MotoGP.
    /// - **Finding, not fixed:** the same tournament round twice, a good 21 hours
    ///   apart — just beyond ``SportPlan/rerunWindow``. Widening the window would mean
    ///   losing again the evening games it was introduced for.
    ///
    /// The last two are rows that, according to the concept, the viewer should not
    /// see. They are here so that they do not grow without anyone noticing.
    @Test(
        "Duplicate rows: three races are three, two tournaments are one finding",
        arguments: SportRecording.all)
    func duplicateRows(_ recording: SportRecording) {
        let groups = Dictionary(grouping: Self.state(recording).events) { event in
            "\(event.kind.rawValue)#"
                + SportKind.normalized(event.title).filter { $0.isLetter || $0.isNumber }
        }.filter { $0.value.count > 1 }
        #expect(groups.mapValues(\.count) == recording.expected.duplicateGroups)
    }

    /// **What the 24-hour window carries** (user decision 2026-09-02),
    /// fixed clock 15:00 on the day of the guide.
    ///
    /// Here stood the measurement of the day tabs: the running exception hung on
    /// every single one, and thus "Tomorrow" and "Day after tomorrow" carried everything that
    /// was running at that moment. Both tabs no longer exist, and with them the
    /// exception is no longer a rule but a consequence: a window that begins at
    /// `now` lets a running match in because its end lies in the future.
    ///
    /// | Cut                         | synthetic |
    /// |-----------------------------|----------:|
    /// | "Today" tab (to midnight)   |        18 |
    /// | 24 h window (to 15:00)      |        20 |
    ///
    /// **Both figures from the same event list** — only the cut differs. The
    /// additional rows are the gain: they kick off between midnight and
    /// tomorrow 15:00, so they are nearer than half of today's — and were hidden
    /// behind a tab.
    @Test("The 24-hour window carries more than the Today tab", arguments: SportRecording.all)
    func twentyFourHours(_ recording: SportRecording) {
        let now = recording.at(hour: 15)
        let span = SportWindow.span(now: now)
        let read = recording.broadcasts.filter {
            $0.start >= span.readAlongFrom && $0.start < span.readUntil
        }
        let events = SportPlan.events(from: read, channelNames: recording.names)

        // The old cut: midnight to midnight, with the exception for
        // what is running — rebuilt so that the difference stays measurable.
        let tabToday = events.filter { $0.end > now && $0.start < recording.dayEnd }

        #expect(tabToday.count == recording.expected.tabToday)
        #expect(SportWindow.list(events, span: span, now: now).count == recording.expected.window24)
        #expect(recording.expected.window24 > recording.expected.tabToday)
    }

    /// **The reach of the guide does not quite cover the window.** It ends on the
    /// next morning at 09:18 — about +24 h from the fetch time, exactly as the
    /// concept measures it. The window reaches to 15:00; the last six hours of it
    /// this guide cannot fill.
    ///
    /// That is no complaint but the reason for the preview of exactly 24 hours: a
    /// window that reaches further than any guide promises something the download
    /// store cannot keep.
    @Test("The reach of the guide ends in the window", arguments: SportRecording.all)
    func reachInWindow(_ recording: SportRecording) {
        let now = recording.at(hour: 15)
        let reach = recording.broadcasts.map(\.start).max()
        let parts = recording.expected.reach

        #expect(
            reach
                == recording.calendar.date(
                    from: DateComponents(
                        timeZone: recording.timeZone, year: parts[0], month: parts[1],
                        day: parts[2], hour: parts[3], minute: parts[4])))
        #expect(reach! < SportWindow.span(now: now).end)
    }

    // MARK: - Der Messvorgang

    /// What stands at each station — the one calculation that all the tests and
    /// `scripts/schedule-probe.sh` share.
    struct State {
        var recording: SportRecording
        var detected = 0
        var passedThrough = 0
        var perSportKind: [SportKind: Int] = [:]
        var events: [SportEvent] = []

        var report: String {
            var rows = [
                "Probe \(recording.name) (fixed clock, Europe/Berlin)",
                "  \(recording.broadcasts.count) broadcasts read",
                "  \(recording.dayWindow.count) in the day window",
                "  \(detected) with detected sport",
                "  \(passedThrough) through the event proof",
                "  \(events.count) events after the merge",
            ]
            for (kind, count) in perSportKind.sorted(by: { $0.value > $1.value }) {
                rows.append("    \(kind.rawValue): \(count)")
            }
            return rows.joined(separator: "\n")
        }
    }

    static func state(_ recording: SportRecording) -> State {
        var state = State(recording: recording)
        let window = recording.dayWindow
        for broadcast in window {
            let channel = (recording.names[broadcast.channelID] ?? "") + " " + broadcast.channelID
            guard SportKind.classify(title: broadcast.title, channelName: channel) != nil else {
                continue
            }
            state.detected += 1
            if SportPlan.isLiveEvent(broadcast.title) { state.passedThrough += 1 }
        }
        state.events = SportPlan.events(from: window, channelNames: recording.names)
        for event in state.events { state.perSportKind[event.kind, default: 0] += 1 }
        return state
    }
}
