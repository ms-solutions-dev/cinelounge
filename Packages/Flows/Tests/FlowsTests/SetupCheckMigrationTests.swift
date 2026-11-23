import Core
import Foundation
import JellyfinKit
import ProfileKit
import Testing

@testable import Flows

/// The red reproductions from the "Setup" check of 2026-09-27 (E3, E4, E5, E11)
/// — as guards.
@Suite("Check setup – server move")
@MainActor
struct SetupCheckMigrationTests {

    static let legacy = URL(string: "http://192.0.2.10:8096")!
    static let fresh = URL(string: "http://192.0.2.20:8096")!

    private func flow(
        _ secureStore: SecureStore, identifier: String? = "abc",
        ledgerStore: any KeyValueStore = InMemoryStore()
    ) -> ServerMigrationFlow {
        ServerMigrationFlow(
            from: Self.legacy, serverID: identifier, keychain: secureStore, ledgerStore: ledgerStore,
            verify: { address in (address, .init(serverName: "vault", version: "10.11", id: "abc")) })
    }

    /// E3: After the move, the profile switch emptied the session — the profiles kept
    /// pointing at the old address.
    @Test("After the move the session stays on a profile switch")
    func profileSwitchAfterMigration() async throws {
        let secureStore = SecureStore(service: "probe.\(UUID().uuidString)")
        let credential = ServerCredentials(
            serverURL: Self.legacy, userID: "u1", username: "Alex", accessToken: "token", serverID: "abc")
        try secureStore.memorize(credential)
        try secureStore.saveCredentials(credential)

        let parent = Profile(
            name: "Parent",
            credentials: [.jellyfin(server: Self.legacy, userID: "u1", username: "Alex")])
        let mother = Profile(
            name: "Mother",
            credentials: [.jellyfin(server: Self.legacy, userID: "u1", username: "Alex")])
        let kind = Profile(name: "Child")
        let ledgerStore = InMemoryStore()
        let start = ProfileBook(profile: [parent, mother, kind], active: parent.identifier)
        start.write(in: ledgerStore)

        let migration = flow(secureStore, ledgerStore: ledgerStore)
        migration.address = Self.fresh.absoluteString
        await migration.verify()
        migration.adopt()
        #expect(migration.finding == .relocated(count: 1))

        let following = ProfileBook.read(from: ledgerStore)
        for profile in following.profile where profile.identifier != kind.identifier {
            #expect(
                profile.jellyfin
                    == .jellyfin(server: Self.fresh, userID: "u1", username: "Alex"),
                "\(profile.name) still points to the old address")
        }

        // Switch briefly to the child profile and back to the parent profile.
        ProfilePointer.als(nil) {
            var ledger = ProfileBook.read(from: ledgerStore)
            _ = ProfileSwitch.switchTo(
                zu: kind.identifier, in: &ledger, keychain: secureStore, deviceStore: InMemoryStore(),
                ledgerStore: ledgerStore)
            _ = ProfileSwitch.switchTo(
                zu: parent.identifier, in: &ledger, keychain: secureStore, deviceStore: InMemoryStore(),
                ledgerStore: ledgerStore)
        }

