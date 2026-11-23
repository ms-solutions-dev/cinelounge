import Core
import Foundation
import SecondScreen
import SwiftUI

/// The TV waits for a phone.
///
/// **The clock is the whole screen.** A QR code that stays on a TV
/// while nobody is in the room proves no proximity any more — it is a note on the
/// door. That is why every code is valid for three minutes (``HandoffKey/validity``), and
/// when they are up, this model creates a **new** one instead of leaving an expired one
/// standing. The viewer notices nothing of this except a code that changes.
///
/// **The service goes with the code.** A receiver that stayed open beyond its code
/// would accept a package encrypted with a long-expired key —
/// and exactly that is what the waiting period is meant to prevent.
@Observable
final class HandoffReceiveModel {

    enum Situation: Equatable {
        case waiting
        case imported(Takeover.Report)
        /// The finished sentence from ``SecondScreen/HandoffMessage`` — the cause comes from
        /// ``HandoffWire``, the wording from `WordingKit` (AP58 R5).
        case failed(String)
    }

    private(set) var state: Situation = .waiting
    private(set) var key: HandoffKey?
    /// How long the code remains valid, in seconds — for the clock under the picture.
    private(set) var remainingTime: TimeInterval = 0

    private var receiver: HandoffReceiver?
    /// The clock under the code — ``SecondScreen/CodeClock``, the same as with pairing.
    private let clock = CodeClock()

    /// Opens a fresh code and the service with it.
    func begin() {
        stopListening()
        let new = HandoffKey.fresh(target: ServiceName.handoff())
        key = new
        state = .waiting
        remainingTime = new.remainingTime()

        let receiver = HandoffReceiver(key: new) { [weak self] result in
            // The callback comes from a thread of its own; everything further belongs to the
            // main thread — it writes to the Keychain and the store.
            //
            // **And it answers** (AP39, 2026-09-20): What goes back here, the wire
            // acknowledges to the phone. Only through that does the sender learn that the
            // parental controls were declined — before, only this screen knew.
            await MainActor.run { self?.take(result) }
        }
        do {
            try receiver.start()
            self.receiver = receiver
        } catch {
            Diagnostics.defect(
                "Handoff receiver not started: \(Diagnostics.explain(error))", since: nil,
                area: "Anmeldung")
            state = .failed(HandoffMessage.message(zu: .noService, page: .receiver))
            return
        }
        clock.run(
            forItem: new,
            whileTrue: { [weak self] in
                guard let self, case .waiting = self.state else { return false }
                return true
            },
            tick: { [weak self] rest in self?.remainingTime = rest },
            expired: { [weak self] in self?.begin() })
    }

    func stopListening() {
        clock.hold()
        receiver?.stopListening()
        receiver = nil
    }

    /// - Returns: What was applied — the wire sends it back as an attachment of the
    ///   acknowledgement. On failure `nil`: The acknowledgement then already carries the cause
    ///   itself, and an empty report next to it would be a second, quieter statement
    ///   about it.
    @discardableResult
    private func take(
        _ result: Result<SetupBundle, HandoffWire.TestError>
    ) -> Takeover.Report? {
        switch result {
        case .success(let bundles):
            let report = Takeover().matches(code: bundles)
            state = .imported(report)
            // **The service closes immediately.** The key is valid once; leaving it open after the
            // first package would mean accepting a second sender
            // of which the first would learn nothing.
            stopListening()
            return report
        case .failure(let error):
            state = .failed(HandoffMessage.message(zu: error, page: .receiver))
            stopListening()
            return nil
        }
    }
}
