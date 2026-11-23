import Core
import Foundation

/// An access as the interface shows it.
///
/// **Server and user identifier together are the identifier.** The same person on two
/// servers is two accounts, two people on one server too. A second sign-in
/// of the same person on the same server is on the other hand **not** a second account but a
/// fresher access token — making two entries of it would mean keeping an expired token
/// and using it at the next switch. This rule does not live here
/// but in ``SecureStore/memorize(_:)``; ``Identifier`` is its counterpart in the
/// interface and must therefore carry exactly the same two fields.
///
/// **Why this is not ``ServerCredentials``.** The access token is in there. A
/// list that is passed through the views to draw a row should carry no
/// secret — and the view needs none of it: a name, a server,
/// the information whether it is a child account.
public nonisolated struct Account: Sendable, Equatable, Identifiable {

    /// Server and user identifier together — the identifier of an account.
    ///
    /// As a type of its own and not as a composed string at the call site:
    /// Whoever rebuilds the mapping builds it differently the second time.
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

        /// The form in which the identifier is held in a store.
        ///
        /// The vertical bar occurs in neither half: An address
        /// does not carry it, and Jellyfin issues user identifiers as hex digits.
        public var stored: String { "\(server)|\(user)" }
    }

    public let server: URL
    public let userID: String
    public let name: String

    /// Whether it is a child account.
    ///
    /// **Lives here and not on the server.** Jellyfin knows user policies but no
    /// "child account" marker; what makes a child account is decided by this app — and
    /// that is why the marker lives here too. Filtering with it only happens in G3; until then
    /// it is information and not a lock, and the interface says so.
    public let kind: Bool

    public var id: Identifier { Identifier(server: server.absoluteString, user: userID) }

    public init(server: URL, userID: String, name: String, kind: Bool) {
        self.server = server
        self.userID = userID
        self.name = name
        self.kind = kind
    }

    /// The letter in the profile circle.
    ///
    /// **A circle with a letter and no picture.** Jellyfin keeps profile pictures,
    /// but not every user has one; a placeholder picture next to a real one looks
    /// like a loading error, a letter next to a letter does not.
    public var initial: String {
        name.first.map { String($0).uppercased() } ?? "?"
    }

    /// The server as it appears in a row — without scheme and without path.
    ///
    /// `https://server.example:8096/` is not legible from three meters away and says
    /// nothing either: Whoever has two servers tells them apart by name, not by port.
    public var serverName: String {
        server.host() ?? server.absoluteString
    }
}

// **``ChildAccountList`` has lived in `ParentalControls` since 2026-09-20** (AP40) — as
// **one** type for both programs, in the ``Core/FileStore`` instead of the Keychain.
//
// It stood here with the reasoning "a store of its own next to the Keychain and
// not in it"; in fact it lay *in* the Keychain, while the phone kept a second
// version in `UserDefaults`. The marker "this is a child account" is not a
// secret — it is structure, and by the rule in `README.md` that belongs in a
// file.
