import Core
import Foundation
import PlaylistKit
import ProfileKit
import Testing

@testable import FeaturesPhone

/// **AP41, row 6 on the phone:** ``SetupState`` answers from the
/// ``ProfileKit/ProfileBook`` and no longer from the device.
///
/// The finding at issue is in the roadmap: A channel list hung on the device and applied
/// to everyone who picked it up — a child profile saw the same 7,746 channels as
/// the adult profiles.
@Suite("The setup state asks the profile")
struct ProfileShellTests {

    private static let server = URL(string: "http://server.example:8096")!

    @MainActor
    private struct Build {
        let sharedStore: SecureStore
        let listen: PlaylistStore
        let parameters: UserDefaults
        let ledger = InMemoryStore()
        let state: SetupState

        init() {
            let name = "probe.\(UUID().uuidString)"
            sharedStore = SecureStore(service: name)
            listen = PlaylistStore(store: InMemoryStore(), secrets: InMemoryStore(), ledger: InMemoryStore())
            parameters = UserDefaults(suiteName: name) ?? .standard
            state = SetupState(
                keychain: sharedStore, listen: listen, store: parameters, ledgerStore: ledger)
        }
    }

    private static func credentials(
        _ user: String, name: String? = nil
    )
        -> ServerCredentials
    {
        ServerCredentials(
            serverURL: server, userID: user, username: name ?? user,
            accessToken: "token-\(user)")
    }

    private static func list(_ identifier: String) -> Playlist {
        Playlist(
            id: identifier, name: identifier.uppercased(),
            kind: .m3u(URL(string: "http://list.example/\(identifier).m3u")!))
    }

    // MARK: - Without a ledger the device applies

    /// **An empty ledger means "not yet taken over" and not "nothing set up".**
    /// Anyone who confuses the two takes the library away from a signed-in viewer.
    @Test("As long as there is no profile, the device state answers")
    @MainActor
    func withoutLedgerDeviceApplies() throws {
        let build = Build()
        build.state.create(jellyfin: Self.credentials("alex"))
        build.state.create(channelList: Self.list("a"), password: nil)
        build.state.set(portals: true)

        #expect(build.state.jellyfin?.userID == "alex")
        #expect(build.state.channelLists.map(\.id) == ["a"])
        #expect(build.state.portalsWanted)
        #expect(build.state.hasContent)
    }

    // MARK: - With a ledger the profile applies

    /// **The finding of AP41.** The list still lies in storage — it just does not belong to
    /// this person.
    @Test("A profile without a channel list sees none, although one is stored")
    @MainActor
    func childDoesNotSeeParentsList() throws {
        let build = Build()
        build.state.create(channelList: Self.list("a"), password: nil)
        #expect(build.listen.playlists.count == 1)

        var ledger = ProfileBook()
        ledger.create(Profile(name: "Child", kind: .kind))
        ledger.write(in: build.ledger)

        #expect(build.state.channelLists.isEmpty)
        #expect(!build.state.hasContent)
    }

    @Test("A profile with the list sees it")
    @MainActor
    func profileWithListSeesIt() throws {
        let build = Build()
        build.state.create(channelList: Self.list("a"), password: nil)
        build.state.create(channelList: Self.list("b"), password: nil)

        var person = Profile(name: "Alex")
        person.create(.channelList(identifier: "b"))
        var ledger = ProfileBook()
        ledger.create(person)
        ledger.write(in: build.ledger)

        #expect(build.state.channelLists.map(\.id) == ["b"])
    }

    /// **The access token stays the Keychain's**, and the profile only decides
    /// whether it applies.
    @Test("A profile without Jellyfin gets none, although one is signed in")
    @MainActor
    func profileWithoutJellyfin() throws {
        let build = Build()
        build.state.create(jellyfin: Self.credentials("alex"))
        #expect((try? build.sharedStore.loadCredentials()) != nil)

        var ledger = ProfileBook()
        ledger.create(Profile(name: "Guest"))
        ledger.write(in: build.ledger)

        #expect(build.state.jellyfin == nil)
    }

    /// **One person's library must not appear under another's name.**
    /// Comparison is by `server|user` and not by "has any".
    @Test("If the profile points to a different account than the session, none applies")
    @MainActor
    func profilePointsToOtherAccount() throws {
        let build = Build()
        build.state.create(jellyfin: Self.credentials("alex"))

        var person = Profile(name: "Child")
        person.create(
            .jellyfin(server: Self.server, userID: "kind", username: "Child"))
        var ledger = ProfileBook()
        ledger.create(person)
        ledger.write(in: build.ledger)

        #expect(build.state.jellyfin == nil)
    }

