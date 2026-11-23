import Core
import DesignSystemPhone
import Flows
import ParentalControls
import ProfileKit
import SwiftUI

/// Sheet: the profile PIN — **set, change, remove, and the latch before
/// switching** (tvOS roadmap AP52, product decision 12 of 2026-09-25).
///
/// **The same flow as `ProfilePinManagement` on the TV**, built from this phone's
/// number pad (``PinSheet``):
/// - **No PIN:** four digits, twice.
/// - **A PIN:** first the choice "Change" or "Remove", then the old one — with "Forgot
///   PIN" as a way out.
/// - **The latch:** the PIN of the target profile, otherwise no switch.
///
/// **"Forgot PIN" only with an Apple account.** Without the cloud there is no waiting period
/// and no second device that confirms; a button leading there would lead to a page that can
/// do nothing.
struct ProfilePinPanel: View {

    let state: ProfilePinState

    /// Check the PIN at the latch — `true` means: switched.
    let openLatch: (String) -> Bool
    /// The way out resolved at the latch.
    let latchReleased: () -> Void
    /// Done or cancelled.
    let done: () -> Void

    /// **The shared flow runs the steps** (``Flows/ProfilePinFlow``, AP58 R2) —
    /// the same as on the TV. Here stands only how the phone shows them.
    @State private var flow: ProfilePinFlow

    init(
        state: ProfilePinState, administration: ProfilePinManagement,
        openLatch: @escaping (String) -> Bool, latchReleased: @escaping () -> Void,
        done: @escaping () -> Void
    ) {
        self.state = state
        self.openLatch = openLatch
        self.latchReleased = latchReleased
        self.done = done
        _flow = State(initialValue: administration.flow(forItem: state))
    }

    private var profile: Profile { state.profile }

    private var recovery: (() -> Void)? {
        guard flow.recovery != nil else { return nil }
        return { flow.openRecovery() }
    }

    var body: some View {
        Group {
            switch flow.step {
            case .lock:
                PinSheet(
                    job: .door(identifier: ProfilePinManagement.door, reason: ""),
                    header: .profile(.lock, name: profile.name),
                    verifies: openLatch, sets: { _ in false }, forgotten: recovery,
                    succeeded: {})
            case .choice:
                choice
            case .oldPinForChange:
                PinSheet(
                    job: .door(identifier: ProfilePinManagement.door, reason: ""),
                    header: .profile(.change, name: profile.name),
                    verifies: { flow.acceptOld($0) != .wrong },
                    sets: { _ in false }, forgotten: recovery, succeeded: {})
            case .oldPinForRemoval:
                PinSheet(
                    job: .door(identifier: ProfilePinManagement.door, reason: ""),
                    header: .profile(.remove, name: profile.name),
                    verifies: { flow.acceptOld($0) == .removed },
                    sets: { _ in false }, forgotten: recovery, succeeded: done)
            case .fresh:
                PinSheet(
                    job: .assignPin, header: .profile(.set, name: profile.name),
                    verifies: { _ in false },
                    sets: { flow.set($0) == .isSet },
                    forgotten: nil, succeeded: done)
            case .recovery:
                fallbackPage
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ColorRole.surfaceHigh.color)
    }

    // MARK: - The choice

    private var choice: some View {
        SheetFrame(
            title: "profiles.pinManage",
            wording: nil,
            message: nil
        ) {
            Footnote(wording: SettingsModel.text("profiles.pinHint %@", profile.name))
            DisclosureRow(title: "pin.change", icon: Glyph.locked.name) {
                flow.chooseChange()
            }
            DisclosureRow(title: "profiles.pinRemove", icon: Glyph.remove.name) {
                flow.chooseRemoval()
            }
        }
    }

    // MARK: - PIN vergessen

    private var fallbackPage: some View {
        SheetFrame(
            title: "pin.forgot", wording: nil, message: nil,
            back: (SettingsModel.text("common.back"), { flow.back() })
        ) {
            Footnote(wording: SettingsModel.text("profiles.pinForgotHint %@", profile.name))
            VStack(alignment: .leading, spacing: MetricsBoard.phone.gutter) {
                switch flow.recovery?.state ?? .none {
                case .none:
                    button("childLock.forgot.ask", loud: true) {
                        flow.recovery?.request()
                    }
                case .wartetAufServer:
                    message("childLock.forgot.waitingServer")
                    cancel
                case .isRunning(let due, let device):
                    HStack(spacing: 8) {
                        Text(app: "childLock.forgot.remaining")
                        Text(timerInterval: Date()...max(Date(), due), countsDown: true)
                    }
                    .font(TypeLevel.text.font)
                    .foregroundStyle(ColorRole.text.color)
                    Text(verbatim: SettingsModel.text("childLock.forgot.askedBy %@", device))
                        .font(TypeLevel.footer.font)
                        .foregroundStyle(ColorRole.textMatt.color)
                    message("childLock.forgot.otherDeviceHint")
                    cancel
                case .due, .confirmed:
                    message("profiles.pinForgotReady")
                    button("childLock.forgot.unlock", loud: true) { Task { await redeem() } }
                    cancel
                }
            }
            .padding(.horizontal, MetricsBoard.phone.margin)
            .padding(.top, MetricsBoard.phone.gutter)
        }
        .task { await flow.recovery?.read() }
        .onReceive(NotificationCenter.default.publisher(for: .pinEscape)) { _ in
            Task { await flow.recovery?.read() }
        }
    }

    /// The waiting period is over or another device has confirmed — **the PIN is dropped
    /// household-wide**, and at the latch the switch continues
    /// (``Flows/ProfilePinFlow/redeemRecovery()``).
    private func redeem() async {
        guard await flow.redeemRecovery() else { return }
        switch state {
        case .lock: latchReleased()
        case .maintain: done()
        }
    }

    private var cancel: some View {
        button("common.cancel", loud: false) {
            flow.recovery?.cancel()
        }
    }

    private func message(_ key: String) -> some View {
        Text(appKey: key)
            .font(TypeLevel.footer.font)
            .foregroundStyle(ColorRole.textMatt.color)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func button(
        _ key: String, loud: Bool, action: @escaping () -> Void
    )
        -> some View
    {
        if loud {
            Button(action: action) {
                Text(appKey: key).frame(maxWidth: .infinity)
            }
            .buttonStyle(.loud)
        } else {
            Button(role: .destructive, action: action) {
                Text(appKey: key).frame(maxWidth: .infinity)
            }
            .buttonStyle(.quiet)
        }
    }
}
