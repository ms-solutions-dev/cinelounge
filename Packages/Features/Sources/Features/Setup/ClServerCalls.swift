import Core
import DesignSystem
import Flows
import Foundation
import Household
import PortalKit
import ProfileKit

/// What A6 does at the CL-Server besides the machine's effects — **polling, withdrawing,
/// redeeming a pairing code** (AP88 §3: `JoinRequester`, `SelfSignIn`, `PortalSettings.pairing`).
///
/// **Passed in, so that the sheet can be shown without a server.** The program's set is
/// ``onDevice(basis:)``; the setup's two effects that reach the CL-Server
/// (``Flows/SetupEffect/enroll(_:)`` and ``Flows/SetupEffect/requestJoin(_:)``) find their real
/// calls in ``enroll(_:at:)`` and ``requestJoin(_:at:kind:)`` for `SetupServices`.
///
/// **Where the CL-Server stands:** a fresh TV has no stored bridge address yet (§10.1). Every
/// call takes the address the search found (``Flows/SetupMachine/clServerAddress``) and **keeps
/// it once it is used** — for a request, a self sign-in or a pairing; a mere find stores
/// nothing.
public struct ClServerCalls {

    /// How a pairing code ended.
    nonisolated public enum Pairing: Sendable, Equatable {
        /// Paired — with the person's name if the code carried one.
        case paired(person: String?)
        /// Refused, already as a sentence.
        case refused(String)
    }

    /// One look at the open request (``Flows/JoinRequester/queryPending()``).
    public var poll: @MainActor () async -> RequestState
    /// Withdraws the open request (``Flows/JoinRequester/forget()``).
    public var withdraw: @MainActor () -> Void
    /// Redeems a pairing code for the active profile.
    public var redeem: @MainActor (String) async -> Pairing

    public init(
        poll: @escaping @MainActor () async -> RequestState,
        withdraw: @escaping @MainActor () -> Void,
        redeem: @escaping @MainActor (String) async -> Pairing
    ) {
        self.poll = poll
        self.withdraw = withdraw
        self.redeem = redeem
    }

    /// The program's set — the address is asked at each call, because the search may answer
    /// while the sheet is open.
    public static func onDevice(basis: @escaping @MainActor () -> URL?) -> ClServerCalls {
        ClServerCalls(
            poll: {
                guard let requester = requester(at: basis()) else { return .none }
                return await requester.queryPending()
            },
            withdraw: { requester(at: basis())?.forget() },
            redeem: { code in
                guard let address = address(basis()) else {
                    return .refused(LanguageFallback.message("settings.portals.unreachable") ?? "")
                }
                return await redeem(code, at: address)
            })
    }

    // MARK: - The setup's effects

    /// `SelfSignIn` with the person token, **for the profile the setup names** (§2.1, §10.1).
    public static func enroll(_ identifier: Profile.Identifier, at basis: URL?) async -> Bool {
        guard let address = address(basis) else { return false }
        let keychain = SecureStore()
        let signIn = SelfSignIn(
            basis: address, session: .shared, keychain: keychain, ledgerStore: FileStore(),
            deviceName: DeviceName.thisDevice, kind: .thisDevice)
        return await signIn.attempts(.setup, forItem: identifier) == .signedIn
    }

    /// The request for **the setup's profile** — not the active one, although they are the same
    /// (§3, `JoinFlow`).
    public static func requestJoin(
        _ identifier: Profile.Identifier, at basis: URL?, kind: DeviceKind = .tv
    ) async -> RequestState {
        guard
            let profile = ProfileBook.read(from: FileStore()).profile.first(where: {
                $0.identifier == identifier
            })
        else { return .none }
        guard let requester = requester(at: basis, kind: kind) else {
            return .failed(LanguageFallback.message("settings.portals.unreachable") ?? "")
        }
        return await requester.location(forItem: profile)
    }

    // MARK: - Pairing

    /// Redeems a pairing code — **the one way in for a child's device** and the code path of the
    /// settings (``PortalSettings``).
    ///
    /// **The same reader as on the phone:** ``PortalKit/Invitation`` takes a six-character code
    /// or a whole invitation link and extracts only the password. Typed in lowercase it is the
    /// same code.
    static func redeem(
        _ input: String, at basis: URL, keychain: any KeyValueStore = SecureStore(),
        ledgerStore: any KeyValueStore = FileStore()
    ) async -> Pairing {
        guard let read = Invitation(input: input) else {
            return .refused(LanguageFallback.message("settings.portals.badCode") ?? "")
        }
        do {
            let login = try await DeviceSignIn.redeem(read, basis: basis, keychain: keychain)
            let entered = PortalAssignment.afterRedemption(person: login.person?.id, ledgerStore: ledgerStore)
            Diagnostics.network.info(
                "CL-Server: code redeemed, \(login.person == nil ? "without" : "with") person, \(entered ? "entered" : "NOT entered (no active profile)") on the profile"
            )
            return .paired(person: login.person?.name)
        } catch let refusal as PortalBridge.TestError {
            Diagnostics.defect(
                "Pairing rejected: \(Diagnostics.explain(refusal))", since: nil, area: "Anmeldung")
            return .refused(refusal.message(lookUp: LanguageFallback.message))
        } catch {
            Diagnostics.defect("Pairing failed: \(Diagnostics.explain(error))", since: nil, area: "Anmeldung")
            return .refused(error.localizedDescription)
        }
    }

    // MARK: - Inside

    private static func requester(at basis: URL?, kind: DeviceKind = .tv) -> JoinRequester? {
        guard let address = address(basis) else { return nil }
        return JoinRequester(
            basis: address, session: .shared, keychain: SecureStore(), ledgerStore: FileStore(),
            deviceName: DeviceName.thisDevice, kind: kind, lookUp: LanguageFallback.message,
            colorValue: ProfileBrand.value)
    }

    /// The address to use — the found one, else the stored one; **the found one is kept** when
    /// nothing is stored yet.
    private static func address(_ basis: URL?) -> URL? {
        let keychain = SecureStore()
        if let stored = BridgeAddress.effective(from: keychain) { return stored }
        guard let basis else { return nil }
        BridgeAddress.save(basis.absoluteString, to: keychain)
        return basis
    }
}
