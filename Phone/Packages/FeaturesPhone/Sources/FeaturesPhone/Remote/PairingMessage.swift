import Foundation
import SecondScreen

/// The wire, **over which one can also pair** — ``SecondScreen/OwnWire`` in operation.
///
/// ``SecondScreen/ControlPath`` knows only connect, disconnect and send; pairing via QR
/// has existed since 2026-09-25 (decision 6, `RemotePairing`) only on the own wire. A
/// protocol of its own here, so that the checks can inject a stand-in that
/// plays back the pairing without going on the network.
public protocol PairingRoute: ControlPath {
    func pair(using key: HandoffKey) async throws
}

extension OwnWire: PairingRoute {}

/// What the phone says when the TV refuses the pairing — **one sentence per error
/// and a next step.**
///
/// **The five cases from ``SecondScreen/RemotePairing/TestError``** (tvOS roadmap, row
/// "Counter-check workstream D"):
///
/// * `.unpaired` — the TV has **demonstrably** forgotten this phone; the wire has
///   already deleted the credential. Next step: on the TV open "iPhone as remote"
///   and scan.
/// * `.dismissed` — an **unfounded** rejection. Only a notice; **the credential stays**,
///   because anyone on the home network can send a rejection without proof. Since TV `main`
///   `f8da11f` (workstream E, D2-1) it also means "no room", and when pairing
///   the code is then not used up — so **Reconnect** is offered first, scanning
///   only after that.
/// * `.pairingRejected` — the code had expired or was already used.
/// * `.tvTooOld` — the TV does not speak the pairing.
/// * `.unreadable` — something arrived garbled; pair again.
public struct PairingMessage: Equatable, Sendable {

    /// What is offered next.
    public enum Step: Equatable, Sendable {
        /// Den QR-Code am Fernseher scannen.
        case scan
        /// Repeat the same attempt — and scanning as a second way.
        case reconnect
        /// Offer nothing except the notice.
        case none
    }

    public let title: String
    public let message: String
    public let step: Step

    /// The message for an error — `nil` if it is not a pairing error (then it is
    /// a network fault and has its own state).
    public static func zu(_ error: any Error) -> PairingMessage? {
        guard let error = error as? RemotePairing.TestError else { return nil }
        return switch error {
        case .unpaired:
            PairingMessage(
                title: "remote.pairing.unpaired", message: "remote.pairing.unpairedText",
                step: .scan)
        case .dismissed:
            PairingMessage(
                title: "remote.pairing.refused", message: "remote.pairing.refusedText",
                step: .reconnect)
        case .pairingRejected:
            PairingMessage(
                title: "remote.pairing.codeInvalid", message: "remote.pairing.codeInvalidText",
                step: .scan)
        case .tvTooOld:
            PairingMessage(
                title: "remote.pairing.tvTooOld", message: "remote.pairing.tvTooOldText",
                step: .none)
        case .unreadable:
            PairingMessage(
                title: "remote.pairing.unreadable", message: "remote.pairing.unreadableText",
                step: .scan)
        }
    }
}
