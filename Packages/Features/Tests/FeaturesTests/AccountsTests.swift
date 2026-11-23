import Core
import Flows
import Foundation
import ParentalControls
import Testing

@testable import Features

// **The machine names carry hyphens, and that is no coincidence.**
// `scripts/strings.py` regards every string of the form `area.name` as a possible
// language key — `vault.example` has exactly this form and was reported as a missing key. An
// entry in its ignore list would be the wrong way out: What is listed there are store keys
// and symbols of the program, not test data. A hyphen breaks the form and costs nothing.

private func identifier(_ server: String, _ user: String) -> Account.Identifier {
    Account.Identifier(server: server, user: user)
}

// MARK: - The identifier

/// **Server and user identifier together**, and both count.
///
/// The rule is in ``SecureStore/memorize(_:)``; what is checked here is that the counterpart in
/// the UI does not interpret it differently. If one of the two halves were left out, two
/// people on one server would be the same account — and a switch would lead to the wrong
/// one.
@Test func identifierDistinguishesServerAndUser() {
    #expect(identifier("https://haus-a.example/", "u1") == identifier("https://haus-a.example/", "u1"))
    #expect(identifier("https://haus-a.example/", "u1") != identifier("https://haus-a.example/", "u2"))
    #expect(identifier("https://haus-a.example/", "u1") != identifier("https://haus-b.example/", "u1"))
}

/// The stored name separates the two halves unambiguously.
///
/// The vertical bar occurs neither in an address nor in a Jellyfin identifier. If they ran
/// into each other without a separator, `haus-a.example` + `bc` and `haus-a.homeb` + `c` would
/// be named the same — and the child-account marker would sit on the wrong entry.
@Test func storedIdentifierSeparatesUniquely() {
    #expect(identifier("haus-a.example", "bc").stored != identifier("haus-a.homeb", "c").stored)
}

// MARK: - What the row shows

/// The initial letter is capitalized — even for a name written in lowercase.
@Test func initialLetterIsUppercase() {
    #expect(account(name: "max").initial == "M")
    #expect(account(name: "Anna").initial == "A")
}

/// **An empty name does not lead to an empty circle.**
///
/// Jellyfin demands a user name, but the access token in the Keychain can come from an older
/// version. A circle without a character looks like a loading error.
@Test func emptyNameGivesQuestionMark() {
    #expect(account(name: "").initial == "?")
}

/// The server is in the row without scheme and without port.
///
/// `https://vault-home.example:8096/` cannot be read from three meters and does not distinguish
/// anything either: Whoever has two servers tells them apart by name.
@Test func serverNameIsOnlyTheHost() {
    #expect(account(server: "https://vault-heim.example:8096/").serverName == "vault-heim.example")
}

// MARK: - The child account list

// **The checks of the ``ChildAccountList`` have been in `KindersicherungTests` since
// 2026-09-20** (AP40) — the type moved there when it became one for both programs. Here
// they would remain a check on a foreign store.

// MARK: - Helpers

private func account(
    server: String = "https://vault-heim.example/",
    user: String = "u1",
    name: String = "Max",
    kind: Bool = false
) -> Account {
    Account(
        server: URL(string: server)!,
        userID: user,
        name: name,
        kind: kind
    )
}

// MARK: - The move

/// **The same server identifier means: the same server, new address.**
@Test func sameIdentifierIsAMove() {
    let state = ServerMigrationFlow.finding(reported: "abc123", previous: "abc123", name: "Vault")
    #expect(state == .sameOne(name: "Vault"))
}

/// **A different identifier is not a move but a second server.**
///
/// The difference is the point of the whole view: A move would take the existing server its
/// address although it still exists.
@Test func differentIdentifierIsNoMove() {
    let state = ServerMigrationFlow.finding(reported: "xyz789", previous: "abc123", name: "Anderer")
    #expect(state == .other(name: "Anderer"))
}

/// **Without a known identifier nothing is guessed.**
///
/// ``ServerCredentials/serverID`` is optional — credentials from the time before do not carry
/// it. A missing comparison must mean neither "yes" nor "no" but must hand the decision
/// visibly to the viewer.
@Test func withoutIdentifierAsksInsteadOfGuessing() {
    let state = ServerMigrationFlow.finding(reported: "xyz789", previous: nil, name: "Vault")
    #expect(state == .withoutIdentifier(name: "Vault"))
}
