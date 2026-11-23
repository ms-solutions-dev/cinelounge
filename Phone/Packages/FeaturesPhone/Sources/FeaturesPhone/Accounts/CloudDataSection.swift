import DesignSystemPhone
import Flows
import SwiftUI

/// **"Delete all my iCloud data"** on the phone (on-device test build 1332, finding 10) —
/// the same flow as on the TV (``Flows/CloudDataDeletion``).
///
/// **Under the accounts and not in diagnostics:** it concerns a person's data, not
/// troubleshooting. **With a confirmation that says what happens** — all devices, shared
/// profiles stay, cannot be undone. The explanation also stands below the
/// row, so that nobody has to tap first to learn what it does.
struct CloudDataSection: View {

    @State private var flow = CloudDataDeletion()
    @State private var asks = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                asks = true
            } label: {
                HStack(spacing: MetricsBoard.phone.gutter) {
                    Image(systemName: Glyph.remove.name)
                        .foregroundStyle(ColorRole.textMatt.color)
                        .frame(width: 22)
                    Text(app: "profiles.icloudDelete")
                        .font(TypeLevel.text.font)
                        .foregroundStyle(ColorRole.text.color)
                    Spacer(minLength: 0)
                    if flow.state == .isRunning { ProgressView() }
                }
                .padding(.horizontal, MetricsBoard.phone.margin)
                .frame(minHeight: Metrics.choiceRow)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(flow.state == .isRunning)

            if let message = Self.message(flow.state) {
                Text(appKey: message)
                    .font(TypeLevel.label.font)
                    .foregroundStyle(ColorRole.text.color)
                    .padding(.horizontal, MetricsBoard.phone.margin)
                    .padding(.bottom, MetricsBoard.phone.gutter)
            }
            Footnote(message: "profiles.icloudDelete.text")
        }
        .confirmationDialog(
            Text(app: "profiles.icloudDelete.confirm"), isPresented: $asks,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                Task { await flow.delete() }
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

    /// The sentence below the row — `nil` as long as nothing has happened.
    static func message(_ state: CloudDataDeletion.State) -> String? {
        switch state {
        case .ready: nil
        case .isRunning: "profiles.icloudDelete.running"
        case .done: "profiles.icloudDelete.done"
        case .failed(let message): message
        }
    }
}
