import Core
import Diagnose
import Flows
import Foundation
import JellyfinKit
import Observation
import ParentalControls

/// Which accounts exist and which one is currently signed in.
///
/// **Switching is not signing out.** Since AP23 the Keychain holds a list per server; a
/// switch changes the signed-in session and touches nothing else. Before that it went
/// through signing out — and signing out takes snapshots, Top Shelf badge and image cache
/// with it. Whoever switched back and forth between two accounts ended up each time with an
/// app that had to refill itself.
@MainActor
@Observable
public final class AccountsModel {

    public private(set) var accounts: [Account] = []
    public private(set) var signedIn: Account.Identifier?

    /// Who is watching right now — **the account and not just its identifier.**
    ///
    /// The profile picture needs a name, parental controls need a rating; both
    /// are attached to the ``Account`` and not to the ``Account/Identifier``. Whoever rebuilds the
    /// mapping at the call site builds it differently the second time.
    public var signedInAccount: Account? {
        accounts.first { $0.id == signedIn }
    }

    /// Where the session lives — **also for the wrapper's profile switch**, so that it switches
    /// the same session that this list reads (``ProfileKit/ProfileSwitch/episode(account:ledgerStore:keychain:pinStore:deviceStore:pin:)``).
    let keychain: SecureStore
    private let childAccounts: ChildAccountList
    /// How a token is revoked on the server — see ``remove(_:)``.
    private let revoke: SignOut.Revocation

    public init(
        keychain: SecureStore = SecureStore(),
        childAccounts: ChildAccountList = ChildAccountList(),
        revoke: @escaping SignOut.Revocation = SignOut.onServer
    ) {
        self.keychain = keychain
        self.childAccounts = childAccounts
        self.revoke = revoke
        load()
    }

    public func load() {
        accounts = keychain.allAccounts().map { credential in
            Account(
                server: credential.serverURL, userID: credential.userID,
                name: credential.username, kind: childAccounts.isChild(Account.Identifier(credential).stored))
        }
        signedIn = (try? keychain.loadCredentials()).map(Account.Identifier.init)
    }

    /// Switches the account — **without deleting anything.**
    public func switchTo(zu account: Account) {
        do {
            try keychain.switchTo(
                server: account.server, user: account.userID)
            signedIn = account.id
            Diagnose.step(.login, "Account switched")
        } catch {
            Diagnose.error(.login, "Account switch failed: \(error)")
        }
    }

    /// Removes an account from the list.
    ///
    /// **A removed account is signed out on the server** (setup check, E11, 2026-09-27). Its
    /// token is revoked (``Flows/SignOut``) — until then this place promised "Signing out
    /// ends the session on the server", and no path called the server. Whoever removes the last
    /// one thereby signs out completely — and only then does the sheet say what is lost along
    /// with it.
    public func remove(_ account: Account) {
        do {
            if let credential = keychain.allAccounts().first(where: {
                $0.serverURL == account.server && $0.userID == account.userID
            }) {
                SignOut.signOut(credential, keychain: keychain, revoke: revoke)
            }
            try keychain.forget(
                server: account.server, user: account.userID)
            if signedIn == account.id { try? keychain.clearCredentials() }
            childAccounts.set(kind: false, forItem: account.id.stored)
            // **And for every profile it belonged to** (AP41). An account that disappears from the
            // device otherwise leaves behind a profile whose library points to a
            // sign-in that no longer exists.
            SetupState(keychain: keychain)
                .remove(account: account.id.stored)
            load()
        } catch {
            Diagnose.error(.login, "Account could not be removed: \(error)")
        }
    }

    /// Takes up a freshly signed-in credential — **into the list, not into the session.**
    ///
    /// **Only the first account is signed in directly**, the one without a predecessor. Every
    /// further one switches through ``ShellModel/addAccount(_:asChild:)`` and thus through the
    /// parental-controls door and the latch of the profile PIN (``ProfileKit/ProfileSwitch``). Until
    /// the check evening of 2026-09-25, taking one up switched the session itself — a profile
    /// that owned the credential was thereby reachable without its PIN.
    public func accept(_ credential: ServerCredentials, asChild kind: Bool) {
        do {
            try keychain.memorize(credential)
            if signedIn == nil { try keychain.saveCredentials(credential) }
            childAccounts.set(kind: kind, forItem: Account.Identifier(credential).stored)
            load()
            // A media server added later is a changed setup —
            // the bar and Home follow it (2026-09-07).
            SetupState.notify()
        } catch {
            Diagnose.error(.login, "Account could not be added: \(error)")
        }
    }

    /// Whether removing this account is at the same time a sign-out.
    public func isLast(_ account: Account) -> Bool {
        accounts.count == 1 && accounts.first?.id == account.id
    }
}

/// An account: one person on one server.
public struct Account: Sendable, Equatable, Identifiable {

    /// **Server and user identifier together.** The same person on two servers is two
    /// accounts, two people on one server too.
    public struct Identifier: Sendable, Equatable, Hashable, Codable {
        /// Stored keys keep their original (German) names — renaming them would
        /// make data written by earlier versions unreadable (AP85 B4).
        private enum CodingKeys: String, CodingKey {
            case server
            case user = "benutzer"
        }

        public let server: String
        public let user: String

        public init(server: String, user: String) {
            self.server = server
            self.user = user
        }

        public init(_ credential: ServerCredentials) {
            self.init(server: credential.serverURL.absoluteString, user: credential.userID)
        }

        public var stored: String { "\(server)|\(user)" }
    }

    public let server: URL
    public let userID: String
    public let name: String
    /// Whether it is a child account.
    ///
    /// **It lives here and not on the server.** Jellyfin knows user policies but no
    /// "child account" flag; what makes a child account is decided by this app —
    /// and that is why the flag lives here as well.
    public let kind: Bool

    public var id: Identifier { Identifier(server: server.absoluteString, user: userID) }

    public init(server: URL, userID: String, name: String, kind: Bool) {
        self.server = server
        self.userID = userID
        self.name = name
        self.kind = kind
    }

    /// The letter in the profile picture.
    public var initial: String {
        String(name.first.map(String.init)?.uppercased() ?? "?")
    }
}

// **``ChildAccountList`` has lived in `ParentalControls` since 2026-09-20** (AP40) — as
// **one** type for both programs.
//
// The reasoning that stood here was the right one and moved along with it: "That an account
// is a child account is no secret — the PIN is one, and that lives elsewhere. Storing a
// flag in the Keychain that nobody needs to protect turns the Keychain into a junk room."
// The TV had it there anyway. Now the list lives in the ``Core/FileStore`` on both, and
// it is no longer `UserDefaults` either — see the table in `ARCHITEKTUR.md`, section 8.
