import Core
import Foundation
import JellyfinKit
import ProfileKit

/// The shortcut of AP88 §2.1 — **a token that outlived the app in the Keychain.**
///
/// iCloud carries `Access.jellyfin(server:userID:username:)` but never the token (AP43). On the
/// same TV, though, the Keychain survives deleting the app, and the account list
/// (``Core/SecureStore/allAccounts()``) may still hold a token for exactly this server and user.
/// One call to `Users/Me` says whether it still counts; then the row is ✓ without a single press.
///
/// **What the shell does with a hit:** `SetupServices.checkToken` returns `true` and hands the
/// credential to `SessionStore.signIn` itself — the machine only records the row
/// (``SetupInput/tokenChecked(_:valid:)``), it never sees a token.
nonisolated public enum SetupKeychainHit {

    /// The stored sign-in for this access — **the same server and the same user**, the newest if
    /// there are several.
    ///
    /// The user ID alone would not do: two servers can hand out the same ID, and a token of the
    /// other one would sign Lea in somewhere she never was.
    public static func credential(for access: Access, in accounts: [ServerCredentials]) -> ServerCredentials?
    {
        guard case .jellyfin(let server, let userID, _) = access else { return nil }
        return accounts.last { $0.userID == userID && $0.serverURL == server }
    }

    /// Looks for a token and checks it with one call.
    ///
    /// - Parameter isValid: whether the server still accepts the credential —
    ///   ``realCheck(deviceID:)`` in the program, a value in the checks.
    /// - Returns: the credential if it still counts, otherwise `nil` (no token, or the server
    ///   refused it, or it did not answer — then A5 asks, which costs one press).
    public static func check(
        _ access: Access, in accounts: [ServerCredentials],
        isValid: (ServerCredentials) async -> Bool
    ) async -> ServerCredentials? {
        guard let credential = credential(for: access, in: accounts) else { return nil }
        return await isValid(credential) ? credential : nil
    }

    /// Whether a hit may sign in now — **only for the profile that is still active.** The check
    /// takes a call; whoever went back to A2 in the meantime and chose someone else must not get
    /// this profile's Jellyfin.
    public static func signsIn(_ access: Access, active: Profile?) -> Bool {
        active?.jellyfin == access
    }

    /// The program's check — `Users/Me` with the stored token (``JellyfinKit/JellyfinSource/userPolicy()``).
    public static func realCheck(deviceID: String) -> @Sendable (ServerCredentials) async -> Bool {
        { credential in
            (try? await JellyfinSource(credentials: credential, deviceID: deviceID).userPolicy()) != nil
        }
    }
}
