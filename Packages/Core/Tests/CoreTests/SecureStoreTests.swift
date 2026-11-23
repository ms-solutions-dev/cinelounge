import Foundation
import Testing

@testable import Core

/// Several sessions per server — the prerequisite for an account switch not deleting
/// an image cache.
@Suite("Account list")
struct AccountListTests {

    private static func credential(
        _ server: String, _ user: String, tag: String = "m"
    ) throws -> ServerCredentials {
        ServerCredentials(
            serverURL: try #require(URL(string: server)), userID: user,
            username: user, accessToken: tag)
    }

    private static func storage() -> SecureStore {
        SecureStore(service: "probe.\(UUID().uuidString)")
    }

    /// **The same person on two servers is two accounts.**
    @Test("Server and user ID together make the account")
    func serverAndUser() throws {
        let store = Self.storage()
        try store.memorize(try Self.credential("http://a.beispiel", "max"))
        try store.memorize(try Self.credential("http://b.beispiel", "max"))
        try store.memorize(try Self.credential("http://a.beispiel", "yusuf"))

        #expect(store.allAccounts().count == 3)
        try? store.remove("server.accounts")
    }

    /// **A second sign-in is not a second account but a fresher token.** Turning it into
    /// two entries would mean keeping an expired token.
    @Test("The same sign-in replaces itself")
    func secondSignInReplaces() throws {
        let store = Self.storage()
        try store.memorize(try Self.credential("http://a.beispiel", "max", tag: "old"))
        try store.memorize(try Self.credential("http://a.beispiel", "max", tag: "new"))

        #expect(store.allAccounts().count == 1)
        #expect(store.allAccounts().first?.accessToken == "new")
        try? store.remove("server.accounts")
    }

    /// **The switch is an assignment and not an operation that can fail** — exactly that is
    /// why the image cache stays.
    @Test("A switch sets the signed-in session without signing in again")
    func switchSetsSession() throws {
        let store = Self.storage()
        let firstCredential = try Self.credential("http://a.beispiel", "max", tag: "one")
        let second = try Self.credential("http://a.beispiel", "yusuf", tag: "two")
        try store.memorize(firstCredential)
        try store.memorize(second)

        try store.switchTo(server: second.serverURL, user: "yusuf")
        #expect(try store.loadCredentials().accessToken == "two")

        try store.switchTo(server: firstCredential.serverURL, user: "max")
        #expect(try store.loadCredentials().accessToken == "one")

        try? store.clearCredentials()
        try? store.remove("server.accounts")
    }

    @Test("Switching to an unknown account is not possible")
    func unknownAccount() throws {
        let store = Self.storage()
        #expect(throws: SecureStore.Failure.notFound) {
            try store.switchTo(
                server: try #require(URL(string: "http://a.beispiel")), user: "niemand")
        }
    }

    /// **A removed account is one entry less and not a cleanup.**
    @Test("Forgetting removes exactly one entry")
    func forgetRemovesOne() throws {
        let store = Self.storage()
        let firstCredential = try Self.credential("http://a.beispiel", "max")
        try store.memorize(firstCredential)
        try store.memorize(try Self.credential("http://a.beispiel", "yusuf"))

        try store.forget(server: firstCredential.serverURL, user: "max")

        #expect(store.allAccounts().map(\.userID) == ["yusuf"])
        try? store.remove("server.accounts")
    }

    // MARK: - Umzug

    /// **A move is not a sign-in.**
    ///
    /// Whoever solves the move via sign-out and new sign-in takes along snapshots, image
    /// cache and tokens — exactly what this list is meant to avoid. The access token
    /// belongs to the server and not to its address; it survives the move unchanged.
    @Test("A move rewrites addresses and keeps the access token")
    func migrationKeepsTheMark() throws {
        let store = Self.storage()
        let old = try #require(URL(string: "http://a.beispiel"))
        let fresh = try #require(URL(string: "http://a.beispiel:8096"))
        let other = try #require(URL(string: "http://b.beispiel"))

        try store.memorize(try Self.credential("http://a.beispiel", "max", tag: "m1"))
        try store.memorize(try Self.credential("http://a.beispiel", "yusuf", tag: "m2"))
        try store.memorize(try Self.credential("http://b.beispiel", "max", tag: "m3"))
        try store.saveCredentials(try Self.credential("http://a.beispiel", "max", tag: "m1"))

        // **A server that moves takes its accounts with it** — but only its own.
        #expect(try store.relocate(from: old, after: fresh) == 2)

        let list = store.allAccounts()
        #expect(list.filter { $0.serverURL == fresh }.count == 2)
        #expect(list.filter { $0.serverURL == other }.count == 1)
        #expect(list.first { $0.userID == "max" && $0.serverURL == fresh }?.accessToken == "m1")
        #expect(try store.loadCredentials().serverURL == fresh, "the session moves along")

        try? store.remove("server.accounts")
        try? store.clearCredentials()
    }

    /// **Credentials from before this line carry no identifier** — and must nevertheless
    /// remain readable. A non-optional field would make reading fail and tell every
    /// existing user that they are signed out.
    @Test("Credentials without a server ID stay readable")
    func oldCredentialRemainsReadable() throws {
        let store = Self.storage()
        // Verbatim what was in the Keychain before this line: four fields, and no
        // `serverID`. The backslash at the end of the line is a continuation — the string is
        // single-line.
        let legacy = """
            {"serverURL":"http://a.beispiel","userID":"max",\
            "username":"Max","accessToken":"marke"}
            """
        try store.set(legacy, for: "server.credentials")

        let read = try store.loadCredentials()
        #expect(read.userID == "max")
        #expect(read.serverID == nil, "it fills in at the next sign-in")

        try? store.clearCredentials()
    }

    /// The old store remains what it was — **the signed-in session.**
    @Test("The list sits beside the old store, not in its place")
    func listSitsBeside() throws {
        let store = Self.storage()
        let one = try Self.credential("http://a.beispiel", "max")
        try store.saveCredentials(one)

        #expect(store.allAccounts().isEmpty, "Saving alone does not fill the list")
        #expect(try store.loadCredentials() == one)

        try? store.clearCredentials()
    }
}
