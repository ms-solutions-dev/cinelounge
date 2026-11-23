import Core
import Flows
import Foundation
import ParentalControls
import PlaylistKit
import Testing

@testable import FeaturesPhone

/// Accounts: a switch is not a sign-out, and a child account is created exactly once.
@Suite("Accounts")
struct AccountsTests {

    private static func makeStore() -> SecureStore {
        SecureStore(service: "probe.\(UUID().uuidString)")
    }

    /// **Since 2026-09-20 the shared type from `ParentalControls`** (AP40) — and
    /// therefore an in-memory store instead of a separate `UserDefaults` collection.
    private static func childList() -> ChildAccountList {
        ChildAccountList(store: InMemoryStore())
    }

    /// An invented host name, **as a value and not as a literal.** That way it does not look
    /// like a language key — and the same message found a real bug on 2026-09-06,
    /// because a name from this household stood in a check.
    static let home = "a" + ".example"
    static let address = "http://" + home

    private static func credential(_ server: String, _ user: String) throws -> ServerCredentials {
        ServerCredentials(
            serverURL: try #require(URL(string: server)), userID: user,
            username: user.capitalized, accessToken: "token-\(user)")
    }

    /// **Server and user ID together are the account.**
    @Test("Two people on one server are two accounts")
    @MainActor
    func twoAccounts() throws {
        let store = Self.makeStore()
        let model = AccountsModel(keychain: store, childAccounts: Self.childList())

        model.accept(try Self.credential(Self.address, "max"), asChild: false)
        model.accept(try Self.credential(Self.address, "yusuf"), asChild: true)

        #expect(model.accounts.count == 2)
        #expect(model.accounts.filter(\.kind).map(\.name) == ["Yusuf"])
        try? store.remove("server.accounts")
        try? store.clearCredentials()
    }

    /// **The switch does not sign out.** That is exactly why the image downloads stay.
    @Test("After a switch both accounts are still in the list")
    @MainActor
    func switchKeepsBoth() throws {
        let store = Self.makeStore()
        let model = AccountsModel(keychain: store, childAccounts: Self.childList())
        model.accept(try Self.credential(Self.address, "max"), asChild: false)
        model.accept(try Self.credential(Self.address, "yusuf"), asChild: false)

        let first = try #require(model.accounts.first { $0.name == "Max" })
        model.switchTo(zu: first)

        #expect(model.signedIn == first.id)
        #expect(model.accounts.count == 2, "a switch removes nothing")
        try? store.remove("server.accounts")
        try? store.clearCredentials()
    }

    /// **Only for the last account is Remove a sign-out.** As long as a second one exists,
    /// the warning would be a threat without cause.
    @Test("Whether a warning is shown depends on whether it is the last one")
    @MainActor
    func warningOnlyForLast() throws {
        let store = Self.makeStore()
        let model = AccountsModel(
            keychain: store, childAccounts: Self.childList(), revoke: { _ in })
        model.accept(try Self.credential(Self.address, "max"), asChild: false)
        model.accept(try Self.credential(Self.address, "yusuf"), asChild: false)

        let one = try #require(model.accounts.first)
        #expect(!model.isLast(one))

        model.remove(one)
        let remaining = try #require(model.accounts.first)
        #expect(model.isLast(remaining))
        try? store.remove("server.accounts")
        try? store.clearCredentials()
    }

    /// The child flag belongs to the device, not to the server.
    @Test("A removed account takes its child flag with it")
    @MainActor
    func markDisappearsWith() throws {
        let store = Self.makeStore()
        let list = Self.childList()
        let model = AccountsModel(keychain: store, childAccounts: list, revoke: { _ in })
        model.accept(try Self.credential(Self.address, "yusuf"), asChild: true)

        let kind = try #require(model.accounts.first)
        #expect(list.isChild(kind.id.stored))

        model.remove(kind)
        #expect(!list.isChild(kind.id.stored))
        try? store.remove("server.accounts")
        try? store.clearCredentials()
    }

