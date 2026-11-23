import Core
import DesignSystem
import Flows
import JellyfinKit
import SwiftUI

/// The latest requests, readable **on the TV**.
///
/// **The reason for this area is a limit we ran into.** On a computer `log show` is enough
/// to see what the app does. On the Apple TV that does not work: over the network macOS
/// refuses to collect logs ("Device not configured"), over a cable you are tied to the
/// computer, and the console on the computer is no answer for everyday use. But that is
/// exactly where errors occur that do not exist in the simulator — a name that only the home
/// network knows, a different DNS, a certificate.
///
/// What is shown is what is recorded anyway: step, address and **translated** cause. The
/// translation is the real value — "Network error -1003" answers no question, "The name
/// could not be resolved. Check: does the device use the home network's DNS?" answers
/// exactly this one.
public struct DiagnosticsSettings: View {

    @FocusState.Binding var focus: String?
    /// For sending to the server log. If it is missing, the button does not appear —
    /// without a media server there is nobody to receive anything.
    let source: JellyfinSource?

    /// Public, because the **sign-in** needs the area too: the first real device error (2026-07-28)
    /// occurred before sign-in — exactly where the diagnostics did not reach until then.
    public init(focus: FocusState<String?>.Binding, source: JellyfinSource?) {
        self._focus = focus
        self.source = source
    }

    @State private var sending = false
    @State private var result: Result?
    @State private var measuring = false
    @State private var measurement: String?
    /// The "record verbosely" switch — since 2026-09-26 the shared flow
    /// (`Flows.CaptureRecording`, AP58 R0) that the phone uses too.
    @State private var recording = CaptureRecording()
    @State private var liveEngine = LiveEngineChoice.load(from: SecureStore())
    @State private var ownDecoder = HardwareVideoDecoder.enabled

    private enum Result: Equatable {
        case sent(String)
        case failed
    }

    /// Re-read on every display. No `@State`: the trace fills in the background, and a state
    /// copied once would already be stale by the time you look.
    private var entries: [Diagnostics.Trace.Entry] {
        // The newest first: whoever comes here is looking for what just went wrong. From the
        // chronologically ordered version, not from the raw list — queueing runs through detached
        // tasks, and nobody promises their order.
        Self.filtered(
            Diagnostics.Trace.chronological.reversed(), onlyNotable: onlyNotable,
            searchTerm: searchTerm)
    }

    /// **Filter and search as on the phone** (decision 27, C17): failures only, and a word that
    /// appears in step, target or reason — ``Flows/LogSearch``.
    @State private var onlyNotable = false
    @State private var searchTerm = ""

    static func filtered(
        _ entries: [Diagnostics.Trace.Entry], onlyNotable: Bool, searchTerm: String
    ) -> [Diagnostics.Trace.Entry] {
        entries.filter { entry in
            var reason = ""
            if case .failed(let text) = entry.outcome {
                reason = text
            } else if onlyNotable {
                return false
            }
            return LogSearch.matches(
                entry.step + " " + entry.target + " " + reason, word: searchTerm)
        }
    }

    /// Whether the state inspector is open.
    @State private var showsStateOverview = false

