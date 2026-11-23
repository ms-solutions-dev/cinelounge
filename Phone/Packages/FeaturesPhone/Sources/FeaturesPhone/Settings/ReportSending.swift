import Core
import Diagnose
import Foundation
import JellyfinKit

/// Put the report where it can be looked up — **on the media server.**
///
/// **The requirement came up** (2026-09-06): on tvOS the diagnostics file itself is stored as part of
/// the diagnostics, and it can always be checked there — the phone should work the same way.
///
/// **Exactly that, and by the same path.** The TV program sends its report to
/// `ClientLog/Document`; Jellyfin stores it as `upload_CineLounge_<version>_<stamp>.log`
/// in its log directory. The TV's reports have been lying there for weeks — they
/// can be read without anybody typing or forwarding anything.
///
/// **On the phone this path did not exist.** The screen had a "Send
/// report" button that flipped a switch that **no view read** — it did nothing. And
/// the short path it was meant for (the file into the share sheet) was never
/// connected. Both exist now.
///
/// **The server is the better of the two, and that is why it is the loud button.** A
/// report in the share sheet needs somebody to send it somewhere; one on the
/// server lies where people look anyway — and it carries in its header which device
/// it comes from, so the reports of both programs can lie side by side.
///
/// **It depends on the media server and says so when there is none.** Whoever has only set up channel lists
/// has nobody to give the report to — then the share sheet remains, and the button states the reason instead of
/// standing there grayed out.
@MainActor
public enum ReportSending {

    /// What came out of sending.
    public enum Outcome: Sendable, Equatable {
        /// Angekommen, unter diesem Namen.
        case stored(String)
        /// No media server set up — there is nobody to give it to.
        case noServer
        /// The server did not accept it.
        case rejected(String)
    }

    /// Builds the report and stores it on the media server.
    ///
    /// **Built here and not outside.** The report is a snapshot; whoever
    /// builds it outside and passes it in sends the one from earlier on the second press.
    public static func send(identifier: String) async -> Outcome {
        guard let source = SourceAssembly.jellyfin() as? JellyfinSource else {
            return .noServer
        }
        do {
            let name = try await source.uploadLog(await text(identifier: identifier))
            Diagnose.step(.surface, "Report stored: \(name)")
            return .stored(name)
        } catch {
            // **The failure goes into the ledger, and into the same one.** Whoever manages to send the report on the
            // next attempt finds in it why it did not work at first.
            Diagnose.hint(.network, "Report not stored", error)
            return .rejected(error.localizedDescription)
        }
    }

    /// The same report as a file — **for the path without a media server.**
    public static func file(identifier: String) async throws -> URL {
        let report = Report(
            identifier: identifier, device: DeviceDetails.thisDevice(),
            entries: await ErrorLog.shared.entries())
        let location = try ReportOutput.file(forItem: report)
        try await text(identifier: identifier).write(to: location, atomically: true, encoding: .utf8)
        return location
    }

    // MARK: - What the report contains

    /// **Two ledgers, and until 2026-09-06 the report read only one.**
    ///
    /// That is the finding behind the requirement — *on tvOS the diagnostics are kept
    /// automatically, and I only submit them*: it is built exactly that way, and it has long run on the phone too. `Core` and `Playback` report at
    /// **ninety-one** places what they do; the engine reports its audio errors by
    /// itself, the repackager session its downloads and its reconnections. All of this
    /// lands in `Core.TraceRecorder` — in **two files**, an always-running
    /// error trace and a recording that depends on the switch.
    ///
    /// **The phone's report read none of it.** It carried only `ErrorLog`, the
    /// ledger of this project — that is, only what the phone views write into it themselves.
    /// The engine's measurements that explain the audio stood in the other file and
    /// were never submitted.
    ///
    /// **Both belong in, and in this order** — the same as over there: first
    /// the errors, because they are always there and mostly carry the answer; then the
    /// detailed recording; last the own ledger.
    ///
    /// **Trimmed at the front.** Jellyfin accepts client logs only up to about one megabyte,
    /// and two full traces exceed that — over there the rejection read on 2026-08-16
    /// like a switched-off server. The newest is what submitting is about.
    public static func text(identifier: String) async -> String {
        var rows = [DiagnosticID.headerLine(identifier), ""]
        rows += Diagnostics.reportHeader()
        rows.append("")

        let error = trimmed(await TraceRecorder.errors.contents(), atMost: 200_000)
        rows.append("═══ Errors (always recorded) ═══")
        rows.append(error.isEmpty ? "No errors in the last three days." : error)
        rows.append("")

        let recorded = trimmed(await TraceRecorder.shared.contents(), atMost: 500_000)
        rows.append("═══ Recording (only with verbose recording) ═══")
        rows.append(recorded.isEmpty ? "Recording is off." : recorded)
        rows.append("")

        // **The own ledger last and not first.** It carries the steps of the
        // interface; the cause of an outage is almost always in the trace above.
        let report = Report(
            identifier: identifier, device: DeviceDetails.thisDevice(),
            entries: await ErrorLog.shared.entries())
        rows.append("═══ Interface ═══")
        rows.append(report.text)

        return rows.joined(separator: "\n")
    }

    /// **Trimmed at the front, not at the back.** The newest is what submitting is about.
    ///
    /// `nonisolated`, because it is a computation over a text and touches no state
    /// — a check should be able to call it without the main actor.
    nonisolated static func trimmed(_ text: String, atMost: Int) -> String {
        guard text.utf8.count > atMost else { return text }
        var kept: [Substring] = []
        var sum = 0
        for row in text.split(separator: "\n", omittingEmptySubsequences: false).reversed() {
            let cost = row.utf8.count + 1
            if sum + cost > atMost { break }
            kept.append(row)
            sum += cost
        }
        return "… (truncated at the front, older entries missing)\n" + kept.reversed().joined(separator: "\n")
    }
}
