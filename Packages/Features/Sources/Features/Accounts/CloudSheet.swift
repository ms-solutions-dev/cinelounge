import CloudSync
import Core
import DesignSystem
import Flows
import ProfileKit
import SwiftUI

/// "Devices & Sharing" — **bringing a profile to another device, and the revocation
/// as well** (AP44).
///
/// **Three things in one place, because they are the same process in three states:**
/// hand over, fetch, and see who is reading along. Three buttons in the profile list would be three
/// more targets on a screen that already has five — and from three meters away you
/// then hit the wrong one.
///
/// **The TV has no camera, and that is why it shows a code in both directions.** What the
/// scanner does with it is stated in the code itself (``ProfileKit/Pairing/Role``):
/// "I have the profile" means fetch, "I would like one" means drop off. The raw
/// sharing link is **never** on screen — it does not expire, and "Valid for 5 minutes"
/// below it would be a promise nobody keeps. What expires is the one-time code
/// before it.
///
/// **The participant list is not an extra.** An accepted link stays valid until
/// someone revokes it; without this list, sharing would be a process with no way back. What
/// CloudKit reveals about a participant is **nothing** when the share goes through the link
/// — that is why it says "joined via the code" and no invented name.
struct CloudSheet: View {

    /// `nil` means: here we only fetch — the second way behind the "+" card in "Who's
    /// watching?" (AP45, product decision 3 of 2026-09-25). The `.isSearching` page needs
    /// no profile; attaching it behind an active one would mean demanding a fetch that only
    /// exists when one is already there.
    let profile: Profile?
    let cloud: ProfileCloud
    /// Called on close — the profile list has to reread, one may have
    /// been added or removed.
    var onClose: () -> Void = {}

    /// **Pages, sharing and revocation are driven by ``Flows/SharingFlow``** (AP58 R2) —
    /// the same flow as on the phone; here the TV fetches with a code
    /// (``Flows/SharingFlow/PullMode/code``) because it has no camera.
    @State private var flow: SharingFlow
    @State private var asksToEnd = false
    @State private var asksToLeave = false
    /// The device that is currently being renamed, and the name in the field.
    @State private var rename: DeviceEntry?
    @State private var newName = ""
    @FocusState private var focus: String?

    init(profile: Profile?, cloud: ProfileCloud, onClose: @escaping () -> Void = {}) {
        self.profile = profile
        self.cloud = cloud
        self.onClose = onClose
        _flow = State(initialValue: SharingFlow(profile: profile, cloud: cloud, pullMode: .code))
    }

    /// Without a profile it goes straight to the code page, and "back" closes instead of returning to the overview.
    private var isPullOnly: Bool { flow.isPullOnly }
    private var page: SharingFlow.Page { flow.page }
    private var pairing: PairingModel? { flow.pairing }
    private var approval: AccessGrant? { flow.approval }
    private var error: String? { flow.error }
    private var isBorrowed: Bool { flow.isBorrowed }
    private var sharedBy: String? { flow.sharedBy }

