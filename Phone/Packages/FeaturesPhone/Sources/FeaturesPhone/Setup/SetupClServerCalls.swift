import Core
import DesignSystemPhone
import Diagnose
import Flows
import Foundation
import Household
import PortalKit
import ProfileKit

/// What A6 does at the CL-Server — **the same calls as the TV's `ClServerCalls`**, over this
/// phone's stores (AP88 §3: `JoinRequester`, `SelfSignIn`, the pairing code).
///
/// **Where the CL-Server stands:** a fresh device has no stored bridge address yet (§10.1). Every
/// call takes the address the search found (``Flows/SetupMachine/clServerAddress``) and **keeps
/// it once it is used**; a mere find stores nothing.
///
/// **The device kind is `DeviceKind.thisDevice` (Household)** and not the fixed
/// ``Flows/SetupSteps/deviceKind``: the same program runs on the iPad, and the CL-Server lists the
/// device as what it is — the settings' request (`PortalSettingsModel`) says the same.
@MainActor
struct SetupClServerCalls {

    /// How a pairing code ended.
    enum Pairing: Sendable, Equatable {
        case paired(person: String?)
        /// Refused, already as a sentence.
        case refused(String)
    }

    let stores: SetupHub.Stores

    /// `SelfSignIn` with the person token, **for the profile the setup names** (§2.1, §10.1).
    func enroll(_ identifier: Profile.Identifier, at basis: URL?) async -> Bool {
        guard let address = address(basis) else { return false }
        let signIn = SelfSignIn(
            basis: address, session: .shared, keychain: stores.keychain, ledgerStore: stores.ledger,
            deviceName: DeviceName.thisDevice, kind: .thisDevice)
        return await signIn.attempts(.setup, forItem: identifier) == .signedIn
    }

    /// The request for **the setup's profile** — not the active one, although they are the same.
    func requestJoin(_ identifier: Profile.Identifier, at basis: URL?) async -> RequestState {
        guard
            let profile = ProfileBook.read(from: stores.ledger).profile.first(where: {
                $0.identifier == identifier
            })
        else { return .none }
        guard let requester = requester(at: basis) else {
            return .failed(AppLanguageSetting.message("setup.clServer.notFound"))
        }
        return await requester.location(forItem: profile)
    }

    /// One look at the open request.
    func poll(at basis: URL?) async -> RequestState {
        guard let requester = requester(at: basis) else { return .none }
        return await requester.queryPending()
    }

    /// Withdraws the open request.
    func withdraw(at basis: URL?) {
        requester(at: basis)?.forget()
    }

    /// Redeems a pairing code — **the one way in for a child's device** (§1.4 point 4), the same
    /// reader as in the settings (``PortalKit/Invitation``).
    func redeem(_ input: String, at basis: URL?) async -> Pairing {
        guard let read = Invitation(input: input) else {
            return .refused(AppLanguageSetting.message("setup.badAddress"))
        }
        guard let address = read.bridgeAddress ?? address(basis) else {
            return .refused(AppLanguageSetting.message("settings.portals.inviteNeedsAddress"))
        }
        do {
            let login = try await DeviceSignIn.redeem(read, basis: address, keychain: stores.keychain)
            PortalAssignment.afterRedemption(person: login.person?.id, ledgerStore: stores.ledger)
            return .paired(person: login.person?.name)
        } catch let refusal as PortalBridge.TestError {
            Diagnose.hint(.network, "Setup pairing rejected: \(refusal.fallbackText)", refusal)
            return .refused(refusal.message(lookUp: LanguageFallback.message))
        } catch {
            Diagnose.hint(.network, "Setup pairing failed", error)
            return .refused(error.localizedDescription)
        }
    }

    // MARK: - Inside

    private func requester(at basis: URL?) -> JoinRequester? {
        guard let address = address(basis) else { return nil }
        return JoinRequester(
            basis: address, keychain: stores.keychain, ledgerStore: stores.ledger,
            deviceName: DeviceName.thisDevice, kind: .thisDevice,
            lookUp: LanguageFallback.message, colorValue: ProfileBrand.value)
    }

    /// The stored address, else the found one — **the found one is kept** once it is used.
    private func address(_ basis: URL?) -> URL? {
        if let stored = BridgeAddress.effective(from: stores.keychain) { return stored }
        guard let basis else { return nil }
        BridgeAddress.save(basis.absoluteString, to: stores.keychain)
        return basis
    }
}
