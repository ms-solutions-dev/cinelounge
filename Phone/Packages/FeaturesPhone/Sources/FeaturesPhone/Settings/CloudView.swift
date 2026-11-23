import CloudSync
import Core
import DesignSystemPhone
import Flows
import ProfileKit
import SwiftUI

#if canImport(CoreImage)
    import CoreImage
    import CoreImage.CIFilterBuiltins
#endif

/// "Devices & Sharing" on the phone — **the page with the camera** (AP44).
///
/// **The counterpart of the ``CloudSheet`` on the TV, and the difference is exactly
/// one:** this device can scan. That is why a third way stands here that does not exist on the
/// TV — "Pair", the camera on the code of the other device.
///
/// **What happens afterwards stands in the code and not on this screen.** One and the
/// same scanner receives a profile *and* hands one out; which of the two it is
/// is stated by the ``ProfileKit/Pairing/Role`` in the scanned text. Two buttons ("fetch" /
/// "give") would be two opportunities to press the wrong one — and the viewer would not
/// know beforehand which is the right one: they see only a QR on the TV.
///
/// **The QR for the opposite direction is there anyway** (phone → iPad): two devices with a
/// camera need one that shows.
struct CloudView: View {

    let cloud: ProfileCloud
    /// Where ``ProfileKit/ProfileBook`` lives — the same store as everywhere.
    let store: any KeyValueStore

    /// **Pages, sharing and revocation are led by ``Flows/SharingFlow``** (AP58 R2) —
    /// the same flow as on the TV; here the phone fetches with the camera
    /// (``Flows/SharingFlow/PullMode/camera``).
    @State private var flow: SharingFlow
    @State private var asksToEnd = false
    @State private var asksToLeave = false
    /// The device that is currently being renamed, and the name in the field.
    @State private var rename: DeviceEntry?
    @State private var newName = ""

    /// A profile link from the system camera that this page accepts right away.
    private let opened: ProfileLink?
    /// A pairing code from the system camera (``ProfileKit/Pairing``) — as if scanned, only without a reader.
    private let pairingCode: String?
    private let done: () -> Void
    /// The opened code that wants a profile **from here** and is therefore asked about first.
    @State private var asksToHandOver: String?

    init(
        cloud: ProfileCloud, store: any KeyValueStore = FileStore(), opened: ProfileLink? = nil,
        pairingCode: String? = nil, done: @escaping () -> Void = {}
    ) {
        self.cloud = cloud
        self.store = store
        self.opened = opened
        self.pairingCode = pairingCode
        self.done = done
        _flow = State(initialValue: Self.flow(cloud: cloud, store: store))
    }

    /// The flow for the profile that is currently in front.
    private static func flow(cloud: ProfileCloud, store: any KeyValueStore) -> SharingFlow {
        SharingFlow(
            profile: ProfileBook.read(from: store).activeProfile, cloud: cloud, pullMode: .camera)
    }

    private var profile: Profile? { flow.profile }
    private var page: SharingFlow.Page { flow.page }
    private var pairing: PairingModel? { flow.pairing }
    private var approval: AccessGrant? { flow.approval }
    private var error: String? { flow.error }
    private var isBorrowed: Bool { flow.isBorrowed }
    private var sharedBy: String? { flow.sharedBy }

