import Core
import DesignSystemPhone
import Diagnose
import Flows
import SwiftUI

/// Area 8 · Diagnostics.
///
/// **Two entry points and two ways back.** Diagnostics is reachable even **before** sign-in
/// — exactly when it is needed most: someone who cannot get in otherwise has nothing to
/// describe what is wrong with.
///
/// **Three cards instead of four dividers (2026-09-07).** ID, log scope and the recording each
/// sit in one card; the three buttons below carry none — a button is already a surface in
/// itself, and a card around it would be a box inside a box.
///
/// **The send button says why it does not work.** A greyed-out button without a reason is a
/// dead end; here either a log or a connection is missing, and both can be stated.
struct DiagnoseView: View {
    @Environment(\.horizontalSizeClass) private var widthClass

    @State private var identifier = ""
    /// How many lines the report takes from each of the three ledgers.
    ///
    /// **There used to be a single number here, and it was wrong.** It counted
    /// ``ErrorLog`` — this project's ledger — and sat under the heading "Log", which means
    /// the whole report. On 2026-09-06 it showed "1" while the submitted report had 239 lines. Anyone
    /// who then does not submit because it does not seem worthwhile acted correctly and was
    /// informed wrongly.
    @State private var extent = Extent()
    /// The file for sharing — **only exists while the sheet is open.**
    @State private var file: URL?
    @State private var isRunning = false
    @State private var result: UserNotice?

    /// Whether detailed recording is on.
    ///
    /// **The switch was missing on the phone, and with it half of the diagnostics.** ``DebugMode``
    /// did not occur anywhere in the project: `DebugMode.current` stayed off forever,
    /// `TraceRecorder.shared` never received a line, and the "Recording" section was empty in
    /// every report there ever was. Errors were still captured — they run independently. Only
    /// the history was missing, and that is exactly where a **stutter** shows (as opposed to a
    /// failure, which the error alone already shows).
    ///
    /// **Since 2026-09-26 the shared flow** (`Flows.CaptureRecording`, AP58 R0): it sets the same
    /// places as before plus the marker in the recording, which was missing here and has always
    /// been present on the TV.
    @State private var recording = CaptureRecording()
    @State private var showsLogSheet = false

    /// Which app version the log is kept for — **and since when.**
    ///
    /// **Without this line the number next to it was worthless.** On 2026-09-07 it said "266
    /// errors", and nobody could say which build run they came from. Now the ledger starts over
    /// with every build (``VersionChange``), and this line states since when — only then does
    /// "266" also mean "266 from now".
    @State private var logVersion: LogVersion?
    @State private var showsClearSheet = false
    @State private var showsStateOverview = false

    /// What to report about sending.
    struct UserNotice: Equatable {
        let good: Bool
        let message: String
    }

    /// What the report consists of — **three ledgers, three numbers.**
    struct Extent: Equatable {
        var error = 0
        var recording = 0
        var surface = 0

        /// How many of the lines are only the ledger's heading.
        ///
        /// **They are counted and yet they do not count.** Displayed, they belong, otherwise a
        /// different number would appear here than in the log next to it; for the question "is there
        /// anything to submit" they carry no information.
        var openings = 0

        /// Whether there is anything to submit at all.
        var isEmpty: Bool { error + recording + surface == openings }
    }

    /// Where "View log" leads.
    ///
    /// **Two entry points, two paths.** From Settings it navigates forward; during setup this
    /// view itself sits in a sheet, and there is no wayfinder yet — then the log opens as a
    /// second sheet. Not pretty, but the only path that exists before sign-in at all.
    var log: (() -> Void)?

    /// The ID of this device — **assigned once and then kept.**
    ///
    /// **It has to be the same across app runs.** Someone who reads it out and calls again three
    /// days later would otherwise give a different one, and the two reports can no longer be
    /// merged. `DiagnosticID.fresh()` rolls it; it is kept here, in the default store — it is
    /// not a secret but a name.
    static func deviceID(store: UserDefaults = .standard) -> String {
        let key = "diagnostics.id"
        if let available = store.string(forKey: key) { return available }
        let incoming = DiagnosticID.fresh()
        store.set(incoming, forKey: key)
        return incoming
    }

    /// Counts what the report consists of.
    ///
    /// **It counts the same thing that ``ReportSending/text(identifier:)`` collects** — otherwise
    /// a number about something else would appear here again.
    static func extent() async -> Extent {
        let ledger = await ErrorLog.shared.entries()
        return Extent(
            error: LogModel.decomposed(await TraceRecorder.errors.contents()).count,
            recording: LogModel.decomposed(await TraceRecorder.shared.contents()).count,
            surface: ledger.count,
            openings: ledger.filter { LogVersion.isOpening($0.message) }.count)
    }

