import DesignSystemPhone
import SecondScreen
import SwiftUI

/// The phone as a remote.
///
/// **The biggest button of the whole design stands here: "Type on the TV".** Because that
/// is the one thing a Siri Remote cannot do. Everything else in this view is
/// more convenient than the real remote; this button is the difference between one
/// minute and five seconds.
///
/// **What explicitly does not stand here is a rebuilt trackpad.** Up, down,
/// select would be a second remote for a device that already has one — and the
/// worse one: glass hits worse than a trackpad you operate blind. What the
/// phone can do better is everything for which the Siri Remote has no button.
///
/// **It shows only what the TV can really do.** For a channel there is no
/// timeline and no skip buttons — the rule lives in ``ControlLimits`` and not
/// three times in the body.
public struct RemoteView: View {

    @State private var model: RemoteModel
    @State private var keyboardOpen = false
    /// Whether the QR reader for pairing is open (decision 6).
    @State private var isScanning = false

    private let account: String
    private let onAccountTap: () -> Void
    /// Continue watching here what is running on the TV — `nil` hides the button.
    private let matches: ((PlaybackJob) -> Void)?
    /// Whether something is running over there — for the consideration of the downloads (E63).
    private let playsRemotely: ((Bool) -> Void)?

    public init(
        model: RemoteModel = RemoteModel(),
        account: String = "?",
        onAccountTap: @escaping () -> Void = {},
        matches: ((PlaybackJob) -> Void)? = nil,
        playsRemotely: ((Bool) -> Void)? = nil
    ) {
        _model = State(initialValue: model)
        self.account = account
        self.onAccountTap = onAccountTap
        self.matches = matches
        self.playsRemotely = playsRemotely
    }

