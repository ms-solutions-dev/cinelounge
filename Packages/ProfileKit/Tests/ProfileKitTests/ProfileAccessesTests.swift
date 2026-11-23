import Core
import Foundation
import Testing

@testable import ProfileKit

/// **Logins arise where they are set up** (AP41, row 6).
///
/// The callers are holders in the shell that do not know each other: Each reads, changes
/// and writes for itself. What must not go wrong in the process is stated here.
@Suite("Accesses on the active profile")
struct ProfileAccessesTests {

    private static let server = URL(string: "https://vault.example:8096")!

    private static func credential(_ user: String, name: String? = nil) -> Access {
        .jellyfin(
            server: server, userID: user, username: name ?? user)
    }

    private static func ledger(_ names: String...) -> (InMemoryStore, ProfileBook) {
        let bucket = InMemoryStore()
        var ledger = ProfileBook()
        for name in names { ledger.create(Profile(name: name)) }
        ledger.write(in: bucket)
        return (bucket, ledger)
    }

    // MARK: - Ablegen

    @Test("The access lands on the active profile and on no other")
    func createOnlyForActive() throws {
        let (bucket, _) = Self.ledger("Max", "Kind")

        #expect(ProfileAccesses.create(.channelList(identifier: "a"), in: bucket))

        let read = ProfileBook.read(from: bucket)
        #expect(read.activeProfile?.channelLists.count == 1)
        #expect(read.profile.last?.channelLists.isEmpty == true)
    }

    /// **Not a failure, but the state before the first setup.** Startup
    /// creates the profile as soon as there is something to create.
    @Test("Without a profile nothing happens")
    func noProfileNothing() {
        let bucket = InMemoryStore()

        #expect(!ProfileAccesses.create(.channelList(identifier: "a"), in: bucket))
        #expect(ProfileBook.read(from: bucket).profile.isEmpty)
    }

    /// **The same thing twice is once.** Otherwise the UI would count a list twice.
    @Test("The same access twice changes nothing the second time")
    func sameTwice() {
        let (bucket, _) = Self.ledger("Max")

        #expect(ProfileAccesses.create(.channelList(identifier: "a"), in: bucket))
        #expect(!ProfileAccesses.create(.channelList(identifier: "a"), in: bucket))
        #expect(ProfileBook.read(from: bucket).activeProfile?.channelLists.count == 1)
    }

    /// **A second Jellyfin server replaces the first** — ``Access/onlyOnce``. Two would be
    /// two truths about the same "Continue Watching" state.
    @Test("A second Jellyfin replaces the first")
    func mediaServerIsUnique() {
        let (bucket, _) = Self.ledger("Max")

        ProfileAccesses.create(Self.credential("max"), in: bucket)
        ProfileAccesses.create(Self.credential("kind"), in: bucket)

        let read = ProfileBook.read(from: bucket)
        #expect(read.activeProfile?.credentials.count == 1)
        #expect(read.activeProfile?.jellyfin?.displayName == "kind")
    }

    // MARK: - Wegnehmen

    @Test("Every access of a kind goes away — for signing out")
    func removeAllOfOneKind() {
        let (bucket, _) = Self.ledger("Max")
        ProfileAccesses.create(Self.credential("max"), in: bucket)
        ProfileAccesses.create(.channelList(identifier: "a"), in: bucket)

        #expect(ProfileAccesses.removeAll(.jellyfin, in: bucket))

        let read = ProfileBook.read(from: bucket)
        #expect(read.activeProfile?.jellyfin == nil)
        #expect(read.activeProfile?.channelLists.count == 1)
    }

    /// **What disappears from the device disappears everywhere.** A pointer to a
    /// deleted list would be a login that nobody can open any more.
    @Test("A deleted list goes away on all profiles")
    func removeEverywhere() {
        let bucket = InMemoryStore()
        var ledger = ProfileBook()
        for name in ["Mutter", "Vater"] {
            var person = Profile(name: name)
            person.create(.channelList(identifier: "a"))
            person.create(.channelList(identifier: "b"))
            ledger.create(person)
        }
        ledger.write(in: bucket)

        #expect(ProfileAccesses.removeEverywhere(.channelList(identifier: "a"), in: bucket))

        let read = ProfileBook.read(from: bucket)
        #expect(
            read.profile.allSatisfy {
                $0.channelLists.compactMap(\.channelListID) == ["b"]
            })
    }

    /// **By account identifier and not by the whole case.** The display name can
    /// have changed since creation; an account that disappears from the device must
    /// not remain on a profile because of a rename.
    @Test("A removed account goes away even with a changed display name")
    func removeMediaServerDespiteRename() {
        let bucket = InMemoryStore()
        var ledger = ProfileBook()
        var person = Profile(name: "Max")
        person.create(Self.credential("max", name: "Max I."))
        ledger.create(person)
        ledger.write(in: bucket)

        #expect(
            ProfileAccesses.removeMediaServer(
                identifier: "\(Self.server.absoluteString)|max", in: bucket))
        #expect(ProfileBook.read(from: bucket).activeProfile?.jellyfin == nil)
    }

    /// **No writing where nothing changes.** Every write is a file, and a
    /// file that changes for no reason is a backup that grows for no reason.
    @Test("An access nobody has changes nothing")
    func nothingToChange() {
        let (bucket, _) = Self.ledger("Max")

        #expect(!ProfileAccesses.removeEverywhere(.channelList(identifier: "x"), in: bucket))
        #expect(!ProfileAccesses.removeMediaServer(identifier: "gibt|es|nicht", in: bucket))
        #expect(!ProfileAccesses.removeAll(.portals, in: bucket))
    }
}