    /// Toggles detailed recording — **in all places at once.**
    ///
    /// Which places those are (Keychain, ``DebugMode/current``, the size of the ``ErrorLog``,
    /// the marker in the recording) is known to `Flows.CaptureRecording`; here it only
    /// recounts.
    private func restoreRecording(_ on: Bool) {
        recording.setEnabled(on)
        Task { extent = await Self.extent() }
    }

    /// Starts all three ledgers over by hand.
    ///
    /// **The old message goes with them.** A "Saved" above a log that was just emptied would
    /// speak about a report that no longer exists in that form.
    private func clear() async {
        showsClearSheet = false
        result = nil
        logVersion = await ErrorLog.shared.restart()
        extent = await Self.extent()
    }

    /// Saves the report and says what came out of it.
    private func send() async {
        isRunning = true
        defer { isRunning = false }
        switch await ReportSending.send(identifier: identifier) {
        case .stored(let name):
            result = UserNotice(good: true, message: name)
        case .noServer:
            result = UserNotice(
                good: false, message: SettingsModel.text("settings.diagnostics.noServer"))
        case .rejected(let reason):
            result = UserNotice(good: false, message: reason)
        }
    }

    var body: some View {
        ZStack {
            ColorRole.reason.color.ignoresSafeArea()

            ScrollSurface {
                VStack(alignment: .leading, spacing: 0) {
                    SettingsCard(header: "settings.diagnostics.id") {
                        // **The ID is meant to be read aloud.** It is set in a monospaced font and is
                        // selectable: someone on the phone reading it out to another person
                        // should not have to copy it down.
                        SettingsRow(title: "settings.diagnostics.idLabel", value: identifier)
                    }

                    SettingsCard(header: "settings.diagnostics.log") {
                        // **Three lines and not a sum.** An added-up number
                        // would hide exactly the case this is about: that the
                        // recording is empty while the errors are full.
                        SettingsRow(
                            title: "settings.diagnostics.log.errors",
                            value: extent.error.formatted())
                        Separator()
                        SettingsRow(
                            title: "settings.diagnostics.log.trace",
                            value: extent.recording.formatted())
                        Separator()
                        SettingsRow(
                            title: "settings.diagnostics.log.ui",
                            value: extent.surface.formatted())

                        // **What the three numbers apply to.** It sits directly below,
                        // because without the time span they carry no information: "266" means
                        // something different if it is 266 since noon today.
                        if let logVersion {
                            Separator()
                            SettingsRow(
                                title: "settings.diagnostics.since", value: logVersion.label)
                        }

                        Separator(isIndented: true)

                        DisclosureRow(
                            title: "settings.diagnostics.log.open",
                            icon: Glyph.check.name, isContained: true
                        ) {
                            if let log { log() } else { showsLogSheet = true }
                        }

                        // **The state inspector from here as well** (decision 27, C17) — until
                        // 2026-09-26 reachable only via a launch switch, on the
                        // TV a line of Diagnostics since AP46. **Developer mode
                        // only** (on-device test build 1332, finding 9) —
                        // ``Flows/CaptureRecording/showsDeveloperTools``.
                        if recording.showsDeveloperTools {
                            Separator(isIndented: true)

                            DisclosureRow(
                                title: "state.review.open", icon: Glyph.info.name,
                                isContained: true
                            ) {
                                showsStateOverview = true
                            }
                        }
                    }

                    if logVersion != nil {
                        Footnote(message: "settings.diagnostics.since.text")
                            .padding(.bottom, MetricsBoard.phone.section)
                    }

                    SettingsCard {
                        SwitchRow(
                            title: "settings.diagnostics.verbose",
                            message: "settings.diagnostics.verboseText",
                            on: Binding(
                                get: { recording.on }, set: { restoreRecording($0) })
                        )
                    }

                    // **The loud button saves it to the media server.** The TV's reports
                    // have been stored there for weeks, and that is where one looks anyway
                    // — a report in the share sheet, by contrast, needs someone to send
                    // it somewhere.
                    Button {
                        Task { await send() }
                    } label: {
                        Text(appKey: isRunning ? "action.wait" : "settings.diagnostics.upload")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.loud)
                    .disabled(extent.isEmpty || isRunning)
                    .padding(.horizontal, MetricsBoard.phone.margin)
                    .padding(.top, MetricsBoard.phone.gutter)

                    // **The quiet way next to it, and it was never connected.** Until 2026-09-06 the button
                    // flipped a switch that no view read — it did
                    // nothing. For a device without a media server it is the only way.
                    Button {
                        Task { file = try? await ReportSending.file(identifier: identifier) }
                    } label: {
                        Text(app: "settings.diagnostics.share").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.quiet)
                    .disabled(extent.isEmpty)
                    .padding(.horizontal, MetricsBoard.phone.margin)
                    .padding(.top, Metrics.targetSpacing)

                    if let result {
                        HintRow(
                            icon: result.good ? Glyph.done.pair.outlined : Glyph.warning.name,
                            color: result.good ? ColorRole.success.color : ColorRole.progress.color,
                            title: result.good
                                ? "settings.diagnostics.uploaded"
                                : "settings.diagnostics.notUploaded",
                            wording: result.message)
                    }

                    // **The reason is always shown and not only on press.** A
                    // disabled button whose reason you only learn by pressing it is
                    // none — because then you do not press it.
                    Footnote(
                        message: extent.isEmpty
                            ? "settings.diagnostics.nothingYet" : "settings.diagnostics.whatIsSent"
                    )
                    .padding(.top, 6)
                    .padding(.bottom, MetricsBoard.phone.section)

                    // **The manual way — for the targeted experiment.** On its own
                    // the ledger starts over with every build; but between two build runs there is
                    // the case "now I press it until it breaks, and everything that
                    // appears afterwards belongs to it". Without this button the only option would be to build once
                    // for nothing.
                    Button {
                        showsClearSheet = true
                    } label: {
                        Text(appKey: "settings.diagnostics.clear").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.quiet)
                    .disabled(extent.isEmpty)
                    .padding(.horizontal, MetricsBoard.phone.margin)
                }
                .contentColumn(widthClass)
                .padding(.top, MetricsBoard.phone.gutter)
            }
        }
        .task {
            identifier = Self.deviceID()
            // **First the state, then the numbers.** It is the query for the state that notices
            // a version change and clears out — counted after that, the
            // three numbers match the line above.
            logVersion = await ErrorLog.shared.versionState()
            extent = await Self.extent()
        }
        // **The log as a sheet — only without a wayfinder.** During setup this is the
        // only way; in Settings the branch stays unused, because there it
        // navigates forward.
        .sheet(isPresented: $showsStateOverview) {
            StateShowcase()
                .presentationDetents([.large])
                .presentationCornerRadius(MetricsBoard.phone.sheetRadius)
                .presentationBackground(ColorRole.reason.color)
        }
        .sheet(isPresented: $showsLogSheet) {
            LogView()
                .presentationDetents([.large])
                .presentationCornerRadius(MetricsBoard.phone.sheetRadius)
                .presentationBackground(ColorRole.reason.color)
        }
        // **It asks, like every destructive action in this project** — as a
        // sheet with a loud yes and a quiet no (``DeleteListSheet``) and not as a
        // system alert: the app has none anywhere else, and a single one would be a
        // foreign body in the middle of its own language.
        .sheet(isPresented: $showsClearSheet) {
            ClearLogSheet(
                clear: { Task { await clear() } },
                cancel: { showsClearSheet = false }
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(MetricsBoard.phone.sheetRadius)
            .presentationBackground(ColorRole.reason.color)
        }
        // **The share sheet hangs off the file and not off a switch.** A
        // `Bool` that is set before the file exists opens a sheet over nothing.
        .sheet(item: Binding(get: { file.map(Shareable.init) }, set: { if $0 == nil { file = nil } })) {
            shareable in
            ShareLink(item: shareable.location) {
                Text(app: "settings.diagnostics.share")
            }
            .presentationDetents([.medium])
        }
    }
}

/// Sheet: Empty the log?
///
/// **Why it asks, although the ledger resets itself.** A version change
/// throws away a log that no longer says anything about the running build anyway; this button
/// throws away one that is speaking about it right now. Anyone who hits it by accident has
/// lost the evidence they were about to share — and the only way back would be to trigger the
/// error again.
///
/// **It names what disappears, and that is all three ledgers:** the error trace, the
/// recording and its own ledger. A sentence that only says "the log" would leave out the
/// number this is about.
///
/// **There is no second way back next to the sheet.** That is why — unlike when deleting a
/// channel list — there is no name here that one could recognise; there is only this one
/// log.
struct ClearLogSheet: View {

    let clear: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: MetricsBoard.phone.gutter) {
            Text(appKey: "settings.diagnostics.clear.title")
                .font(TypeLevel.section.font)
                .foregroundStyle(ColorRole.text.color)

            Text(appKey: "settings.diagnostics.clear.text")
                .font(TypeLevel.footer.font)
                .foregroundStyle(ColorRole.textMatt.color)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: clear) {
                Text(appKey: "settings.diagnostics.clear").frame(maxWidth: .infinity)
            }
            .buttonStyle(.loud)
            .padding(.top, MetricsBoard.phone.gutter)

            Button(action: cancel) {
                Text(appKey: "common.cancel").frame(maxWidth: .infinity)
            }
            .buttonStyle(.quiet)
        }
        .padding(.horizontal, MetricsBoard.phone.margin)
        .padding(.vertical, MetricsBoard.phone.section)
    }
}

/// A file that can be shown in a sheet.
///
/// **`sheet(item:)` requires `Identifiable`, and `URL` is not.** A retroactive conformance
/// for a foreign type would be a promise about every other place that uses `URL`; this
/// wrapper applies only here.
struct Shareable: Identifiable {
    let location: URL
    var id: String { location.path }
}
