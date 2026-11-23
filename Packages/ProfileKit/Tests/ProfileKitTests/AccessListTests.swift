import Core
import Foundation
import Testing

@testable import ProfileKit

/// **The gap between the account list and the signed-in session.**
///
/// It is the reason ``Access/jellyfin(list:signedIn:)`` exists at all:
/// On every device set up before 2026-09-06 the list is empty even though someone is
/// signed in.
@Suite("A device's accesses")
struct AccessListTests {

    private static let server = URL(string: "https://vault.example:8096")!

    private static func data(_ user: String, name: String? = nil) -> ServerCredentials {
        ServerCredentials(
            serverURL: server, userID: user, username: name ?? user,
            accessToken: "marke-\(user)")
    }

    @Test("The signed-in session counts even without an entry in the list")
    func sessionWithoutList() {
        let credentials = Access.jellyfin(list: [], signedIn: Self.data("max"))

        #expect(credentials.count == 1)
        #expect(credentials.first?.legacyAccountID == "\(Self.server.absoluteString)|max")
    }

    @Test("If it is already in the list, no second entry is created")
    func noDuplicate() {
        let credentials = Access.jellyfin(
            list: [Self.data("max"), Self.data("kind")],
            signedIn: Self.data("max"))

        #expect(credentials.count == 2)
    }

    /// **A rename must not create a second profile.** Server and user say
    /// who it is; the display name is a display.
    @Test("A different display name is the same person")
    func renamedStaysOne() {
        let credentials = Access.jellyfin(
            list: [Self.data("max", name: "Max")],
            signedIn: Self.data("max", name: "Max I."))

        #expect(credentials.count == 1)
        #expect(credentials.first?.displayName == "Max")
    }

    @Test("Without a sign-in the list stays as it is — even an empty one")
    func withoutSignIn() {
        #expect(Access.jellyfin(list: [], signedIn: nil).isEmpty)
        #expect(Access.jellyfin(list: [Self.data("kind")], signedIn: nil).count == 1)
    }

    /// **The order of the list is the order of the profiles** — the session is appended
    /// at the end and does not re-sort.
    @Test("The session goes at the end")
    func sessionAtEnd() {
        let credentials = Access.jellyfin(
            list: [Self.data("kind")], signedIn: Self.data("max"))

        #expect(credentials.map(\.displayName) == ["kind", "max"])
    }

    @Test("The identifier of a channel list comes out, those of the other kinds do not")
    func channelListID() {
        #expect(Access.channelList(identifier: "abc").channelListID == "abc")
        #expect(Access.portals(person: nil).channelListID == nil)
        #expect(Self.data("max").tag.channelListID == nil)
    }
}

extension ServerCredentials {
    fileprivate var tag: Access { Access(self) }
}
