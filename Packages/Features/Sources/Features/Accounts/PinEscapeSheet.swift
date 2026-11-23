import Core
import DesignSystem
import Flows
import ProfileKit
import SwiftUI

/// "Forgot PIN" on the TV — **two ways, and the second costs a day** (AP43).
///
/// **Without a way out a lock is not a lock but a trap.** On the phone there has long been
/// one via the account password at Jellyfin; on the TV there was none — the
/// PIN lives in the Keychain and comes back from the iCloud backup, even after
/// reinstalling.
///
/// **The fast way stands on top and the slow one below**, and the order is the
/// recommendation: Whoever has a second device is through in ten seconds. The waiting period is for
/// someone who has none — and it is deliberately inconvenient.
///
/// **The waiting period also stands on the PIN sheet itself** (``PinDeadlineRow``) and not only
/// behind this button. A reset that only shows up for whoever looks for it is never noticed by
/// the parent — and they are exactly the one who should be able to cancel it.
///
/// **Reading, requesting, cancelling and releasing are driven by ``Flows/PinRecoveryFlow``** (AP58 R2) —
/// the same flow as on the phone: first sync, then read, and only what is
/// freshly read as due or confirmed is released. Until then this sheet read the mirror
/// synchronously and showed "waiting" where a second device had long since confirmed.
///
/// **What this sheet cannot do: shorten the waiting period.** A child sits out an hour;
/// few survive twenty-four, and whoever really needs the way out has it
/// the next evening.
struct PinEscapeSheet: View {

    /// **What the way out applies to** (AP45, 2026-09-24) — the parental controls of the household
    /// or the PIN of a profile. No default: Which lock is meant is known only to the
    /// call site, and a wrong guess would put the waiting period on the wrong lock.
    var lock: PINFallback.Lock { flow.lock }

    /// Called when the lock may fall — the caller deletes the PIN.
    let onRelease: () -> Void
    let onClose: () -> Void

    @State private var flow: PinRecoveryFlow
    @State private var asksToReset = false
    @FocusState private var focus: String?

    private let cloud: ProfileCloud

    init(
        cloud: ProfileCloud, lock: PINFallback.Lock, onRelease: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.cloud = cloud
        self.onRelease = onRelease
        self.onClose = onClose
        _flow = State(initialValue: PinRecoveryFlow(cloud: cloud, lock: lock))
    }

    var body: some View {
        ZStack {
            ColorRole.reason.color.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SettingsHeader("pin.forgot", hint: "childLock.forgot.hint")

                    switch flow.state {
                    case .none:
                        routes
                    case .wartetAufServer:
                        report("childLock.forgot.waitingServer")
                        cancel
                    case .isRunning(let due, let device):
                        running(due: due, device: device)
                    case .due, .confirmed:
                        ready
                    }

                    // **The open requests of the profiles, cancelable** (finding 6) — whoever presses
                    // "Forgot PIN" in front of the parental controls is the parent who
                    // has to see them too.
                    if lock == .parentalControls {
                        ProfileEscapeSection(cloud: cloud)
                    }

                    button("common.done", identifier: "fertig", action: onClose)
                        .padding(.top, 34)
                }
                .frame(maxWidth: 1100, alignment: .leading)
                .padding(.horizontal, MetricsBoard.tv.margin)
                .padding(.vertical, TVMetrics.topMargin)
            }
        }
        .onExitCommand(perform: onClose)
        .task { await flow.read() }
        .onReceive(NotificationCenter.default.publisher(for: .pinEscape)) { _ in
            Task { await flow.read() }
        }
        .confirmationDialog(
            Text(app: "childLock.forgot.resetConfirm"), isPresented: $asksToReset,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                flow.request()
            } label: {
                Text(app: "childLock.forgot.reset")
            }
            Button(role: .cancel) {
            } label: {
                Text(app: "common.cancel")
            }
        } message: {
            Text(app: "childLock.forgot.resetHint")
        }
    }

    // MARK: - The two ways

    @ViewBuilder
    private var routes: some View {
        section("childLock.forgot.otherDevice", hint: "childLock.forgot.otherDeviceHint") {
            // **No button of its own for "Send".** The request *is* the message: As soon as
            // it lies in the zone, the silent push wakes every device of this Apple ID.
            // A second button next to it would promise a second path that does not exist.
            button("childLock.forgot.ask", identifier: "fragen", action: flow.request)
        }

        section("childLock.forgot.noDevice", hint: "childLock.forgot.noDeviceHint") {
            button("childLock.forgot.reset", identifier: "zuruecksetzen") {
                asksToReset = true
            }
        }
    }

    @ViewBuilder
    private func running(due: Date, device: String) -> some View {
        section("childLock.forgot.running", hint: "childLock.forgot.runningHint") {
            HStack(spacing: 10) {
                Text(app: "childLock.forgot.remaining")
                // **The display may use the device time** — it is information and
                // not a decision. The computation is against the server's clock, see
                // ``ProfileKit/PINFallback``.
                Text(timerInterval: Date()...max(Date(), due), countsDown: true)
            }
            .font(TypeLevel.header.font)
            .foregroundStyle(ColorRole.text.color)

            Text(app: "childLock.forgot.askedBy \(device)")
                .font(TypeLevel.footer.font)
                .foregroundStyle(ColorRole.textMatt.color)
                .padding(.top, 6)

            cancel.padding(.top, 18)
        }
    }

    @ViewBuilder
    private var ready: some View {
        section("childLock.forgot.ready", hint: "childLock.forgot.readyHint") {
            button("childLock.forgot.unlock", identifier: "loesen") {
                Task { if await flow.redeem() { onRelease() } }
            }
            cancel.padding(.top, 14)
        }
    }

    private var cancel: some View {
        button("common.cancel", identifier: "zuruecknehmen", action: flow.cancel)
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
        .focusSection()
    }

    private func report(_ key: String) -> some View {
        Text(appKey: key)
            .font(TypeLevel.text.font)
            .foregroundStyle(ColorRole.progress.color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 900, alignment: .leading)
            .padding(.bottom, 24)
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

}

/// The row above the number pad when a reset is running.
///
/// **It belongs on the PIN sheet and not behind the button.** Whoever knows the PIN opens
/// the sheet and types — they would never think of looking under "Forgot PIN". A
/// reset that is only there is noticed by the parent only once it has gone through.
struct PinDeadlineRow: View {

    let state: PINFallback.State

    var body: some View {
        switch state {
        case .isRunning(let due, let device):
            row {
                HStack(spacing: 8) {
                    Text(app: "childLock.forgot.noticeRunning \(device)")
                    Text(timerInterval: Date()...max(Date(), due), countsDown: true)
                }
            }
        case .due(let device), .confirmed(let device):
            row { Text(app: "childLock.forgot.noticeReady \(device)") }
        case .none, .wartetAufServer:
            EmptyView()
        }
    }

    private func row<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .font(TypeLevel.footer.font)
            .foregroundStyle(ColorRole.progress.color)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 760)
    }
}
