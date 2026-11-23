import DesignSystem
import Flows
import ParentalControls
import SwiftUI

/// **"Delete all my iCloud data"** on the TV (on-device test build 1332, finding 10) —
/// the same flow as on the phone (``Flows/CloudDataDeletion``).
///
/// **Behind the door `accounts`**, like removing a profile: it removes all of them, on all
/// devices. **The explanation is above the button** and once more in the confirmation — from three
/// meters away nobody likes to read a confirmation they did not expect.
struct CloudDataSection: View {

    @ObservedObject var lock: ParentalControlsState
    /// Called after the deletion — the list above rereads the ledger.
    let following: () -> Void

    @State private var flow = CloudDataDeletion()
    @State private var asks = false
    @FocusState private var focus: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(app: "profiles.icloudDelete.text")
                .font(TypeLevel.footer.font)
                .foregroundStyle(ColorRole.textQuiet.color)
                .frame(maxWidth: 1100, alignment: .leading)
            ActionRow(
                title: "profiles.icloudDelete",
                state: Self.actionState(flow.state),
                warning: true,
                identifier: "icloudDelete",
                focus: $focus
            ) {
                guard lock.isAllowed(finished: "konten") else { return }
                asks = true
            }
            .frame(maxWidth: 1100, alignment: .leading)
            if let message = Self.message(flow.state) {
                Text(appKey: message)
                    .font(TypeLevel.footer.font)
                    .foregroundStyle(ColorRole.text.color)
                    .frame(maxWidth: 1100, alignment: .leading)
            }
        }
        .padding(.top, 40)
        .confirmationDialog(
            Text(app: "profiles.icloudDelete.confirm"), isPresented: $asks,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                Task {
                    await flow.delete()
                    following()
                }
            } label: {
                Text(app: "profiles.icloudDelete.do")
            }
            Button(role: .cancel) {
            } label: {
                Text(app: "common.cancel")
            }
        } message: {
            Text(app: "profiles.icloudDelete.text")
        }
    }

    /// The state of the row.
    ///
    /// **Via ``ActionRow`` and not as a button of its own:** a disabled button during
    /// the deletion would lose focus on tvOS, and the focus would jump somewhere in the
    /// middle of the process (``EinstellungenFokusbaumTests``). The building block discards the second
    /// press in its body and stays focusable.
    static func actionState(_ state: CloudDataDeletion.State) -> ActionState {
        switch state {
        case .ready, .failed: .ready
        case .isRunning: .isRunning
        case .done: .done
        }
    }

    /// The sentence under the button — `nil` as long as nothing has happened.
    static func message(_ state: CloudDataDeletion.State) -> String? {
        switch state {
        case .ready: nil
        case .isRunning: "profiles.icloudDelete.running"
        case .done: "profiles.icloudDelete.done"
        case .failed(let message): message
        }
    }
}
