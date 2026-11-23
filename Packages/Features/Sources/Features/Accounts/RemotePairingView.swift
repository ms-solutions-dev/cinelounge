import DesignSystem
import Foundation
import SecondScreen
import SwiftUI

/// The TV shows a pairing code for the remote (decision 6,
/// 2026-09-25).
///
/// **The same clock as with the handoff:** A code is valid for three minutes and once; when it
/// expires, a new one is immediately put up. The difference is what remains afterwards — here a
/// paired phone that from now on identifies itself on every connection.
@Observable
final class RemotePairingModel {

    private(set) var key: HandoffKey?
    private(set) var remainingTime: TimeInterval = 0
    /// The phone that paired last — for the confirmation on screen.
    private(set) var paired: String?
    private(set) var phones: [RemotePairingLedger.Phone] = []

    private let controller: RemoteControl
    /// The clock under the code — ``SecondScreen/CodeClock``, the same as with the handoff.
    private let clock = CodeClock()

    init(controller: RemoteControl = .shared) {
        self.controller = controller
    }

    func begin() {
        phones = controller.phones
        let new = controller.openPairing { [weak self] phone in
            Task { @MainActor in self?.take(phone) }
        }
        key = new
        remainingTime = new.remainingTime()
        clock.run(
            forItem: new,
            tick: { [weak self] rest in self?.remainingTime = rest },
            expired: { [weak self] in self?.begin() })
    }

    func stopListening() {
        clock.hold()
        controller.closePairing()
    }

    func forget(_ phone: RemotePairingLedger.Phone) {
        controller.forget(phone)
        phones = controller.phones
    }

    /// **After a pairing a new code is put up immediately** — the old one is used up,
    /// and a second phone should not aim at a code that no longer applies.
    private func take(_ phone: RemotePairingLedger.Phone) {
        paired = phone.name
        begin()
    }

    /// The text in the QR code — **under the scheme of the remote**, so that the phone
    /// does not start a handoff.
    nonisolated static func text(_ key: HandoffKey) -> String {
        key.asText(schema: RemotePairing.schema)
    }
}

/// "iPhone as remote" — code, clock and the paired phones.
public struct RemotePairingView: View {

    @State private var model = RemotePairingModel()
    @FocusState private var focus: String?
    let close: () -> Void

    public init(close: @escaping () -> Void) {
        self.close = close
    }

    public var body: some View {
        ZStack {
            ColorRole.reason.color.ignoresSafeArea()
            HStack(alignment: .top, spacing: 80) {
                codeColumn
                phoneColumn
            }
            .padding(.horizontal, MetricsBoard.tv.margin)
            .padding(.vertical, TVMetrics.topMargin)
        }
        .task { model.begin() }
        .onDisappear { model.stopListening() }
    }

    private var codeColumn: some View {
        VStack(spacing: 26) {
            Text("remote.pair.title")
                .font(TypeLevel.title.font)
                .foregroundStyle(ColorRole.text.color)
            Text("remote.pair.text")
                .font(TypeLevel.footer.font)
                .foregroundStyle(ColorRole.textMatt.color)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 720)

            if let key = model.key,
                let image = HandoffReceiveView.render(RemotePairingModel.text(key))
            {
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 360, height: 360)
                    .padding(28)
                    .background(.white, in: RoundedRectangle(cornerRadius: 16))
                Text(verbatim: key.target)
                    .font(TypeLevel.footer.font)
                    .foregroundStyle(ColorRole.textQuiet.color)
                    .kerning(2)
                Text("handover.tv.validFor \(Int(model.remainingTime.rounded()))")
                    .font(TypeLevel.footer.font)
                    .foregroundStyle(ColorRole.textQuiet.color)
                    .monospacedDigit()
            }
            if let name = model.paired {
                Label {
                    Text("remote.pair.done \(name)")
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                }
                .font(TypeLevel.text.font)
                .foregroundStyle(ColorRole.brandLight.color)
            }
            Button(action: close) { Text(app: "common.done") }
                .focused($focus, equals: "schliessen")
        }
        .frame(maxWidth: .infinity)
    }

    private var phoneColumn: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("remote.pair.phones")
                .font(TypeLevel.footer.font)
                .kerning(3)
                .foregroundStyle(ColorRole.textQuiet.color)
            if model.phones.isEmpty {
                Text("remote.pair.none")
                    .font(TypeLevel.text.font)
                    .foregroundStyle(ColorRole.textMatt.color)
            }
            ForEach(model.phones) { phone in
                Button {
                    model.forget(phone)
                } label: {
                    HStack(spacing: 14) {
                        Text(verbatim: phone.name)
                        Spacer(minLength: 20)
                        Text(app: "remote.pair.forget")
                            .foregroundStyle(ColorRole.textMatt.color)
                    }
                    .font(TypeLevel.text.font)
                }
                .focused($focus, equals: "telefon-" + phone.id)
            }
        }
        .frame(width: 620, alignment: .leading)
    }
}