    var body: some View {
        ZStack {
            ColorRole.reason.color.ignoresSafeArea()

            switch page {
            case .overview: overview
            case .isFetching, .gives: operation
            }
        }
        .navigationTitle(Text(app: "pairing.title"))
        .task { await flow.loadSharing() }
        // **The acceptance does not hang on the view** (report of 2026-09-28, CKError 20): here
        // stood `await flow.accept` in the task itself. `done()` clears the link,
        // which changes the `id`, and SwiftUI cancelled the task in the middle of the
        // iCloud acceptance. A task of its own runs to the end.
        .task(id: opened?.approval) {
            guard let opened else { return }
            let flow = flow
            Task { await flow.accept(opened) }
            done()
        }
        // **An opened pairing code is already the scan.** If the phone fetches, it starts
        // right away; if it hands a profile out, it asks first — a registered scheme can be
        // called by any web page, and only what someone has confirmed is handed out.
        .task(id: pairingCode) {
            guard let pairingCode, let read = Pairing.read(pairingCode) else { return }
            done()
            if read.role.scannerFetches {
                process(pairingCode)
            } else {
                asksToHandOver = pairingCode
            }
        }
        .alert(
            Text(app: "pairing.renameDevice"),
            isPresented: Binding(get: { rename != nil }, set: { if !$0 { rename = nil } })
        ) {
            TextField(text: $newName) { Text(app: "pairing.deviceName") }
            Button {
                if let device = rename {
                    let name = newName
                    Task { await flow.rename(device: device.identifier, name: name) }
                }
                rename = nil
            } label: {
                Text(app: "common.save")
            }
            Button(role: .cancel) {
                rename = nil
            } label: {
                Text(app: "common.cancel")
            }
        } message: {
            Text(app: "pairing.renameDeviceHint")
        }
        .confirmationDialog(
            Text(app: "pairing.giveConfirm \(profile?.name ?? "")"),
            isPresented: Binding(
                get: { asksToHandOver != nil }, set: { if !$0 { asksToHandOver = nil } }),
            titleVisibility: .visible
        ) {
            Button {
                if let code = asksToHandOver { process(code) }
                asksToHandOver = nil
            } label: {
                Text(app: "pairing.giveAction")
            }
        } message: {
            Text(app: "pairing.giveConfirmHint")
        }
        .confirmationDialog(
            Text(app: "pairing.endConfirm"), isPresented: $asksToEnd, titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                Task { await flow.finish() }
            } label: {
                Text(app: "pairing.end")
            }
        } message: {
            Text(app: "pairing.endHint")
        }
        .confirmationDialog(
            Text(app: "pairing.leaveConfirm"), isPresented: $asksToLeave,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                Task { await leave() }
            } label: {
                Text(app: "pairing.leave")
            }
        } message: {
            Text(app: "pairing.leaveHint")
        }
    }

    /// A code that came in without a reader goes through the same flow as a scanned one.
    private func process(_ code: String) {
        let flow = flow
        flow.start(.isFetching)
        Task { await flow.scanned(code) }
    }

    // MARK: - Overview

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let error {
                    HintRow(icon: Glyph.offline.name, title: error)
                        .padding(.horizontal, MetricsBoard.phone.margin)
                        .padding(.bottom, MetricsBoard.phone.gutter)
                }

                SettingsCard(header: "pairing.pair") {
                    DisclosureRow(
                        title: "pairing.pairAction", icon: Glyph.camera.name,
                        action: { flow.start(.isFetching) })
                }

                if profile != nil, !isBorrowed {
                    SettingsCard(header: "pairing.give") {
                        DisclosureRow(
                            title: "pairing.giveAction", icon: Glyph.share.name,
                            action: { flow.start(.gives) })
                    }
                }

                if profile != nil {
                    deviceCard
                }

                if isBorrowed {
                    borrowedSection
                } else {
                    participantCard
                }

                Footnote(message: "pairing.hint")
                Spacer(minLength: 0)
            }
            .padding(.top, MetricsBoard.phone.gutter)
        }
    }

    /// Where this profile runs — **newest first, this device marked** (2026-10-01,
    /// after StoryShelf's "iCloud & Devices"). A press renames; the name applies on all
    /// devices of the profile.
    @ViewBuilder
    private var deviceCard: some View {
        SettingsCard(header: "pairing.devices") {
            if flow.devices.isEmpty {
                HintRow(icon: Glyph.handoff.name, title: "pairing.devicesEmpty")
            } else {
                ForEach(flow.devices) { device in
                    deviceRow(device)
                }
            }
        }
    }

    private func deviceRow(_ device: DeviceEntry) -> some View {
        Button {
            newName = device.name
            rename = device
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: device.name)
                        .font(TypeLevel.text.font)
                        .foregroundStyle(ColorRole.text.color)
                    if device.identifier == flow.thisDevice {
                        Text(app: "pairing.deviceThis")
                            .font(TypeLevel.label.font)
                            .foregroundStyle(ColorRole.textMatt.color)
                    }
                }
                Text(verbatim: Self.deviceDetail(device))
                    .font(TypeLevel.label.font)
                    .foregroundStyle(ColorRole.textMatt.color)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Metrics.cardInset)
            .frame(minHeight: Metrics.choiceRow)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// „iPad · zuletzt 30.09.2026, 20:14“.
    static func deviceDetail(_ device: DeviceEntry) -> String {
        let when = device.recent.formatted(date: .abbreviated, time: .shortened)
        return [device.model, AppLanguageSetting.text("pairing.deviceSeen \(when)")]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    @ViewBuilder
    private var participantCard: some View {
        SettingsCard(header: "pairing.participants") {
            if let approval, !approval.invited.isEmpty {
                ForEach(approval.invited) { participant in
                    participantRow(participant)
                }
                DisclosureRow(title: "pairing.end", action: { asksToEnd = true })
            } else {
                HintRow(
                    icon: Glyph.person.name, title: "pairing.participantsEmpty")
            }
        }
    }

    @ViewBuilder
    private var borrowedSection: some View {
        SettingsCard(header: "pairing.shared") {
            ValueRow(title: "pairing.sharedByLabel", value: sharedBy ?? "—")
            DisclosureRow(title: "pairing.leave", action: { asksToLeave = true })
        }
    }

    /// One row per participant, with the way out next to it.
    ///
    /// **A visible button and no swipe.** The card is not a `List`; a
    /// swipe command would be a hidden action here, in a place where you do not
    /// look for it — and "who has my profile" is exactly the question where you want to see
    /// the way out.
    private func participantRow(_ participant: Participant) -> some View {
        HStack(spacing: MetricsBoard.phone.gutter) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: participantTitle(participant))
                    .font(TypeLevel.text.font)
                    .foregroundStyle(ColorRole.text.color)
                Text(
                    app: participant.accepted
                        ? "pairing.participantJoined" : "pairing.participantInvited"
                )
                .font(TypeLevel.label.font)
                .foregroundStyle(ColorRole.textMatt.color)
            }
            Spacer(minLength: Metrics.targetSpacing)
            Button {
                Task { await flow.remove(participant) }
            } label: {
                Text(app: "pairing.remove")
            }
            .buttonStyle(.quiet)
        }
        .padding(.horizontal, Metrics.cardInset)
        .frame(minHeight: Metrics.choiceRow)
    }

    /// Who that is: Apple's name, otherwise their devices, otherwise "joined via link" —
    /// the same order as in StoryShelf.
    private func participantTitle(_ participant: Participant) -> String {
        if let name = participant.name { return name }
        let devices = flow.deviceNames(from: participant)
        return devices.isEmpty
            ? AppLanguageSetting.text("pairing.participantLink") : devices.joined(separator: ", ")
    }

    // MARK: - The operation

    @ViewBuilder
    private var operation: some View {
        VStack(alignment: .leading, spacing: MetricsBoard.phone.gutter) {
            switch pairing?.state {
            case .shows(let code, let expiry):
                if page == .isFetching {
                    seeker
                } else {
                    codeImage(code: code, expiry: expiry)
                }
            case .arrived(let name, let device):
                // **The sentence fully translated and not as a key** (finding of
                // 2026-09-25): "pairing.arrived \(name) \(geraet)" as a `String` yielded the
                // key "pairing.arrived Alex iPhone", which the catalog does not know — the raw key
                // stood on screen.
                finish(
                    String(
                        format: SettingsModel.text("pairing.arrived %@ %@"), name, device),
                    icon: Glyph.done.pair.filled)
            case .pickedUp:
                finish(
                    page == .isFetching ? "pairing.handed" : "pairing.picked",
                    icon: Glyph.done.pair.filled)
            case .expired:
                finish("pairing.expired", icon: Glyph.offline.name)
            case .error(let key):
                finish(key, icon: Glyph.offline.name)
            case .isRunning, .none:
                // **No scanner while an acceptance is already running** — reasoning at
                // ``ProfileKit/PairingModel/isProcessed``. A link from the system camera is
                // already the scan; a second reader in front of it would be a request to
                // repeat it.
                if page == .isFetching, pairing?.isProcessed != true {
                    seeker
                } else {
                    LoadingState(message: "pairing.working")
                }
            }
        }
        .padding(.top, MetricsBoard.phone.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// The camera — **a switch and not a second button.**
    ///
    /// What the read text triggers is decided by ``ProfileKit/PairingModel/scanned(_:offering:now:)``
    /// from the role in the code. The profile that this device would hand out stands as a sentence below
    /// — otherwise nobody would know what they are about to give away.
    private var seeker: some View {
        VStack(alignment: .leading, spacing: MetricsBoard.phone.gutter) {
            Text(app: "pairing.scanText")
                .font(TypeLevel.footer.font)
                .foregroundStyle(ColorRole.textMatt.color)
                .fixedSize(horizontal: false, vertical: true)

            QRScanner(read: scanned)
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity)

            if let profile {
                Text(app: "pairing.wouldGive \(profile.name)")
                    .font(TypeLevel.footer.font)
                    .foregroundStyle(ColorRole.textMatt.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, MetricsBoard.phone.margin)
    }

    /// The QR that a second phone or an iPad scans.
    private func codeImage(code: String, expiry: Date) -> some View {
        VStack(alignment: .leading, spacing: MetricsBoard.phone.gutter) {
            Text(app: "pairing.giveSteps")
                .font(TypeLevel.footer.font)
                .foregroundStyle(ColorRole.textMatt.color)
                .fixedSize(horizontal: false, vertical: true)

            if let url = pairing?.qr, let image = Self.render(url.absoluteString) {
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 260)
                    .padding(14)
                    // systemfarbe: A QR is read by a camera and not
                    // looked at. White is here not a design means but the
                    // background that the reading algorithm expects — on a dark
                    // surface the contrast flips, and the code becomes unreadable.
                    .background(
                        Color.white, in: RoundedRectangle(cornerRadius: MetricsBoard.phone.fieldRadius)
                    )
                    .frame(maxWidth: .infinity)
                    .accessibilityHidden(true)
            }

            Text(verbatim: SharingFlow.readable(code))
                .font(TypeLevel.footer.font.monospaced())
                .foregroundStyle(ColorRole.text.color)
                .frame(maxWidth: .infinity)

            HStack(spacing: 8) {
                Text(app: "pairing.validFor")
                Text(timerInterval: Date()...max(Date(), expiry), countsDown: true)
            }
            .font(TypeLevel.footer.font)
            .foregroundStyle(ColorRole.textMatt.color)
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, MetricsBoard.phone.margin)
        .task(id: code) { await pairing?.run() }
    }

    private func finish(_ message: String, icon: String) -> some View {
        ZStack(alignment: .bottom) {
            StateBlock(
                form: .job(
                    Job(
                        icon: icon, headline: "pairing.title", message: message,
                        button: "common.done", target: .retry))
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            FloatingBar {
                Button(action: back) {
                    Text(app: "common.done").frame(maxWidth: .infinity)
                }
                .buttonStyle(.loud)
            }
        }
    }

    // MARK: - Helpers

    private func scanned(_ text: String) {
        Task { await flow.scanned(text) }
    }

    private func back() {
        Task { await flow.back() }
    }

    /// Leave — **afterwards a different profile is in front**, and the page applies to it.
    private func leave() async {
        guard await flow.leave() else { return }
        flow = Self.flow(cloud: cloud, store: store)
        await flow.loadSharing()
    }

    // MARK: - Drawing

    /// A QR from CoreImage — black on white, **without smoothing.**
    ///
    /// A smoothed edge is no longer an edge for a camera; the code from the screen
    /// of the neighbouring device is exactly the case in which that shows.
    static func render(_ text: String) -> CGImage? {
        #if canImport(CoreImage)
            let filter = CIFilter.qrCodeGenerator()
            filter.message = Data(text.utf8)
            filter.correctionLevel = "M"
            guard let output = filter.outputImage else { return nil }
            let large = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
            return CIContext().createCGImage(large, from: large.extent)
        #else
            return nil
        #endif
    }
}
