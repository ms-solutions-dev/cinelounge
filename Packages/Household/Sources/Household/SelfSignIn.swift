import Core
import Diagnose
import Foundation
import PortalKit
import ProfileKit

/// A device signs in **by itself with the token from the profile** (AP47, third
/// app row) — no pairing code, no console.
///
/// **When, and only then:** when the portals open (``Occasion/open``) and when a
/// portal request was rejected with `auth.required` (``Occasion/dismissed``). **No
/// constant polling:** A token rarely changes, and a timer that asks the server in the background
/// mostly asks it when nobody benefits.
///
/// **At most one attempt per occasion**, and a token that the server has once rejected as
/// unknown never again (``ProfileKit/JoinNote/failed``). Otherwise
/// every opening would ask the server with the same dead token until its throttle kicks in.
///
/// **Since AP58 R2 for both programs** (finding P3). The phone did not have it, because it
/// never comes in via a token; through ``TokenReconciliation`` it now runs there as
/// well, and ``expectedValue(_:hasTrait:tag:used:failed:signedOut:)`` says "no" for a
/// phone with its own sign-in — the same calculation, no platform switch.
public struct SelfSignIn {

    public enum Occasion: Equatable, Sendable {
        /// The portals are opened.
        case open
        /// A request was rejected with `auth.required` — the credential no longer applies.
        case dismissed
        /// The first setup reached the CL-Server row of a profile that carries a person token
        /// (AP88 §2.1). **Decided like ``open``** — a device without a credential signs in, one
        /// with a credential has nothing new to say — but named apart, so that the log tells
        /// a setup step from an opened portal page.
        case setup
    }

    public enum SwitchOutcome: Equatable, Sendable {
        /// There was nothing to do — no token, already signed in, the same token as last
        /// time, or one that has already failed once.
        case notNeeded
        case signedIn
        case failed
    }

    let basis: URL
    let session: URLSession
    let keychain: any KeyValueStore
    let ledgerStore: any KeyValueStore
    let deviceName: String
    let kind: DeviceKind

    public init(
        basis: URL, session: URLSession, keychain: any KeyValueStore,
        ledgerStore: any KeyValueStore, deviceName: String, kind: DeviceKind
    ) {
        self.basis = basis
        self.session = session
        self.keychain = keychain
        self.ledgerStore = ledgerStore
        self.deviceName = deviceName
        self.kind = kind
    }

    /// **The whole decision as a calculation** — testable without a server.
    ///
    /// - Parameters:
    ///   - hatMerkmal: Is there a device credential in the Keychain?
    ///   - marke: The digest of the token in the active profile.
    ///   - genutzt: The digest of the token this device came in with, or `nil`.
    ///   - gescheitert: The digest of the token the server rejected, or `nil`.
    ///   - abgemeldet: The digest of the token with which someone explicitly signed out
    ///     here (``PortalSignOut``), or `nil`. It is blocked until a
    ///     new approval or a different token comes.
    ///
    /// **A rejected credential alone is no reason.** If the device did not come in via a
    /// token (pairing code) or via **the same** one that is in the profile now, a
    /// sign-in would have nothing new — on revocation the old token is just as dead as the
    /// credential. Only a **different** token in the profile is the new one.
    public nonisolated static func expectedValue(
        _ reason: Occasion, hasTrait: Bool, tag: String, used: String?, failed: String?,
        signedOut: String?
    ) -> Bool {
        guard tag != failed, tag != signedOut else { return false }
        switch reason {
        case .open, .setup:
            return !hasTrait
        case .dismissed:
            guard hasTrait else { return true }
            guard let used else { return false }
            return used != tag
        }
    }

    /// One attempt, if ``expectedValue(_:hasTrait:tag:used:failed:signedOut:)`` says so.
    ///
    /// **Never for children:** The server gives them no token, so the app does not expect one
    /// either — a child profile with one (for example from a converted profile) signs nothing
    /// in here.
    ///
    /// - Parameter identifier: **The profile the caller means** — the setup names its own. The
    ///   credential lands in the active profile's compartment (`DeviceTrait.bucket`); if that is
    ///   someone else, nothing happens rather than signing in the wrong person.
    public func attempts(
        _ reason: Occasion, forItem identifier: Profile.Identifier? = nil
    ) async -> SwitchOutcome {
        let ledger = ProfileBook.read(from: ledgerStore)
        guard let profile = ledger.activeProfile, profile.wantsPortals, profile.kind != .kind,
            identifier.map({ $0 == profile.identifier }) ?? true,
            let tag = PortalMarkerSlot(keychain).tag(forItem: profile.identifier)
        else { return .notNeeded }
        let note = JoinNote(keychain)
        guard
            Self.expectedValue(
                reason, hasTrait: DeviceTrait.signedIn(in: keychain),
                tag: tag.digest, used: note.used, failed: note.failed,
                signedOut: note.signedOut)
        else { return .notNeeded }

        let join = Join(
            binding: PortalBridge(basis: basis, dialect: .cinelounge, session: session))
        do {
            let login = try await join.signIn(
                tag: tag.value, name: deviceName, kind: kind)
            // The device now belongs to the person — the same rule as after `/redeem`.
            DeviceSignIn.create(login.trait, own: true, in: keychain)
            note.rememberUsed(tag)
            if let person = login.person, profile.portalPerson != person.id {
                var fresh = ledger
                fresh.update(profile.identifier) { $0.create(.portals(person: person.id)) }
                fresh.write(in: ledgerStore)
            }
            Diagnose.step(.login, "Self sign-in with the person token (\(reason))")
            return .signedIn
        } catch let rejection as PortalBridge.TestError
            where Self.blockingCodes.contains(rejection.code ?? "")
        {
            note.rememberFailed(tag)
            Diagnose.hint(.login, "Person token rejected: \(rejection.fallbackText)", rejection)
            return .failed
        } catch {
            // Network or throttle: **not** recorded as a dead token — at the next occasion
            // there may be an attempt again, but only one.
            Diagnose.hint(.network, "Self sign-in failed", error)
            return .failed
        }
    }
}

extension SelfSignIn {

    /// Refusals after which **this token is never tried again**.
    ///
    /// `enroll.unknown_mark` means unknown or revoked. `enroll.too_many_devices`
    /// (cross-check of 2026-09-24) means: ten devices are already attached to the token — without
    /// the block every opening would ask the server again and get the same `409` each time.
    /// Only a new approval or a different token opens the way again.
    public nonisolated static let blockingCodes: Set<String> = [
        "enroll.unknown_mark", "enroll.too_many_devices",
    ]

    /// This program's self-enrollment: Keychain, file store, and the
    /// registered address — `nil` if none is registered.
    public static func onDevice() -> SelfSignIn? {
        let keychain = SecureStore()
        guard let bridgeAddress = BridgeAddress.effective(from: keychain) else { return nil }
        return SelfSignIn(
            basis: bridgeAddress, session: .shared, keychain: keychain,
            ledgerStore: FileStore(), deviceName: DeviceName.thisDevice, kind: .thisDevice)
    }
}