    @Test("The portal preference comes from the profile and not from the old key")
    @MainActor
    func portalRequestFromProfile() throws {
        let build = Build()
        build.state.set(portals: true)

        var ledger = ProfileBook()
        ledger.create(Profile(name: "Child", kind: .kind))
        ledger.write(in: build.ledger)

        #expect(!build.state.portalsWanted)
        #expect(build.parameters.bool(forKey: SetupState.portalsKey))
    }

    // MARK: - Accesses are created where they are set up

    @Test("An accepted list lands with the active profile")
    @MainActor
    func listLandsAtProfile() throws {
        let build = Build()
        var ledger = ProfileBook()
        ledger.create(Profile(name: "Alex"))
        ledger.write(in: build.ledger)

        build.state.create(channelList: Self.list("a"), password: nil)

        let read = try #require(ProfileBook.read(from: build.ledger).activeProfile)
        #expect(read.channelLists.map(\.channelListID) == ["a"])
        #expect(build.state.channelLists.map(\.id) == ["a"])
    }

    @Test("The portal toggle creates the access and removes it again")
    @MainActor
    func portalToggleOnProfile() throws {
        let build = Build()
        var ledger = ProfileBook()
        ledger.create(Profile(name: "Alex"))
        ledger.write(in: build.ledger)

        build.state.set(portals: true)
        #expect(build.state.portalsWanted)

        build.state.set(portals: false)
        #expect(!build.state.portalsWanted)
        #expect(ProfileBook.read(from: build.ledger).activeProfile?.credentials.isEmpty == true)
    }

    // MARK: - What disappears from the device

    /// **For every profile and not only the active one.** A pointer to a deleted
    /// list would be an access that nobody can open any more.
    @Test("A deleted list disappears from all profiles")
    @MainActor
    func deletedListDisappearsEverywhere() throws {
        let build = Build()
        var parentA = Profile(name: "Parent A")
        parentA.create(.channelList(identifier: "a"))
        var parentB = Profile(name: "Parent B")
        parentB.create(.channelList(identifier: "a"))
        var ledger = ProfileBook()
        ledger.create(parentA)
        ledger.create(parentB)
        ledger.write(in: build.ledger)

        build.state.remove(channelList: "a")

        let read = ProfileBook.read(from: build.ledger)
        #expect(read.profile.allSatisfy { $0.channelLists.isEmpty })
    }

    /// **By account ID and not by display name** — otherwise a renamed account would
    /// stay with one profile.
    @Test("A removed account disappears even with a renamed display name")
    @MainActor
    func removedAccountDisappears() throws {
        let build = Build()
        var person = Profile(name: "Alex")
        person.create(
            .jellyfin(
                server: Self.server, userID: "alex", username: "Alex A."))
        var ledger = ProfileBook()
        ledger.create(person)
        ledger.write(in: build.ledger)

        build.state.remove(account: "\(Self.server.absoluteString)|alex")

        #expect(ProfileBook.read(from: build.ledger).activeProfile?.jellyfin == nil)
    }

    // MARK: - The profiles are created

    /// **The gap between account list and session.** On every phone set up before
    /// 2026-09-06 the list is empty although someone is signed in.
    /// Anyone who read only it would create a profile **without a media server** — and the library
    /// would disappear for someone who is signed in.
    @Test("A sign-in without an entry in the account list still yields a profile with Jellyfin")
    @MainActor
    func loginWithoutAccountList() throws {
        try ProfilePointer.als(nil) {
            let build = Build()
            try build.sharedStore.saveCredentials(Self.credentials("alex", name: "Alex"))
            #expect(build.sharedStore.allAccounts().isEmpty)

            #expect(build.state.createProfiles(fallbackName: "Home"))

            let read = ProfileBook.read(from: build.ledger)
            #expect(read.profile.count == 1)
            #expect(read.activeProfile?.name == "Alex")
            #expect(build.state.jellyfin?.userID == "alex")
        }
    }

    @Test("A second call changes nothing")
    @MainActor
    func secondCallChangesNothing() throws {
        try ProfilePointer.als(nil) {
            let build = Build()
            build.state.create(jellyfin: Self.credentials("alex", name: "Alex"))
            #expect(build.state.createProfiles(fallbackName: "Home"))

            let first = try #require(ProfileBook.read(from: build.ledger).active)
            #expect(!build.state.createProfiles(fallbackName: "Home"))
            #expect(ProfileBook.read(from: build.ledger).active == first)
        }
    }

    /// **From scratch means from scratch.** If the ledger stayed, the next pass would
    /// meet profiles with accesses that no longer exist.
    @Test("Clearing takes the profiles with it")
    @MainActor
    func clearingTakesProfilesAlong() throws {
        ProfilePointer.als(nil) {
            let build = Build()
            build.state.create(jellyfin: Self.credentials("alex", name: "Alex"))
            #expect(build.state.createProfiles(fallbackName: "Home"))

            build.state.clear()

            #expect(ProfileBook.read(from: build.ledger).profile.isEmpty)
        }
    }
}
