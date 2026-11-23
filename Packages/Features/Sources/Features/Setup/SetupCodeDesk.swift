import Core
import Flows
import Foundation
import ProfileKit
import SecondScreen

/// The code on A2 — **QR stage 1 with the schemes the phone already opens** (AP88 §4.2).
///
/// | TV has iCloud | the QR carries | the phone |
/// |---|---|---|
/// | yes (``Flows/SetupPullMode/cloud``) | `Pairing.link(code:role: .search)` → `cinelounge-koppeln://` | puts the profile link into the mailbox |
/// | no (``Flows/SetupPullMode/wire``) | ``SecondScreen/HandoffKey`` → `cinelounge-uebergabe://` | hands over through the home network |
///
/// **Issuing and withdrawing only** — when, and that only one code is valid at a time, decides
/// ``Flows/SetupJourney`` through ``Flows/SetupServices/issueCode`` and
/// ``Flows/SetupServices/revokeCode``. This desk keeps what belongs to the code that is valid now:
/// the pairing that polls the mailbox, or the receiver that listens in the home network.
///
/// **What arrives goes to ``onArrival``** as the profiles in the book
/// (``Flows/SetupWorld/arrivals(before:in:named:carried:)``): one, and the machine jumps into its
/// A4 without a press; several — the handoff carries the phone's whole book — and they stand in
/// A2 for someone to pick. **The color scheme of a handoff goes to ``onTheme``**, as
/// ``HandoffReceiveView`` applies it on leaving.
///
/// **No handoff while the reception door is shut** (`uebergabeEmpfang`): a bundle may carry a
/// PIN and a limit, and the door in front of the handoff is the parental-controls question of
/// AP23. A code that bypassed it would be the way round. Without a household PIN the door is open,
/// and that is the fresh TV.
public final class SetupCodeDesk {

    /// How the code travels now — read from the offer on A2 at every issue, so that a late iCloud
    /// answer switches the next code from the home network to iCloud.
    public var mode: () -> SetupPullMode? = { nil }
    public var onArrival: (SetupWorld.Arrival) -> Void = { _ in }
    /// The color scheme a handoff brought — `ThemeStore.choose` in the shell.
    public var onTheme: (Theme) -> Void = { _ in }

    private let store: any KeyValueStore
    private var pairing: PairingModel?
    private var watch: Task<Void, Never>?
    private var receiver: HandoffReceiver?
    private var before: Set<Profile.Identifier> = []

    public init(store: any KeyValueStore = FileStore()) {
        self.store = store
    }

    /// A fresh code — `nil` if none can be issued here and now.
    public func issue() async -> String? {
        switch mode() {
        case .cloud: issuePairing()
        case .wire: issueHandoff()
        case nil: nil
        }
    }

    /// Withdraws whatever belongs to the current code.
    public func revoke(_ code: String) {
        watch?.cancel()
        watch = nil
        if let pairing {
            Task { await pairing.close() }
        }
        pairing = nil
        receiver?.stopListening()
        receiver = nil
    }

    // MARK: - iCloud

    private func issuePairing() -> String? {
        guard let cloud = ProfileCloud.attached else { return nil }
        let model = PairingModel(cloud: cloud, device: DeviceName.thisDevice)
        model.search()
        guard let link = model.qr else { return nil }
        pairing = model
        remember()
        watch = Task { [weak self] in
            await model.run()
            guard !Task.isCancelled, case .arrived(let name, _) = model.state else { return }
            self?.arrived(named: name)
        }
        return link.absoluteString
    }

    // MARK: - Home network

    private func issueHandoff() -> String? {
        guard !ParentalControlsState().isHidden("uebergabeEmpfang") else { return nil }
        let key = HandoffKey.fresh(target: ServiceName.handoff())
        let listener = HandoffReceiver(key: key) { [weak self] result in
            await MainActor.run { self?.take(result) }
        }
        do {
            try listener.start()
        } catch {
            Diagnostics.defect(
                "Setup: handoff receiver for the code on A2 not started — \(Diagnostics.explain(error))",
                since: nil, area: "Anmeldung")
            return nil
        }
        receiver = listener
        remember()
        return key.asText
    }

    /// **The receiver closes after the first bundle** — the key is valid once, as in
    /// ``HandoffReceiveModel``.
    private func take(_ result: Result<SetupBundle, HandoffWire.TestError>) -> Takeover.Report? {
        receiver?.stopListening()
        receiver = nil
        switch result {
        case .success(let bundle):
            let report = Takeover().matches(code: bundle)
            arrived(named: nil, carried: bundle.profile.map(\.identifier))
            if let theme = Takeover.colorPattern(report.colorPattern) { onTheme(theme) }
            return report
        case .failure(let error):
            Diagnostics.defect(
                "Setup: handoff on A2 failed — \(HandoffMessage.message(zu: error, page: .receiver))",
                since: nil, area: "Anmeldung")
            return nil
        }
    }

    // MARK: - Arrival

    private func remember() {
        before = Set(ProfileBook.read(from: store).profile.map(\.identifier))
    }

    private func arrived(named name: String?, carried: [Profile.Identifier] = []) {
        let arrival = SetupWorld.arrivals(
            before: before, in: ProfileBook.read(from: store), named: name, carried: carried)
        guard arrival != .none else { return }
        onArrival(arrival)
    }
}
