import Core
import DesignSystemPhone
import Flows
import ProfileKit
import SwiftUI

/// **Device PIN forgotten — the same two ways as on the TV** (G3, finding B8).
///
/// **Until G3, the Jellyfin password of an account without an age limit unlocked it here.**
/// That was a third way alongside the TV's two, and it depended on a media server: a
/// household with only channel lists or portals had no way out at all, and neither did a
/// profile without its own account — selectable on the phone since G3. Now the shared
/// ``Flows/PinRecoveryFlow`` applies on both devices:
///
/// * **Confirm on the other device.** The request lives in the household zone and wakes every
///   device on the same Apple ID; whoever confirms there (behind that device's PIN) lifts the
///   lock here immediately.
/// * **Without another device, after 24 hours.** The waiting period is announced, visible and
///   cancellable — also from another device.
///
/// **The clock is the server's** (``ProfileKit/PINFallback``); the display may use the device time,
/// the decision is made there. **Without an Apple account there is no way out**, as on the
/// TV — the door then does not offer it at all (``LockedDoor``). And the PIN still
/// survives a reinstall: "delete the app" would be found in five seconds.
struct PinForgottenView: View {

    @State private var flow: PinRecoveryFlow
    @State private var asksToReset = false

    /// The way out has resolved — the wrapper deletes the PIN and leads into parental controls
    /// (``ShellModel/unlocked()``).
    let unlocked: () -> Void

    init(cloud: ProfileCloud, unlocked: @escaping () -> Void) {
        _flow = State(initialValue: PinRecoveryFlow(cloud: cloud, lock: .parentalControls))
        self.unlocked = unlocked
    }

    var body: some View {
        ZStack {
            ColorRole.reason.color.ignoresSafeArea()

            ScrollSurface {
                VStack(alignment: .leading, spacing: 0) {
                    Footnote(message: "childLock.forgot.hint")

                    switch flow.state {
                    case .none:
                        routes
                    case .wartetAufServer:
                        section("childLock.forgot.running", hint: "childLock.forgot.waitingServer") {
                            cancel
                        }
                    case .isRunning(let due, let device):
                        running(due: due, device: device)
                    case .due, .confirmed:
                        section("childLock.forgot.ready", hint: "childLock.forgot.readyHint") {
                            Button {
                                Task { if await flow.redeem() { unlocked() } }
                            } label: {
                                Text(app: "childLock.forgot.unlock")
                            }
                            .buttonStyle(.loud)
                            cancel
                        }
                    }

                    HintRow(
                        icon: Glyph.info.name, title: "childLock.forgot.delete",
                        message: "childLock.forgot.delete.text")
                }
                .padding(.top, MetricsBoard.phone.gutter)
            }
        }
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

    /// **No separate "Send" button.** The request *is* the message: as soon as it is in the
    /// zone, the silent push wakes every device on this Apple ID. The same request starts the
    /// waiting period — the two ways differ in what you wait for.
    @ViewBuilder
    private var routes: some View {
        section("childLock.forgot.otherDevice", hint: "childLock.forgot.otherDeviceHint") {
            Button(action: flow.request) {
                Text(app: "childLock.forgot.ask")
            }
            .buttonStyle(.loud)
        }
        section("childLock.forgot.noDevice", hint: "childLock.forgot.noDeviceHint") {
            Button {
                asksToReset = true
            } label: {
                Text(app: "childLock.forgot.reset")
            }
            .buttonStyle(.quiet)
        }
    }

    private func running(due: Date, device: String) -> some View {
        section("childLock.forgot.running", hint: "childLock.forgot.runningHint") {
            HStack(spacing: 8) {
                Text(app: "childLock.forgot.remaining")
                // **The display may use the device time** — it is information, not a decision.
                Text(timerInterval: Date()...max(Date(), due), countsDown: true)
                    .monospacedDigit()
            }
            .font(TypeLevel.header.font)
            .foregroundStyle(ColorRole.text.color)
            Text(verbatim: SettingsModel.text("childLock.forgot.askedBy %@", device))
                .font(TypeLevel.footer.font)
                .foregroundStyle(ColorRole.textMatt.color)
            cancel
        }
    }

    private var cancel: some View {
        Button(action: flow.cancel) {
            Text(app: "common.cancel")
        }
        .buttonStyle(.quiet)
    }

    // MARK: - Building blocks

    private func section<Content: View>(
        _ title: String, hint: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: MetricsBoard.phone.gutter) {
            SectionHeader(title: title)
            Footnote(message: hint)
            VStack(alignment: .leading, spacing: MetricsBoard.phone.gutter) {
                content()
            }
            .padding(.horizontal, MetricsBoard.phone.margin)
        }
        .padding(.bottom, MetricsBoard.phone.section)
    }
}
