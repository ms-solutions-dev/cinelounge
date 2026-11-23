import Core
import Diagnose
import Foundation
import PortalKit
import ProfileKit

extension DeviceKind {

    /// How **this** device names itself to the server — a TV borrows profiles, everything
    /// else belongs to somebody.
    ///
    /// **One value and not a switch at every call site** (AP58 R2): Until then `.tv`
    /// or `.web` stood in each of the four sign-in places individually.
    ///
    /// **Phone or tablet, not `web`** (AP85, 2026-11-09): since the console rebuild the
    /// server knows both, and its device list showed every phone as a browser.
    public nonisolated static var thisDevice: DeviceKind {
        #if os(tvOS)
            .tv
        #elseif os(iOS)
            isTablet ? .tablet : .phone
        #else
            .web
        #endif
    }

    /// Whether this is an iPad — read from the model identifier and not from `UIDevice`.
    ///
    /// **`UIDevice` belongs to the main actor**, and ``thisDevice`` is read from
    /// background tasks during sign-in. The model identifier is the same answer without
    /// the hop: `iPad…` on a device, `SIMULATOR_MODEL_IDENTIFIER` in the simulator.
    nonisolated static var isTablet: Bool {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated.hasPrefix("iPad")
        }
        var info = utsname()
        uname(&info)
        let model = withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return model.hasPrefix("iPad")
    }
}

/// What a sign-in leaves on the device — **feature, no loaner header, and whether the device
/// belongs to somebody** (AP47; merged in AP58 R2, findings P3 and E4).
///
/// **The finding:** After an invitation the TV set the own-device feature
/// (``Core/DeviceTrait/ownKey``), the phone did not — neither after the invitation nor
/// after signing in with person and PIN. As long as the phone never wrote a portal header,
/// that went unnoticed. Since it switches via ``ProfileKit/ProfileSwitch`` like the TV,
/// the header depends on the own-device feature; a phone without it would get a loaner header on switching,
/// and ``TokenReconciliation/reconcile()`` would take it for borrowed.
public enum DeviceSignIn {

    /// Stores a fresh feature.
    ///
    /// **The profile is NOT set here but taken away.** Whether the device needs one
    /// is said by the server on the next request — and if it belongs to a person,
    /// a remembered profile would be a loan that nobody wanted.
    ///
    /// **And an open join request is dropped** (check 2026-09-27, B1): Whoever comes in via
    /// code, invitation, PIN, mark or approval is waiting for nothing any more. If it
    /// stayed, a later approval would pick it up and replace this feature — a
    /// shared TV would silently belong to one person afterwards.
    ///
    /// - Parameter eigen: whether the device belongs to a person. **With a person means own**:
    ///   Then a profile switch no longer writes a loaner header.
    public nonisolated static func create(
        _ trait: String, own: Bool, in keychain: any KeyValueStore
    ) {
        DeviceTrait.save(trait, to: keychain)
        DeviceTrait.saveProfile(nil, to: keychain)
        DeviceTrait.saveOwn(own, to: keychain)
        JoinNote(keychain).forgetRequest()
    }

    /// Redeem an invitation or a pairing code — **and store what comes out of it.**
    ///
    /// The address, reading the code and the sentences stay with the call site: The
    /// TV types a six-character code on the remote, the phone catches a link from
    /// the camera. What then has to lie on the device is the same on both.
    ///
    /// - Throws: ``PortalKit/PortalBridge/TestError`` or a network error; then nothing is
    ///   stored.
    @discardableResult
    public static func redeem(
        _ invitation: Invitation, basis: URL, session: URLSession = .shared,
        keychain: any KeyValueStore, deviceName: String = DeviceName.thisDevice,
        kind: DeviceKind = .thisDevice
    ) async throws -> SignIn {
        let login = try await Household(
            binding: PortalBridge(basis: basis, dialect: .cinelounge, session: session)
        ).redeem(password: invitation.password, name: deviceName, kind: kind)
        create(login.trait, own: login.person != nil, in: keychain)
        Diagnose.step(.login, "Invitation redeemed")
        return login
    }

    /// Sign in with person and PIN — **the device then belongs to this person.**
    ///
    /// **The device name goes along**, otherwise this device is called "Browser" in the
    /// device list like every other.
    @discardableResult
    public static func notify(
        on person: String, pin: String, basis: URL, session: URLSession = .shared,
        keychain: any KeyValueStore, deviceName: String = DeviceName.thisDevice
    ) async throws -> SignIn {
        let login = try await Household(
            binding: PortalBridge(basis: basis, dialect: .cinelounge, session: session)
        ).signIn(person: person, pin: pin, device: deviceName)
        create(login.trait, own: true, in: keychain)
        Diagnose.step(.login, "Signed in with person")
        return login
    }

    /// **A phone that was signed in before AP58 R2 belongs to its person** — added
    /// once.
    ///
    /// Until then the phone never wrote a loaner header and never sent one; each of its
    /// sign-ins behaved like an own one. Without this addition the first profile switch
    /// after the update would turn it into a loan, and the mark sync would stay silent.
    /// **Only without a remembered profile**: Whoever already carries a header was never "own".
    ///
    /// **Exactly once per device** (``backfilledKey``): A later invitation without a person
    /// explicitly makes a shared iPad a shared device; an addition at every start
    /// would take that away from it again.
    ///
    /// - Returns: whether it was added.
    @discardableResult
    public nonisolated static func adoptsLegacySignIn(
        in keychain: any KeyValueStore
    ) -> Bool {
        guard (try? keychain.value(for: backfilledKey)) == nil else { return false }
        try? keychain.set("1", for: backfilledKey)
        guard DeviceTrait.signedIn(in: keychain),
            !DeviceTrait.own(in: keychain),
            DeviceTrait.profile(from: keychain) == nil
        else { return false }
        DeviceTrait.saveOwn(true, to: keychain)
        return true
    }

    /// Where it is recorded that ``adoptsLegacySignIn(in:)`` has already run — assembled, because it
    /// is a store key and not a language key (`scripts/strings.py`).
    nonisolated static let backfilledKey = "setup" + ".deviceOwnedMigrated"
}
