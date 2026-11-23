import Core
import Foundation

extension Access {

    /// From the keychain's credentials.
    ///
    /// **A translation and not a move:** Password and access token stay where they
    /// are; only the pointer to them is created here.
    public init(_ credential: ServerCredentials) {
        self = .jellyfin(
            server: credential.serverURL, userID: credential.userID,
            username: credential.username)
    }

    /// This device's media-server accesses — **the logged-in session included.**
    ///
    /// **The gap this closes.** ``Core/SecureStore`` keeps two things apart: the
    /// account list (``Core/SecureStore/memorize(_:)``) and the one logged-in session
    /// (``Core/SecureStore/saveCredentials(_:)``). Until 2026-09-06 the setup path
    /// filled **only the second** — on every device that was set up before, the list
    /// is empty to this day although a login exists.
    ///
    /// Whoever builds profiles from it and reads only the list creates, for exactly these devices, a
    /// profile **without a media server**. After that ``ProfileBook/Situation/showsLibrary``
    /// says "no", and the library disappears for someone who is logged in. That is
    /// not an edge case but the normal case for every device from the time before.
    ///
    /// **The session goes at the end and not at the beginning.** If it is already in the
    /// list, its place applies: The order of the list is the order in which the profiles
    /// arise, and a migration should not reshuffle it.
    public static func jellyfin(
        list: [ServerCredentials], signedIn: ServerCredentials?
    ) -> [Access] {
        var credentials = list.map(Access.init)
        guard let signedIn else { return credentials }
        // **Compared via the account ID and not via the whole case.** Server and
        // user say who this is; the display name may have changed along the way,
        // and a rename must not turn into two profiles for the same
        // human.
        let session = Access(signedIn)
        guard !credentials.contains(where: { $0.legacyAccountID == session.legacyAccountID })
        else { return credentials }
        credentials.append(session)
        return credentials
    }
}
