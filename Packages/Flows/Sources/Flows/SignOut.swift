import Core
import Diagnose
import Foundation
import JellyfinKit

/// Signing out of a media server account — **at the server and on the device, the same on both
/// devices** (setup check, E11, 2026-09-27).
///
/// **The finding:** On the TV "Sign out" deleted only the session. The access token stayed
/// valid at the server, the device stayed in its device list, and in the Keychain the
/// account stayed in the account list — every other profile with this account got back in
/// by profile switch without a password. `JellyfinConnection.logout` existed, nobody
/// called it. On the phone the docs claimed "Signing out ends the session at the server",
/// and there too it did not happen.
///
/// **The revocation runs on the side and may fail.** A server that is not currently
/// answering should not hold up the sign-out; locally the account is gone afterwards, and the
/// token expires at the server at the latest when an administrator removes the device.
public enum SignOut {

    /// How the token is revoked at the server — the checks pass in a path of their own.
    public typealias Revocation = @Sendable (ServerCredentials) async -> Void

    /// The program's path: `POST /Sessions/Logout` with the token and the ID of this
    /// device — the same one under which it signed in.
    public static let onServer: Revocation = { credential in
        await JellyfinConnection().logout(
            credentials: credential, deviceID: DeviceIdentity.id(), deviceName: DeviceName.thisDevice)
    }

    /// Removes the account from account list and session and revokes its token.
    ///
    /// **The session only if it is exactly this account.** Whoever removes a second
    /// account on the phone stays signed in with the first.
    ///
    /// - Returns: the running revocation — the checks wait for it, the program does not.
    @discardableResult
    public static func signOut(
        _ credential: ServerCredentials, keychain: SecureStore,
        revoke: @escaping Revocation = onServer
    ) -> Task<Void, Never> {
        do {
            try keychain.forget(server: credential.serverURL, user: credential.userID)
        } catch {
            Diagnose.error(.login, "Sign-out: credential could not be removed from the list", error)
        }
        if let session = try? keychain.loadCredentials(),
            session.serverURL == credential.serverURL, session.userID == credential.userID
        {
            try? keychain.clearCredentials()
        }
        Diagnose.step(.login, "Signed out, token is revoked on the server")
        return Task { await revoke(credential) }
    }
}
