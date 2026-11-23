import Core
import DesignSystemPhone
import Diagnose
import Flows
import Observation
import SwiftUI

/// The log for reading — **the same text that is submitted.**
///
/// **This was asked for** (2026-09-06): forward navigation at the log, to be able to look inside
/// oneself, in terms of transparency and traceability.
///
/// **And the row before it lied.** It counted "Entries: 1" while the submitted report had 239
/// lines: what was counted was ``ErrorLog``, this project's ledger; what is submitted in
/// addition is the trace that `Core` and `Playback` keep on their own. A number that counts
/// something other than what stands next to it is worse than none — it looks right, and here
/// it made a full report appear empty.
///
/// **What is shown is what is sent, and not a prettier selection.** Whoever looks wants to
/// know what leaves the device. That works because both ledgers redact already when writing
/// and not only when sending — otherwise more would stand here than in the report.
///
/// **Newest on top.** A log is read from the back: what just happened is at the end of the
/// file and interests first.
struct LogView: View {

    @State private var model = LogModel()

    var body: some View {
        ZStack {
            ColorRole.reason.color.ignoresSafeArea()

            VStack(spacing: 0) {
                SegmentRow(pages: model.segments, chosen: $model.section)

                if model.isLoading {
                    ProgressView().tint(ColorRole.textMatt.color).frame(maxHeight: .infinity)
                } else if model.rows.isEmpty {
                    empty.frame(maxHeight: .infinity, alignment: .top)
                } else {
                    SearchField(text: $model.searchTerm, placeholder: "settings.diagnostics.log.search")
                    list
                }
            }
            .padding(.top, MetricsBoard.phone.gutter)
        }
        .task { await model.load() }
    }

    /// **Two empty cases and two sentences.** An empty error ledger is good news; an empty
    /// recording is a switched-off switch — and whoever does not distinguish the two leaves
    /// exactly the error standing that made this screen necessary.
    private var empty: some View {
        HintRow(
            icon: model.section == 1 ? Glyph.warning.name : Glyph.info.name,
            color: model.section == 1 ? ColorRole.progress.color : ColorRole.textQuiet.color,
            title: "settings.diagnostics.log.empty",
            message: model.section == 1
                ? "settings.diagnostics.log.empty.trace" : "settings.diagnostics.log.empty.text")
    }

    /// **A `List` and not a scroll view.** With two thousand lines the reuse of rows decides
    /// whether scrolling is smooth — and a log is the only view in this app that grows this
    /// long.
    private var list: some View {
        List {
            ForEach(Array(model.shown.enumerated()), id: \.offset) { _, row in
                // **A character before the line and not only a color** (AP5). Until 2026-09-10 only the gold
                // marked "conspicuous"; whoever cannot tell gold from muted grey saw two hundred
                // identical-looking lines and no hint which of them is meant.
                //
                // **An exclamation mark and no symbol.** The line is set in monospace so that timestamps
                // line up; an `Image` next to it would break the column. The character takes exactly one
                // position, and the inconspicuous lines get a space there — otherwise every conspicuous
                // line would be indented against the others.
                Text(verbatim: (model.isNotable(row) ? "! " : "  ") + row)
                    .font(TypeLevel.label.font.monospaced())
                    .foregroundStyle(color(row))
                    // **And for the screen reader a word instead of a character.** It reads "!" as punctuation
                    // or not at all.
                    .accessibilityLabel(
                        model.isNotable(row)
                            ? Text(app: "settings.diagnostics.log.notable") + Text(verbatim: ": " + row)
                            : Text(verbatim: row)
                    )
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .listRowInsets(
                        EdgeInsets(
                            top: 4, leading: MetricsBoard.phone.margin, bottom: 4,
                            trailing: MetricsBoard.phone.margin)
                    )
                    .listRowBackground(ColorRole.reason.color)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(ColorRole.reason.color)
    }

    /// **Conspicuous in gold, everything else quiet.**
    ///
    /// Not in red: red means "broken right now", and a log shows the past. Whoever sees two
    /// hundred red lines reads none of them.
    private func color(_ row: String) -> Color {
        model.isNotable(row) ? ColorRole.progress.color : ColorRole.textMatt.color
    }
}

/// Where the lines come from — **from both ledgers, selectable separately.**
///
/// **Separate and not interwoven.** The three sources keep their own clocks and their own
/// formats; mixing them by time would look like a history that would not be one.
@MainActor
@Observable
final class LogModel {

    private(set) var error: [String] = []
    private(set) var recording: [String] = []
    private(set) var surface: [String] = []
    private(set) var isLoading = false

    var section = 0
    var searchTerm = ""

    /// The labels of the segments — **with the number in them.**
    ///
    /// Only the number makes the tab an answer: "Recording 0" says at a glance that there is
    /// nothing there, without having to switch over.
    var segments: [String] {
        [
            SettingsModel.text("settings.diagnostics.log.errors") + " \(error.count)",
            SettingsModel.text("settings.diagnostics.log.trace") + " \(recording.count)",
            SettingsModel.text("settings.diagnostics.log.ui") + " \(surface.count)",
        ]
    }

    var rows: [String] {
        switch section {
        case 1: recording
        case 2: surface
        default: error
        }
    }

    var shown: [String] {
        rows.filter { LogSearch.matches($0, word: searchTerm) }
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        error = Self.decomposed(await TraceRecorder.errors.contents())
        recording = Self.decomposed(await TraceRecorder.shared.contents())
        surface = await ErrorLog.shared.entries().reversed().map(\.row)
    }

    /// Splits a trace file into lines — **newest first.**
    nonisolated static func decomposed(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init).reversed()
    }

    /// Whether a line should be highlighted.
    ///
    /// **By the characters both ledgers set, and not by words.** ``ContentEntryRecord/row`` sets "✗" for
    /// a failure and "!" for a notice; `TraceRecorder` adopts the same ones. Checking for German
    /// words would mean losing the highlighting in three languages.
    nonisolated func isNotable(_ row: String) -> Bool {
        LogSearch.isNotable(row)
    }
}