    /// The path to the state inspector (G4) — **a ``DisclosureRow`` since 2026-09-25** (AP46):
    /// the press leads to another screen, and the arrow says so.
    ///
    /// **Here and not in the settings next to it.** It is a tool and not an area: it produces
    /// twenty failures that could not be produced otherwise — switching a server off, letting
    /// an access token expire, using a provider account twice. Nobody should stumble into it on
    /// the release path, and diagnostics is the place that only someone who is checking
    /// something visits anyway.
    private var stateOverviewButton: some View {
        DisclosureRow(
            title: "state.review.open",
            card: CardSpec(header: "state.review.open"),
            identifier: "zustandsschau",
            focus: $focus
        ) {
            showsStateOverview = true
        }
        .padding(.top, 14)
        #if os(tvOS)
            .fullScreenCover(isPresented: $showsStateOverview) {
                ZStack {
                    ColorRole.reason.color.ignoresSafeArea()
                    StateShowcase()
                    .padding(.horizontal, MetricsBoard.tv.margin)
                    .padding(.vertical, TVMetrics.topMargin)
                }
            }
        #endif
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsHeader("settings.diagnostics", hint: "settings.diagnosticsHint")

            debugToggle
            // **Direct renderer and custom decoder are taken out of the UI** (decision 2026-09-04, see
            // roadmap): the HLS path is the path — AirPlay, Picture in Picture and the Dolby bitstream
            // remain only there. The switches (``rendererToggle``, ``decoderToggle``) and the paths
            // behind them stay in the source, for measurements and for the day they have something to
            // offer again.
            measureButton
            sendButton
            // **Developer mode only** (on-device test build 1332, finding 9) —
            // ``Flows/CaptureRecording/showsDeveloperTools``.
            if recording.showsDeveloperTools {
                stateOverviewButton
            }

            SwitchRow(
                title: "settings.diagnostics.onlyNotable",
                on: $onlyNotable,
                card: .toggle(
                    header: "settings.diagnostics.onlyNotable", on: onlyNotable, explanation: nil,
                    validity: .device),
                identifier: "log-notable",
                focus: $focus
            )
            .padding(.top, 14)
            InputRow(
                title: "settings.diagnostics.log.search", text: $searchTerm, state: .inRow,
                kind: .prose, width: 620, identifier: "log-search", focus: $focus
            )
            .padding(.top, 14)

            if entries.isEmpty {
                Text(app: "settings.diagnosticsEmpty")
                    .font(TypeLevel.footer.font)
                    .foregroundStyle(ColorRole.textQuiet.color)
                    .padding(.top, 8)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(entries) { entry in
                            row(entry)
                        }
                    }
                    .padding(.vertical, 8)
                }
                // **The rows take focus so that the list scrolls.** `allowsHitTesting(false)` stood here
                // — the rows are text, after all, and not a selection. Only a ScrollView on tvOS scrolls
                // exclusively after the focus, and below the buttons there was nothing focusable: from
                // about eight entries on, everything below the edge was unreachable — of all things the
                // history the area was built for, up to two hundred entries deep in verbose mode.
                //
                // Each row is therefore a button without effect, with a visible highlight — invisible
                // focus would be the next bug, see ``MainView/returningFromSearch``. The focus section of
                // its own keeps the way back to the buttons above open: the list is entered and left as a
                // whole instead of swallowing the controls.
                .focusSection()
                .frame(maxHeight: 620)
            }
        }
    }

    /// The switch for verbose recording.
    ///
    /// While it is on, the trace grows to ``Diagnostics/Trace/verboseCapacity`` entries and
    /// also records successes and every playback step — the material for the search for a
    /// stutter. **Explicitly not meant to be permanent**, and it says so right there: even two
    /// hundred slots fill up in everyday use with what goes well anyway, and the one line that
    /// matters falls off the back.
    private var debugToggle: some View {
        SwitchRow(
            title: "settings.debugMode",
            message: "settings.debugModeHint",
            on: Binding(
                // Store, valid state and the mark in the trace ("A gap in the recording thereby has an
                // explanation instead of a suspicion") are set by the flow.
                get: { recording.on },
                set: { recording.setEnabled($0) }),
            // Without an explanatory sentence: the row already carries it as `message`.
            card: .toggle(
                header: "settings.debugMode", on: recording.on, explanation: nil, validity: .device),
            identifier: "debugMode",
            focus: $focus
        )
        .padding(.bottom, 12)
    }

    /// The switch for the live engine — HLS path or direct renderer.
    ///
    /// **A measuring tool, not a convenience** (2026-09-03): both paths are built, and which one
    /// holds up only the TV can tell. The startup tally in the report lists them separately —
    /// switch, open the same channels, compare. The change applies to the next channel start,
    /// not to the running one.
    private var rendererToggle: some View {
        SwitchRow(
            title: "settings.liveRenderer",
            message: "settings.liveRendererHint",
            on: Binding(
                get: { liveEngine == .renderer },
                set: { fresh in
                    liveEngine = fresh ? .renderer : .hls
                    liveEngine.save(to: SecureStore())
                    // The switch itself belongs in the trace — otherwise the report shows a tally with two
                    // paths and nobody knows when it was switched.
                    Diagnostics.probe("Live engine switched: \(liveEngine.rawValue)")
                }),
            // Without an explanatory sentence: the row already carries it as `message`.
            card: .toggle(
                header: "settings.liveRenderer", on: liveEngine == .renderer, explanation: nil,
                validity: .device),
            identifier: "liveRenderer",
            focus: $focus
        )
        .padding(.bottom, 12)
    }

    /// The switch for the custom decoder in the direct renderer.
    ///
    /// **For troubleshooting, not for everyday use** (F-016, 2026-09-03): the Apple TV refuses
    /// deinterlacing in hardware, and the path rejected pictures on Rendal HQ (`-12911`). It stays
    /// built — for the deinterlacing on the GPU that comes next —, and whoever wants to check
    /// it on the device switches it on here. Applies only to interlaced channels in the direct
    /// renderer.
    private var decoderToggle: some View {
        SwitchRow(
            title: "settings.ownDecoder",
            message: "settings.ownDecoderHint",
            on: Binding(
                get: { ownDecoder },
                set: { fresh in
                    ownDecoder = fresh
                    HardwareVideoDecoder.save(fresh, to: SecureStore())
                    Diagnostics.probe("Own decoder switched: \(fresh ? "on" : "off")")
                }),
            // Without an explanatory sentence: the row already carries it as `message`.
            card: .toggle(header: "settings.ownDecoder", on: ownDecoder, explanation: nil, validity: .device),
            identifier: "ownDecoder",
            focus: $focus
        )
        .padding(.bottom, 12)
    }

    /// Measures the connection **from the TV**.
    ///
    /// The measurement that was missing all along: from a computer on the same network the
    /// server answers in forty milliseconds; from the TV the report showed seven to ten
    /// seconds. What causes that could not be decided from outside. Here the measurement is
    /// taken where the problem occurs.
    @ViewBuilder
    private var measureButton: some View {
        if let source {
            VStack(alignment: .leading, spacing: 10) {
                // The discarded second press and the busy notice now live in
                // ``ActionRow`` — both already applied here, but only here.
                ActionRow(
                    title: "settings.measure",
                    statusTitle: "settings.measuring",
                    icon: "speedometer",
                    state: measuring ? .isRunning : .ready,
                    identifier: "measure",
                    focus: $focus
                ) {
                    Task { await measure(via: source) }
                }

                if let measurement {
                    Text(verbatim: measurement)
                        .font(TypeLevel.lowercased.font)
                        .foregroundStyle(ColorRole.textMatt.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 900, alignment: .leading)
                }
            }
            .padding(.bottom, 16)
        }
    }

    private func measure(via source: JellyfinSource) async {
        measuring = true
        defer { measuring = false }
        let result = await ConnectionProbe(source: source).run()
        // Every measurement also feeds the automatic quality selection — otherwise only the
        // diagnostics screen would know what the connection can carry, and playback would go on
        // deciding blind.
        if let throughput = result.throughput {
            ThroughputMemory.save(mbps: throughput, to: SecureStore())
        }
        measurement = result.summary
    }

    /// Sends the trace to the media server.
    ///
    /// **Not by mail, and that is no convenience.** tvOS has neither a mail window nor a share
    /// sheet — both exist only on iOS and macOS. What exists is the server, which is up anyway:
    /// Jellyfin accepts client logs and files them with its own, to be collected in the web
    /// interface under Dashboard → Logs. No additional service, no credentials in the app.
    @ViewBuilder
    private var sendButton: some View {
        if let source {
            VStack(alignment: .leading, spacing: 10) {
                // See ``measureButton`` — the same reason, the same pattern (AP22).
                // **And here it weighs more:** a report goes over the thin connection, that takes a while;
                // whoever loses focus during that time takes the screen for hung and presses.
                ActionRow(
                    title: "settings.diagnosticsSend",
                    statusTitle: "settings.diagnosticsSending",
                    icon: "square.and.arrow.up",
                    state: sending ? .isRunning : .ready,
                    identifier: "sendLog",
                    focus: $focus
                ) {
                    Task { await send(via: source) }
                }

                // **The identifier is shown, no longer the file name** (AP17, 2026-09-02). The server's name
                // answered "is it there?"; but what is needed is how the viewer says on the phone WHICH one
                // it is — and for that it is too long and carries characters you do not read out. The same
                // identifier appears as a line of its own at the very top of the uploaded report; support
                // finds it that way in a folder full of reports with a single search command.
                switch result {
                case .sent(let identifier):
                    VStack(alignment: .leading, spacing: 4) {
                        Text(app: "settings.diagnosticsSentID")
                            .font(TypeLevel.lowercased.font)
                            .foregroundStyle(ColorRole.textMatt.color)
                        Text(verbatim: identifier)
                            // Large and with equal digit widths: it is read out, not skimmed.
                            .font(TypeLevel.header.font)
                            .monospaced()
                            .foregroundStyle(ColorRole.success.color)
                    }
                case .failed:
                    Text(app: "settings.diagnosticsSendFailed")
                        .font(TypeLevel.lowercased.font)
                        .foregroundStyle(ColorRole.live.color)
                case nil:
                    EmptyView()
                }
            }
            .padding(.vertical, 12)
        }
    }

    private func send(via source: JellyfinSource) async {
        sending = true
        defer { sending = false }

        // **The identifier is created here and not in the report** (AP17, 2026-09-02): it has to be on
        // the screen AND in the uploaded text, and the same one. Created twice there would be two —
        // and support would search for one that appears nowhere.
        let identifier = DiagnosticID.fresh()
        do {
            _ = try await source.uploadLog(await report(identifier: identifier))
            // **The file name was the wrong answer.** It answers "is it there?"; but what is needed is
            // how the viewer says on the phone WHICH one it is. The server's name is too long for that
            // and carries characters you do not read out.
            result = .sent(identifier)
        } catch {
            Diagnostics.defect(
                "Report not sent: \(Diagnostics.explain(error))", since: nil, area: "Oberfläche")
            result = .failed
        }
    }

    /// The trace as text, the way it arrives at the server.
    ///
    /// With a header: whoever finds the file later among the server logs should know without
    /// asking which device and which state it comes from.
    ///
    /// **From the disk trace, not from the ring buffer:** the file carries up to three days and
    /// survives a restart — the buffer only the running session. If the file is empty (freshly
    /// installed, cleaned up by the system), the buffer remains as a fallback; it is never longer
    /// than the file, just there earlier.
    private func report(identifier: String? = nil) async -> String {
        var lines =
            [
                "CineLounge — Diagnostics",
                "Created: \(Date().formatted(date: .abbreviated, time: .standard))",
            ]
            // At the very top and in a line of its own — see ``DiagnosticID``.
            + (identifier.map { [DiagnosticID.headerLine($0)] } ?? [])
            // The profile card — which build, which device, which mode. Why it belongs in every
            // diagnosis is explained at ``Diagnostics/reportHeader()``.
            + Diagnostics.reportHeader()
            + [""]

        // **Two sections, two promises** (requirement 2026-08-15): the error trace always runs — it is
        // there even if nobody ever touched a switch. The recording carries every step, but only
        // from the times when the switch was on; the state marks ("App start", "Recording switched
        // on/off") order both.
        // **Cut down to what the server accepts** (on-device finding 2026-08-16: "Sending not
        // possible" — Jellyfin accepts client logs only up to about a megabyte, and two full disk
        // traces blew past that; the rejection read like a server that was switched off). Cutting
        // happens at the FRONT: the newest is what matters when submitting.
        // **The startup as a tally, not as a heap of lines** (AP12, 2026-09-02). The individual
        // measurements stay further down in the recording; here is what they say together. Without
        // this section everyone who wanted to answer the question "is the startup uneven?" had to
        // lay the lines side by side by hand — and the question has been in the roadmap since
        // 2026-08-11.
        let startup = StartupTally.shared.report
        if !startup.isEmpty {
            lines.append("═══ Startup (this session) ═══")
            lines.append(contentsOf: startup)
            lines.append("")
        }

        let errors = Self.tail(of: await TraceRecorder.errors.contents(), maxBytes: 200_000)
        lines.append("═══ Errors (always recorded) ═══")
        lines.append(errors.isEmpty ? "No errors in the last three days." : errors)
        lines.append("")

        let recorded = Self.tail(
            of: await TraceRecorder.shared.contents(), maxBytes: 600_000)
        lines.append("═══ Recording (only with \"verbose recording\") ═══")
        if recorded.isEmpty {
            lines.append(
                DebugMode.current.isOn
                    ? "Switched on, but nothing recorded yet."
                    : "Recording is off.")
            // The fallback: freshly installed or cleaned up by the system — then at least the ring
            // buffer carries the session.
            for entry in Diagnostics.Trace.chronological {
                lines.append(
                    "\(entry.at.formatted(date: .omitted, time: .standard))  \(entry.reportLine)"
                )
            }
        } else {
            lines.append(recorded)
        }
        return lines.joined(separator: "\n")
    }

    /// The end of a text, cut at line boundaries — for the report.
    ///
    /// Why it is cut is explained at the caller; cut at the FRONT, because the newest counts. A
    /// mark at the start honestly says that something is missing.
    static func tail(of text: String, maxBytes: Int) -> String {
        guard text.utf8.count > maxBytes else { return text }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var kept: [Substring] = []
        var total = 0
        for line in lines.reversed() {
            let cost = line.utf8.count + 1
            if total + cost > maxBytes { break }
            kept.append(line)
            total += cost
        }
        return "… (cut at the front, older lines gone)\n" + kept.reversed().joined(separator: "\n")
    }

    /// A row of the trace — as a button that does nothing when pressed.
    ///
    /// The focus serves only for scrolling here, see the reasoning at the list. The highlight
    /// is deliberately quieter than with the real buttons — a raised surface instead of the
    /// bright capsule: the row should read as entered, not as an invitation to press.
    private func row(_ entry: Diagnostics.Trace.Entry) -> some View {
        let id = "log-" + entry.id.uuidString
        let isFocused = focus == id

        return Button {
            // Bewusst ohne Wirkung: Es gibt an einer Protokollzeile nichts zu tun.
        } label: {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: symbol(for: entry.outcome))
                    .font(.system(size: 20))
                    .foregroundStyle(color(for: entry.outcome))
                    .frame(width: 26)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 12) {
                        Text(verbatim: entry.step)
                            .font(TypeLevel.footer.font)
                            .foregroundStyle(ColorRole.text.color)
                        Text(verbatim: entry.at.formatted(date: .omitted, time: .standard))
                            .font(TypeLevel.lowercased.font)
                            .foregroundStyle(ColorRole.textQuiet.color)
                    }

                    Text(verbatim: entry.target)
                        .font(TypeLevel.lowercased.font)
                        .foregroundStyle(ColorRole.textMatt.color)
                        .lineLimit(1)

                    // The cause appears only on a failure, and then in full: it is the reason this area
                    // exists, and must not be cut off after one line.
                    if case .failed(let reason) = entry.outcome {
                        Text(verbatim: reason)
                            .font(TypeLevel.lowercased.font)
                            .foregroundStyle(ColorRole.live.color)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 1000, alignment: .leading)
                    }
                }
            }
            .frame(maxWidth: 1060, alignment: .leading)
            .settingsSurface(.readingRow, isFocused: isFocused, reason: .clear)
        }
        .bareFocusableButton()
        .focused($focus, equals: id)
        // **The outcome lives here solely in the glyph and its colour** — both mean nothing to the
        // screen reader. Without this line every entry would begin with
        // `exclamationmark.triangle.fill`, and that is a file name, not information.
        .info(
            Text(verbatim: entry.step + " — " + entry.target),
            .key(Self.outcome(entry.outcome)))
    }

    /// The outcome of a trace row as a word — the same statement that the glyph carries.
    static func outcome(_ outcome: Diagnostics.Trace.Entry.Outcome) -> String {
        switch outcome {
        case .started: "a11y.trace.started"
        case .succeeded: "a11y.trace.succeeded"
        case .failed: "a11y.trace.failed"
        }
    }

    private func symbol(for outcome: Diagnostics.Trace.Entry.Outcome) -> String {
        switch outcome {
        case .started: "arrow.right.circle"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private func color(for outcome: Diagnostics.Trace.Entry.Outcome) -> Color {
        switch outcome {
        case .started: ColorRole.textQuiet.color
        case .succeeded: ColorRole.success.color
        case .failed: ColorRole.live.color
        }
    }
}