    /// **Remove signs out at the server** (setup check, E11, 2026-09-27) — with the
    /// flag of exactly this account.
    @Test("A removed account is signed out at the server")
    @MainActor
    func removalRevokes() async throws {
        let store = Self.makeStore()
        let revoked = RevocationCollector()
        let model = AccountsModel(
            keychain: store, childAccounts: Self.childList(),
            revoke: { await revoked.take($0.accessToken) })
        model.accept(try Self.credential(Self.address, "max"), asChild: false)
        model.accept(try Self.credential(Self.address, "yusuf"), asChild: false)

        let childAccount = try #require(model.accounts.first { $0.userID == "yusuf" })
        model.remove(childAccount)
        for _ in 0..<100 where await revoked.all.isEmpty {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(await revoked.all == ["token-yusuf"])
        #expect(model.accounts.map(\.userID) == ["max"])
        try? store.remove("server.accounts")
        try? store.clearCredentials()
    }

    // MARK: - The chain from the Keychain to the circle

    /// **The counter-check to what E22 repaired.**
    ///
    /// The write fix (`memorize` before `saveCredentials`) lives in ``SetupState``, and
    /// whether it holds is not decided there: Setup writes, ``AccountsModel``
    /// reads, and the profile picture shows a letter. Three places, one Keychain
    /// — and until 2026-09-06 the chain was severed at the first place and hard-wired at the
    /// last to a fixed personal name (five times).
    ///
    /// **The circle before setup is a question mark and not a name.** That is half
    /// of the finding: It asserted a person even when there was no account at
    /// all.
    @Test("What setup stores then shows up in the sheet and in the circle")
    @MainActor
    func chainHolds() throws {
        let store = Self.makeStore()
        let setup = SetupState(
            keychain: store,
            listen: PlaylistStore(store: InMemoryStore(), secrets: InMemoryStore(), ledger: InMemoryStore()),
            store: UserDefaults(suiteName: "probe.\(UUID().uuidString)") ?? .standard,
            ledgerStore: InMemoryStore())
        let accounts = AccountsModel(keychain: store, childAccounts: Self.childList())
        let wrapper = ShellModel(accounts: accounts)

        #expect(wrapper.accountName == "?", "before setup the circle knows nobody")

        setup.create(jellyfin: try Self.credential(Self.address, "max"))
        wrapper.adopt(.fromAccesses(jellyfin: true))

        #expect(accounts.accounts.count == 1, "the list the sheet hangs on")
        #expect(accounts.signedInAccount?.name == "Max", "and which of them is signed in")
        #expect(wrapper.accountName == "Max", "the same person in the circle")

        try? store.remove("server.accounts")
        try? store.clearCredentials()
    }

    // MARK: - Move or second server

    /// **The difference on which the whole screen hangs.**
    ///
    /// Anyone who moves still has one server — with the same account, the same
    /// progress and the same favorites; anyone who adds a second has two. Treated as a
    /// "second server", the same catalog would appear twice in the register, and the
    /// old entry would point into the void.
    @Test("The identifier is compared — and where there is none, nothing is guessed")
    func moveComparesIdentifiers() {
        let same = ServerMigrationFlow.finding(reported: "abc", previous: "abc", name: "vault")
        #expect(same == .sameOne(name: "vault"))

        // **The same name is no proof.** "Jellyfin" is the delivery name.
        let foreign = ServerMigrationFlow.finding(reported: "xyz", previous: "abc", name: "vault")
        #expect(foreign == .other(name: "vault"))

        let legacy = ServerMigrationFlow.finding(reported: "abc", previous: nil, name: "vault")
        #expect(legacy == .withoutIdentifier(name: "vault"), "guessing would be the worst answer")
    }

    /// **The path that did not exist here until 2026-09-21** (AP41).
    ///
    /// Without a verifiable ID the message stood there and `isAdoptable` stayed `false` — a
    /// dead end for everyone whose access dates from before ``ServerCredentials/serverID``.
    /// The TV showed a sentence and a button below it in the same case.
    /// **It does not guess, it asks** — and as of today that is the common rule
    /// (``Core/ServerMove``).
    @MainActor
    @Test("Without an identifier the move continues — but only after explicit consent")
    func withoutIdentifierWithConsent() {
        #expect(ServerMove.mayMove(.withoutIdentifier(name: "vault"), confirmed: false) == false)
        #expect(ServerMove.mayMove(.withoutIdentifier(name: "vault"), confirmed: true))
        // **A consent does not cancel a finding that speaks against it.** Anyone who presses "yes"
        // confirms that checking was not possible — not that it is the same
        // server.
        #expect(ServerMove.mayMove(.other(name: "vault"), confirmed: true) == false)
    }

    /// **The button writes nothing as long as nothing has been checked.** That was exactly the
    /// objection in the roadmap: "without it the move would be a button that guesses".
    @Test("Without a comparison the move adopts nothing")
    @MainActor
    func moveWithoutReconciliationWritesNothing() throws {
        let store = Self.makeStore()
        let credential = try Self.credential(Self.address, "max")
        try store.saveCredentials(credential)
        try store.memorize(credential)

        let model = ServerMigrationFlow(sessionFrom: store)
        model.address = "http://" + "b" + ".example"
        #expect(!model.isAdoptable)

        model.adopt()

        #expect(try store.loadCredentials().serverURL == credential.serverURL)
        #expect(store.allAccounts() == [credential])

        try? store.remove("server.accounts")
        try? store.clearCredentials()
    }

    /// A profile picture without a letter is a gray circle.
    @Test("The initial comes from the name")
    func initial() throws {
        let account = Account(
            server: try #require(URL(string: Self.address)), userID: "x",
            name: "max", kind: false)
        #expect(account.initial == "M")
    }
}

private actor RevocationCollector {
    private(set) var all: [String] = []
    func take(_ value: String) { all.append(value) }
}
