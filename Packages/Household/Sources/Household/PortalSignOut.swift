import Core
import Diagnose
import Foundation
import PortalKit
import ProfileKit

/// Sign out — **and block self-enrollment with the same token** (cross-check of
/// 2026-09-24).
///
/// **Pulled out of the view so the connection can be tested.** Before, signing
/// out only threw away the credential; the token stayed in the profile, and the next
/// time the portals opened, ``SelfSignIn`` quietly signed the device in again — as a new
/// server device, until the ten per token were used up. A sign-out that undoes
/// itself is none.
///
/// **Since AP58 R2 on the phone too.** There, signing out only threw away the credential; the
/// token block was missing because the phone had no self-enrollment. Now it runs through
/// ``TokenReconciliation`` as well — so the block applies too.
///
/// **And an open join request goes with it** (check of 2026-09-27, B1): Otherwise
/// the next opening of the portals would pick up an approval granted in the meantime, and the
/// device would be signed in again — the same ineffective sign-out by a second route.
///
/// **`DeviceTrait.forget` only after the server sign-out** (finding 2026-09-27, e1,
/// security): `try?` discarded every error until then, and without an address no attempt was
/// made at all — the credential was dropped here anyway. It stayed valid on the server
/// and was forgotten locally, so **never revocable again**: no device knows it any more to
/// take it back. Now only a confirmed server sign-out counts as signing out; without an
/// address or on failure the credential stays, and the caller receives
/// ``Outcome/failed`` to display and retry.
public enum PortalSignOut {

    /// What became of an attempt — **for the view**, which turns it into an error message
    /// with a "try again" instead of a silent success.
    public enum Outcome: Equatable, Sendable {
        /// Signed out at the server (or there was no credential left to revoke).
        case signedOut
        /// Only the loan of a borrowed profile ended — the credential stays.
        case borrowedReturned
        /// Without an address or because of a server error: the credential is still there,
        /// **on purpose** — otherwise it would remain valid there and could no longer be
        /// revoked from here.
        case failed
    }

    /// - Parameter geliehen: For a borrowed profile only the loan ends; the credential
    ///   stays, and nothing is blocked.
    @discardableResult
    public static func notify(
        from isBorrowed: Bool, basis: URL?, session: URLSession, keychain: any KeyValueStore,
        ledgerStore: any KeyValueStore
    ) async -> Outcome {
        if isBorrowed {
            DeviceTrait.saveProfile(nil, to: keychain)
            return .borrowedReturned
        }
        // Without a credential there is nothing to revoke — the same situation as "already signed out".
        if let trait = DeviceTrait.load(from: keychain) {
            guard let basis else {
                Diagnose.error(.login, "Sign-out not possible without a server address")
                return .failed
            }
            // First at the server, then here: the other way round, a valid credential would remain in
            // the world that nobody can take back any more, because nobody knows it any more.
            do {
                try await Household(
                    binding: PortalBridge(
                        basis: basis, dialect: .cinelounge, trait: trait, session: session)
                ).signOut()
            } catch {
                Diagnose.error(.login, "Household sign-out failed", error)
                return .failed
            }
        }
        DeviceTrait.forget(in: keychain)
        JoinNote(keychain).forgetRequest()
        Diagnose.step(.login, "Signed out of the household")
        if let active = ProfileBook.read(from: ledgerStore).active,
            let tag = PortalMarkerSlot(keychain).tag(forItem: active)
        {
            JoinNote(keychain).rememberSignedOut(tag)
        }
        return .signedOut
    }
}