    var body: some View {
        ZStack {
            ColorRole.reason.color.ignoresSafeArea()

            Group {
                switch page {
                case .overview: if isPullOnly { Color.clear } else { overview }
                case .gives, .isFetching: codePage
                }
            }
            .padding(50)
            .frame(maxWidth: 1100, alignment: .leading)
        }
        .onExitCommand(perform: back)
        .task {
            if isPullOnly, page == .overview {
                flow.start(.isFetching)
            } else {
                await flow.loadSharing()
            }
        }
        .alert(
            Text(app: "pairing.renameDevice"),
            isPresented: Binding(get: { rename != nil }, set: { if !$0 { rename = nil } })
        ) {
            TextField(text: $newName) { Text(app: "pairing.deviceName") }
                .keyboard(forItem: .prose)
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
            Text(app: "pairing.endConfirm"), isPresented: $asksToEnd, titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                Task { await flow.finish() }
            } label: {
                Text(app: "pairing.end")
            }
            Button(role: .cancel) {
            } label: {
                Text(app: "common.cancel")
            }
        } message: {
            Text(app: "pairing.endHint")
        }
        .confirmationDialog(
            Text(app: "pairing.leaveConfirm"), isPresented: $asksToLeave,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                Task { if await flow.leave() { onClose() } }
            } label: {
                Text(app: "pairing.leave")
            }
            Button(role: .cancel) {
            } label: {
                Text(app: "common.cancel")
            }
        } message: {
            Text(app: "pairing.leaveHint")
        }
    }

    // MARK: - Overview

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SettingsHeader("pairing.title", hint: "pairing.hint")

                if let error {
                    report(error)
                }

                if isBorrowed {
                    borrowedSection
                } else {
                    ownSection
                }

                button("common.done", identifier: "fertig", action: back)
                    .padding(.top, 34)
            }
        }
    }

    /// A profile that belongs to this account: hand over, fetch, participants.
    @ViewBuilder
    private var ownSection: some View {
        section("pairing.give", hint: "pairing.giveHint") {
            button("pairing.giveAction", identifier: "geben") { flow.start(.gives) }
        }

        section("pairing.get", hint: "pairing.getHint") {
            button("pairing.getAction", identifier: "holen") { flow.start(.isFetching) }
        }

        deviceSection

        section("pairing.participants", hint: "pairing.participantsHint") {
            participantList
        }
    }

    /// Where this profile runs — **newest first, this device marked** (2026-10-01,
    /// after StoryShelf's "iCloud & Devices"). A press renames.
    private var deviceSection: some View {
        section("pairing.devices", hint: "pairing.devicesHint") {
            if flow.devices.isEmpty {
                Text(app: "pairing.devicesEmpty")
                    .font(TypeLevel.footer.font)
                    .foregroundStyle(ColorRole.textMatt.color)
            } else {
                ForEach(flow.devices) { device in
                    deviceRow(device)
                }
            }
        }
    }

    /// From the ``DisclosureRow`` building block and not by hand — it leads to renaming, and the
    /// value column says what one would otherwise only see in the sheet: model and "last …".
    private func deviceRow(_ device: DeviceEntry) -> some View {
        let thisDevice = device.identifier == flow.thisDevice
        return DisclosureRow(
            wording: thisDevice
                ? device.name + " · " + AppLanguageSetting.text("pairing.deviceThis") : device.name,
            value: Self.deviceDetail(device),
            identifier: "geraet-\(device.identifier)",
            focus: $focus
        ) {
            newName = device.name
            rename = device
        }
    }

    /// „Apple TV · zuletzt 30.09.2026, 20:14“.
    static func deviceDetail(_ device: DeviceEntry) -> String {
        let when = device.recent.formatted(date: .abbreviated, time: .shortened)
        return [device.model, AppLanguageSetting.text("pairing.deviceSeen \(when)")]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    /// Who that is: Apple's name, otherwise their devices, otherwise "joined via link".
    private func participantTitle(_ participant: Participant) -> String {
        if let name = participant.name { return name }
        let devices = flow.deviceNames(from: participant)
        return devices.isEmpty
            ? AppLanguageSetting.text("pairing.participantLink") : devices.joined(separator: ", ")
    }

    @ViewBuilder
    private var participantList: some View {
        if let approval, !approval.invited.isEmpty {
            ForEach(approval.invited) { participant in
                participantRow(participant)
            }
            button("pairing.end", identifier: "beenden") { asksToEnd = true }
                .padding(.top, 18)
        } else {
            Text(app: "pairing.participantsEmpty")
                .font(TypeLevel.footer.font)
                .foregroundStyle(ColorRole.textMatt.color)
        }
    }

    /// One row per participant — **and a long press removes them.**
    ///
    /// The same rule as in the profile list: no second target in the row. From three
    /// meters away the wrong target here would be locking someone out.
    private func participantRow(_ participant: Participant) -> some View {
        let identifier = "teilnehmer-\(participant.identifier)"
        return Button {
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 20) {
                Text(verbatim: participantTitle(participant))
                    .frame(width: 420, alignment: .leading)
                    .lineLimit(1)
                Text(
                    app: participant.accepted ? "pairing.participantJoined" : "pairing.participantInvited"
                )
                .foregroundStyle(ColorRole.textMatt.color)
                Spacer(minLength: 0)
                Text(app: "pairing.removeHint")
                    .foregroundStyle(ColorRole.textQuiet.color)
            }
            .font(TypeLevel.footer.font)
            .settingsFont(isFocused: focus == identifier)
            .settingsSurface(.readingRow, isFocused: focus == identifier, reason: .clear)
        }
        .bareFocusableButton()
        .focused($focus, equals: identifier)
        .onLongPressGesture {
            Task { await flow.remove(participant) }
        }
    }

    /// A profile that belongs to someone else: only the way out.
    @ViewBuilder
    private var borrowedSection: some View {
        section("pairing.shared", hint: "pairing.sharedHint") {
            Text(app: "pairing.sharedBy \(sharedBy ?? "—")")
                .font(TypeLevel.text.font)
                .foregroundStyle(ColorRole.text.color)
                .padding(.bottom, 18)
            button("pairing.leave", identifier: "verlassen") { asksToLeave = true }
        }

        deviceSection
    }

    // MARK: - The code page

    @ViewBuilder
    private var codePage: some View {
        VStack(alignment: .leading, spacing: 30) {
            Text(appKey: page == .gives ? "pairing.give" : "pairing.getTitle")
                .font(TypeLevel.section.font)
                .foregroundStyle(ColorRole.text.color)

            switch pairing?.state {
            case .shows(let code, let until):
                codeImage(code: code, until: until)
            case .arrived(let name, let device):
                done("pairing.arrived \(name) \(device)")
            case .pickedUp:
                done("pairing.picked")
            case .expired:
                retry("pairing.expired")
            case .error(let key):
                retry(key)
            case .isRunning, .none:
                Text(app: "pairing.working")
                    .font(TypeLevel.text.font)
                    .foregroundStyle(ColorRole.textMatt.color)
            }

            button("common.done", identifier: "zurueck", action: back)
        }
    }

    /// The QR and the code below it.
    ///
    /// **The code is shown as text although nobody is meant to type it.** A camera
    /// that does not cooperate is not a rare case — an oblique angle, a
    /// reflective pane, a TV that is set too bright. Sixteen characters are
    /// tedious, and tedious is better than a dead end.
    private func codeImage(code: String, until: Date) -> some View {
        HStack(alignment: .top, spacing: 40) {
            if let url = pairing?.qr, let image = QRCode.image(for: url.absoluteString) {
                image
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 320, height: 320)
                    .padding(20)
                    // systemfarbe: a QR is read by a camera and not by the eye —
                    // it needs the brightest border there is, in every color scheme.
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 18))
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 18) {
                Text(appKey: page == .gives ? "pairing.giveSteps" : "pairing.getSteps")
                    .font(TypeLevel.text.font)
                    .foregroundStyle(ColorRole.textMatt.color)
                    .fixedSize(horizontal: false, vertical: true)

                // When handing over, the QR carries the link itself (``ProfileKit/ProfileLink``) — then
                // there is no code to type.
                if !code.isEmpty {
                    Text(verbatim: SharingFlow.readable(code))
                        .font(TypeLevel.section.font.monospaced())
                        .foregroundStyle(ColorRole.text.color)
                }

                HStack(spacing: 10) {
                    Text(app: "pairing.validFor")
                    // **Never a reversed range** (crash 2026-09-28, twice): if the
                    // sheet stayed open past the deadline, `Date()` was greater than `until`,
                    // and `...` then aborts hard.
                    let now = Date()
                    Text(timerInterval: now...max(now, until), countsDown: true)
                }
                .font(TypeLevel.footer.font)
                .foregroundStyle(ColorRole.textQuiet.color)
            }
            .frame(maxWidth: 520, alignment: .leading)
        }
        .task(id: code) { await pairing?.run() }
    }

    private func done(_ key: String) -> some View {
        Text(appKey: key)
            .font(TypeLevel.text.font)
            .foregroundStyle(ColorRole.text.color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 900, alignment: .leading)
    }

    private func retry(_ key: String) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            report(key)
            button("pairing.again", identifier: "nochmal") { flow.start(page) }
        }
    }

    private func report(_ key: String) -> some View {
        Text(appKey: key)
            .font(TypeLevel.text.font)
            .foregroundStyle(ColorRole.progress.color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 900, alignment: .leading)
            .padding(.bottom, 24)
    }

    // MARK: - Building blocks

    private func section<Content: View>(
        _ title: String, hint: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(appKey: title)
                .font(TypeLevel.section.font)
                .foregroundStyle(ColorRole.text.color)
            Text(appKey: hint)
                .font(TypeLevel.footer.font)
                .foregroundStyle(ColorRole.textMatt.color)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 900, alignment: .leading)
            content()
        }
        .padding(.bottom, 40)
        // One section per block: jumping from one to the next should not land in the
        // middle of a participant list.
        .focusSection()
    }

    private func button(
        _ key: String, identifier: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(appKey: key)
                .font(TypeLevel.footer.font)
                .settingsFont(isFocused: focus == identifier)
                .settingsSurface(.pill, isFocused: focus == identifier)
        }
        .bareFocusableButton()
        .focused($focus, equals: identifier)
    }

    // MARK: - Helpers

    /// Back — **and the mailbox is emptied in the process** (``Flows/SharingFlow/back()``).
    private func back() {
        Task { if await flow.back() { onClose() } }
    }
}