    public var body: some View {
        ZStack {
            ColorRole.reason.color.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                HeaderRow(account: account, onAccountTap: onAccountTap)
                content
            }
        }
        .task { model.searchDevices() }
        // **On the state and not on connecting.** Whoever is connected and plays nothing
        // holds no connection of the account — the downloads may then load.
        .onChange(of: model.status.isRunning, initial: true) { _, isRunning in
            playsRemotely?(isRunning)
        }
        // **And withdrawn on leaving.** A claim that stays standing while
        // nobody is looking any more would hold the downloads forever — exactly the error
        // that a state without a withdrawal has.
        .onDisappear { playsRemotely?(false) }
        // **Pairing via QR** — the same reader as for the handoff. A code that is not a
        // pairing does not close the reader: it keeps reading.
        .sheet(isPresented: $isScanning) {
            SheetFrame(title: "remote.pairing.scan") {
                QRScanner(read: { text in
                    Task {
                        guard await model.pair(text: text) else { return }
                        isScanning = false
                    }
                })
            }
        }
        .sheet(isPresented: $keyboardOpen) {
            KeyboardSheet(
                template: KeyboardSheet.template(from: model.status),
                isSecret: model.status.keyboardSecret,
                tap: { model.tap($0) },
                done: { keyboardOpen = false })
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .isSearching:
            if model.pairingMessage != nil || !model.pairings.isEmpty {
                deviceList([])
            } else {
                VStack(spacing: 0) {
                    LoadingState(message: "remote.searching").frame(maxHeight: .infinity)
                    pairButton.padding(.bottom, MetricsBoard.phone.section)
                }
            }

        case .found(let devices):
            deviceList(devices)

        case .connecting:
            LoadingState(message: "remote.connecting").frame(maxHeight: .infinity)

        case .disrupted(let state):
            StateView(state: state, action: { model.searchDevices() })

        case .connected:
            controls
        }
    }

    /// **A list and no automatic choice.** In a household with two Apple TVs
    /// "the first one to answer" would be a coin toss — and you would notice only when the film
    /// stops in the wrong room.
    private func deviceList(_ devices: [DeviceDiscovery.Device]) -> some View {
        ScrollSurface {
            VStack(alignment: .leading, spacing: 0) {
                report
                if !devices.isEmpty {
                    SettingsCard(header: "remote.foundTVs") {
                        ForEach(devices) { device in
                            DisclosureRow(
                                title: device.name, icon: Glyph.target.name,
                                action: { Task { await model.connect(using: device) } })
                        }
                    }
                    Footnote(message: "remote.foundHint")
                }
                pairingList
                pairButton
                    .padding(.top, MetricsBoard.phone.gutter)
            }
            .padding(.top, MetricsBoard.phone.gutter)
        }
    }

    // MARK: - Kopplung (Entscheidung 6)

    /// What the TV said about the pairing — with the next step.
    @ViewBuilder
    private var report: some View {
        if let report = model.pairingMessage {
            HintRow(
                icon: Glyph.info.name, color: ColorRole.progress.color, title: report.title,
                message: report.message)
            if report.step == .reconnect {
                Button {
                    Task { await model.reconnect() }
                } label: {
                    Text(appKey: "remote.pairing.retry").frame(maxWidth: .infinity)
                }
                .buttonStyle(.loud)
                .padding(.horizontal, MetricsBoard.phone.margin)
                .padding(.bottom, MetricsBoard.phone.gutter)
            }
            if report.step != .none {
                Button {
                    model.dismissMessage()
                    isScanning = true
                } label: {
                    Text(appKey: "remote.pairing.scanAgain").frame(maxWidth: .infinity)
                }
                .buttonStyle(.quiet)
                .padding(.horizontal, MetricsBoard.phone.margin)
                .padding(.bottom, MetricsBoard.phone.gutter)
            }
        }
    }

    /// The paired TVs — **each with a "Forget"**.
    @ViewBuilder
    private var pairingList: some View {
        if !model.pairings.isEmpty {
            SettingsCard(header: "remote.pairing.paired") {
                ForEach(Array(model.pairings.enumerated()), id: \.element.tv) {
                    slot, credential in
                    if slot > 0 { Separator() }
                    HStack(spacing: MetricsBoard.phone.gutter) {
                        Text(verbatim: credential.name)
                            .font(TypeLevel.text.font)
                            .foregroundStyle(ColorRole.text.color)
                        Spacer(minLength: Metrics.targetSpacing)
                        Button {
                            model.forget(credential)
                        } label: {
                            Text(appKey: "remote.pair.forget")
                        }
                        .textHitTarget()
                    }
                    .padding(.horizontal, Metrics.cardInset)
                    .frame(minHeight: Metrics.choiceRow)
                }
            }
        }
    }

    /// "Pair with TV" — **opens the QR reader.** On the TV the code stands under
    /// "iPhone as remote".
    private var pairButton: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                model.dismissMessage()
                isScanning = true
            } label: {
                Label {
                    Text(appKey: "remote.pairing.scan")
                } icon: {
                    Image(systemName: "qrcode.viewfinder")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.quiet)
            .padding(.horizontal, MetricsBoard.phone.margin)
            Footnote(message: "remote.pairing.hint")
        }
    }

    // MARK: - The controls

    private var controls: some View {
        ScrollSurface {
            VStack(alignment: .leading, spacing: MetricsBoard.phone.section) {
                nowPlaying

                if ControlLimits.canControl(model.status) {
                    SwipeField(
                        duration: model.status.duration,
                        location: model.status.location,
                        jumpTo: { model.send(.jumpTo($0)) },
                        jumpBy: { model.jumpBy($0) }
                    )
                    .padding(.horizontal, MetricsBoard.phone.margin)

                    transportRow
                }

                keyboardButton
                fetchHere
                disconnect
            }
            .padding(.top, MetricsBoard.phone.gutter)
        }
    }

    /// What is currently running — **or that nothing is.**
    ///
    /// **The idle state gets a sentence and not an empty surface.** "Nothing is running" is
    /// information; an empty surface under a connected remote looks
    /// like an error.
    @ViewBuilder
    private var nowPlaying: some View {
        if let title = model.status.title {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: title)
                    .font(TypeLevel.section.font)
                    .foregroundStyle(ColorRole.text.color)
                    .lineLimit(2)
                if let beside = model.status.beside {
                    Text(verbatim: beside)
                        .font(TypeLevel.footer.font)
                        .foregroundStyle(ColorRole.textMatt.color)
                        .lineLimit(1)
                }
                if let duration = model.status.duration {
                    Text(
                        verbatim: Timeline.time(model.status.location) + " / "
                            + Timeline.time(duration)
                    )
                    .font(TypeLevel.label.font)
                    .monospacedDigit()
                    .foregroundStyle(ColorRole.textQuiet.color)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, MetricsBoard.phone.margin)
        } else {
            HintRow(
                icon: Glyph.info.name, title: "remote.nothingPlaying",
                message: "remote.nothingPlayingText")
        }
    }

    private var transportRow: some View {
        HStack(spacing: Metrics.targetSpacing) {
            Spacer(minLength: 0)
            roundButton(Glyph.tenBack.name, "player.back10") { model.jumpBy(-10) }
            roundButton(
                model.status.isRunning ? Glyph.pause.name : Glyph.play.name,
                model.status.isRunning ? "common.pause" : "common.play"
            ) {
                model.togglePlayback()
            }
            roundButton(Glyph.thirtyForward.name, "player.forward30") { model.jumpBy(30) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, MetricsBoard.phone.margin)
    }

    private func roundButton(
        _ icon: String, _ label: String, _ action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
        }
        .buttonStyle(.rounded)
        .accessibilityLabel(Text(appKey: label))
    }

    /// **Gone instead of greyed out**, as at ``CommandButtons``: if no field is open on the
    /// TV, this button types into nothing — and you would notice only when you have finished
    /// typing.
    @ViewBuilder
    private var keyboardButton: some View {
        if ControlLimits.canTap(model.status) {
            Button {
                keyboardOpen = true
            } label: {
                Label {
                    Text(appKey: "remote.typeOnTV")
                } icon: {
                    Image(systemName: "keyboard")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.loud)
            .padding(.horizontal, MetricsBoard.phone.margin)
        }
    }

    /// "Bring here" — **only where there is something to bring.**
    ///
    /// **A channel cannot be brought**, and that is no restriction: it runs equally far
    /// everywhere, you would arrive at the same position. What the button promises is
    /// "continue watching at **my** position" — and that exists only where there is a position.
    /// The rule lives in ``SecondScreen/StateMirror/fetchable``.
    @ViewBuilder
    private var fetchHere: some View {
        if let matches, model.status.fetchable {
            Button {
                // **The TV pauses before it continues here.** Two screens
                // with the same movie at the same position are not continued watching but
                // an echo — and with an account with one allowed connection the
                // second would be a `509` anyway.
                if let job = model.bringHere() { matches(job) }
            } label: {
                Label {
                    Text(appKey: "remote.bringHere")
                } icon: {
                    Image(systemName: "iphone.and.arrow.forward")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.quiet)
            .padding(.horizontal, MetricsBoard.phone.margin)
        }
    }

    private var disconnect: some View {
        Button {
            Task { await model.disconnect() }
        } label: {
            Text(appKey: "remote.disconnect").frame(maxWidth: .infinity)
        }
        .buttonStyle(.quiet)
        .padding(.horizontal, MetricsBoard.phone.margin)
        .padding(.bottom, MetricsBoard.phone.section)
    }
}