        let session = try? secureStore.loadCredentials()
        #expect(
            session?.serverURL == Self.fresh,
            "Session after switching back: \(String(describing: session?.serverURL))")
    }

    /// E4: The session without an account-list entry did not move and still reported
    /// "moved (0)".
    @Test("The session moves even without an entry in the account list")
    func sessionWithoutList() async throws {
        let secureStore = SecureStore(service: "probe.\(UUID().uuidString)")
        try secureStore.saveCredentials(
            ServerCredentials(
                serverURL: Self.legacy, userID: "u1", username: "Alex", accessToken: "token",
                serverID: "abc"))

        let migration = flow(secureStore)
        migration.address = Self.fresh.absoluteString
        await migration.verify()
        migration.adopt()

        #expect(
            (try? secureStore.loadCredentials())?.serverURL == Self.fresh, "Finding: \(migration.finding)")
        #expect(migration.finding == .relocated(count: 1))
    }

    /// E4, second half: **Nothing moved does not mean "moved".**
    @Test("Without any credential at the old address the move reports it")
    func nothingMigrated() async throws {
        let secureStore = SecureStore(service: "probe.\(UUID().uuidString)")
        let migration = flow(secureStore)
        migration.address = Self.fresh.absoluteString
        await migration.verify()
        migration.adopt()
        #expect(migration.finding == .error("accounts.move.nothingMoved"))
    }

    /// ultra e5, round A.1: **All or nothing.** If no credential moved, the move still wrote
    /// the profiles to the new address — they pointed at a server under which there was no
    /// account.
    @Test("If no credential moves, the profiles stay at the old address too")
    func nothingMigratedLeavesProfiles() async throws {
        let secureStore = SecureStore(service: "probe.\(UUID().uuidString)")
        let parent = Profile(
            name: "Parent",
            credentials: [.jellyfin(server: Self.legacy, userID: "u1", username: "Alex")])
        let ledgerStore = InMemoryStore()
        ProfileBook(profile: [parent], active: parent.identifier).write(in: ledgerStore)

        let migration = flow(secureStore, ledgerStore: ledgerStore)
        migration.address = Self.fresh.absoluteString
        await migration.verify()
        migration.adopt()

        #expect(migration.finding == .error("accounts.move.nothingMoved"))
        let following = ProfileBook.read(from: ledgerStore)
        #expect(
            following.profile.first?.jellyfin
                == .jellyfin(server: Self.legacy, userID: "u1", username: "Alex"))
    }

    /// E5: The move of another profile was checked against the server ID of the **active**
    /// session.
    @Test("The server identifier comes from the account that moves")
    func identifierFromAccount() throws {
        let secureStore = SecureStore(service: "probe.\(UUID().uuidString)")
        let x = URL(string: "http://x.example:8096")!
        let y = URL(string: "http://y.example:8096")!
        let active = ServerCredentials(
            serverURL: x, userID: "a", username: "A", accessToken: "m1", serverID: "server-x")
        try secureStore.memorize(active)
        try secureStore.saveCredentials(active)
        try secureStore.memorize(
            ServerCredentials(
                serverURL: y, userID: "b", username: "B", accessToken: "m2", serverID: "server-y"))

        #expect(ServerMigrationFlow.serverID(server: y, user: "b", in: secureStore) == "server-y")
        #expect(ServerMigrationFlow.serverID(server: x, user: "a", in: secureStore) == "server-x")
        #expect(ServerMigrationFlow.serverID(server: y, user: "fremd", in: secureStore) == nil)
    }
}

@Suite("Check setup – sign-out")
@MainActor
struct SetupCheckSignOutTests {

    /// E11: Signing out did not revoke the token and left it in the account list.
    @Test("Signing out revokes the token and removes the credential from the list")
    func signOutRevokes() async throws {
        let secureStore = SecureStore(service: "probe.\(UUID().uuidString)")
        let server = URL(string: "http://media.example:8096")!
        let parent = ServerCredentials(
            serverURL: server, userID: "parent", username: "Parent", accessToken: "token-parent")
        let mother = ServerCredentials(
            serverURL: server, userID: "mother", username: "Mother", accessToken: "token-mother")
        try secureStore.memorize(parent)
        try secureStore.memorize(mother)
        try secureStore.saveCredentials(parent)

        let revoked = RevocationList()
        await SignOut.signOut(parent, keychain: secureStore) { await revoked.take($0.accessToken) }
            .value

        #expect(await revoked.all == ["token-parent"])
        #expect(!secureStore.allAccounts().contains { $0.userID == "parent" })
        #expect(secureStore.allAccounts().contains { $0.userID == "mother" }, "other accounts stay")
        #expect((try? secureStore.loadCredentials()) == nil)
    }

    /// E11: **The session of another account stays in place.**
    @Test("Signing out one account leaves a foreign session alone")
    func foreignSessionRemains() async throws {
        let secureStore = SecureStore(service: "probe.\(UUID().uuidString)")
        let server = URL(string: "http://media.example:8096")!
        let parent = ServerCredentials(
            serverURL: server, userID: "parent", username: "Parent", accessToken: "token-parent")
        let mother = ServerCredentials(
            serverURL: server, userID: "mother", username: "Mother", accessToken: "token-mother")
        try secureStore.memorize(parent)
        try secureStore.memorize(mother)
        try secureStore.saveCredentials(mother)

        await SignOut.signOut(parent, keychain: secureStore) { _ in }.value
        #expect((try? secureStore.loadCredentials())?.userID == "mother")
    }
}

private actor RevocationList {
    private(set) var all: [String] = []
    func take(_ tag: String) { all.append(tag) }
}
