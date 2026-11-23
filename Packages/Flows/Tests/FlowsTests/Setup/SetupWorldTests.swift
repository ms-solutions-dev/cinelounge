import Core
import Foundation
import ParentalControls
import ProfileKit
import Testing

@testable import Flows

/// What the setup reads from the device — **Keychain and list store turned into the gate's
/// values** (AP88 §1.5, wave 2).
///
/// Counter-checks: with the device trait read without the profile's compartment
/// ``clServerTraitPerProfile()`` turns red; with the identifier dropped from `newcomer`
/// ``newcomerByIdentifier()``.
@Suite("Setup — reading the device")
struct SetupWorldTests {

    static let server = URL(string: "https://media.example:8096")!
    static let leaAccess = Access.jellyfin(server: server, userID: "lea-id", username: "lea")
    static let leaToken = ServerCredentials(
        serverURL: server, userID: "lea-id", username: "lea", accessToken: "token")

    static func lea() -> Profile {
        var profile = Profile(name: "Lea")
        profile.create(leaAccess)
        return profile
    }

    @Test("A token in the Keychain makes the Jellyfin access usable, the access alone does not")
    func jellyfinNeedsToken() {
        let lea = Self.lea()
        let book = ProfileBook(profile: [lea], active: nil)
        let keychain = InMemoryStore()
        let without = SetupWorld.usable(book: book, accounts: [], channelLists: [], keychain: keychain)
        #expect(SetupWorld.start(book: book, usable: without, describe: { SetupProfile($0) }) != nil)
        let with = SetupWorld.usable(
            book: book, accounts: [Self.leaToken], channelLists: [], keychain: keychain)
        #expect(with.jellyfinAccounts == [Self.leaAccess.legacyAccountID!])
        #expect(SetupWorld.start(book: book, usable: with, describe: { SetupProfile($0) }) == nil)
    }

    @Test("The CL-Server device trait counts in the profile's own compartment")
    func clServerTraitPerProfile() {
        let lea = Self.lea()
        let tom = Profile(name: "Tom")
        let book = ProfileBook(profile: [lea, tom], active: nil)
        let keychain = InMemoryStore()
        DeviceTrait.save("trait", to: ProfileStore(keychain, forItem: tom.identifier.rawValue))
        let usable = SetupWorld.usable(book: book, accounts: [], channelLists: [], keychain: keychain)
        #expect(usable.clServerProfiles == [tom.identifier])
    }

    @Test("A profile is described with its person token and its own limit on this device")
    func describe() {
        let mia = Profile(name: "Mia", kind: .kind)
        let keychain = InMemoryStore()
        #expect(SetupWorld.describe(mia, keychain: keychain) == SetupProfile(mia))
        AgeLimit.write(.from12, in: keychain, forItem: mia.identifier.rawValue)
        #expect(SetupWorld.describe(mia, keychain: keychain).hasOwnLimit)
    }

    @Test("Fresh starts with the profiles in the book, resume with the active one")
    func start() {
        let anna = Profile(name: "Anna")
        let lea = Self.lea()
        let describe: (Profile) -> SetupProfile = { SetupProfile($0) }
        var nobody = ProfileBook(profile: [lea, anna])
        nobody.clearActive()
        #expect(
            SetupWorld.start(book: nobody, usable: .init(), describe: describe)
                == .fresh(known: [SetupProfile(lea), SetupProfile(anna)]))
        #expect(
            SetupWorld.start(
                book: ProfileBook(profile: [lea, anna], active: anna.identifier), usable: .init(),
                describe: describe) == .resume(SetupProfile(anna)))
    }

    @Test("The profile from the phone: the new one in the book, else the one of that name")
    func newcomerByIdentifier() {
        let anna = Profile(name: "Anna")
        let tom = Profile(name: "Tom")
        let before: Set<Profile.Identifier> = [anna.identifier]
        let book = ProfileBook(profile: [anna, tom], active: nil)
        #expect(SetupWorld.newcomer(before: before, in: book)?.identifier == tom.identifier)
        let merged = ProfileBook(profile: [anna], active: nil)
        #expect(SetupWorld.newcomer(before: before, in: merged) == nil)
        #expect(SetupWorld.newcomer(before: before, in: merged, named: "Anna")?.identifier == anna.identifier)
    }

    @Test("A handoff names the profile it carried, even one this TV already knew")
    func arrivalCarriedAndKnown() {
        let anna = Profile(name: "Anna")
        let book = ProfileBook(profile: [anna], active: nil)
        #expect(SetupWorld.arrivals(before: [anna.identifier], in: book) == .none)
        #expect(
            SetupWorld.arrivals(before: [anna.identifier], in: book, carried: [anna.identifier])
                == .one(anna))
    }

    @Test("A handoff with the phone's whole book leaves the choice to A2")
    func arrivalSeveral() {
        let anna = Profile(name: "Anna")
        let tom = Profile(name: "Tom")
        let mia = Profile(name: "Mia", kind: .kind)
        let book = ProfileBook(profile: [anna, tom, mia], active: nil)
        #expect(
            SetupWorld.arrivals(
                before: [anna.identifier], in: book, carried: [tom.identifier, mia.identifier])
                == .several([tom, mia]))
        #expect(SetupWorld.arrivals(before: [anna.identifier], in: book) == .several([tom, mia]))
        #expect(SetupWorld.arrivals(before: [anna.identifier, tom.identifier], in: book) == .one(mia))
        #expect(
            SetupWorld.arrivals(before: Set(book.profile.map(\.identifier)), in: book, named: "Tom")
                == .one(tom), "the pairing reports a name")
    }

    @Test("One arrival leads into A4, several into A2, none into nothing")
    func arrivalInput() {
        let anna = Profile(name: "Anna")
        let tom = Profile(name: "Tom")
        let describe: (Profile) -> SetupProfile = { SetupProfile($0) }
        #expect(SetupWorld.Arrival.one(anna).input(describe: describe) == .profileFetched(SetupProfile(anna)))
        #expect(
            SetupWorld.Arrival.several([anna, tom]).input(describe: describe)
                == .profilesArrived([SetupProfile(anna), SetupProfile(tom)]))
        #expect(SetupWorld.Arrival.none.input(describe: describe) == nil)
    }

    @Test("Taking over the lists copies only IPTV, never Jellyfin, and nothing twice")
    func copyChannelLists() {
        var anna = Profile(name: "Anna")
        anna.create(Self.leaAccess)
        anna.create(.channelList(identifier: "list-1"))
        anna.create(.channelList(identifier: "list-2"))
        var mia = Profile(name: "Mia", kind: .kind)
        mia.create(.channelList(identifier: "list-2"))
        let store = InMemoryStore()
        ProfileBook(profile: [anna, mia], active: mia.identifier).write(in: store)

        #expect(SetupWorld.copyChannelLists(from: anna.identifier, to: mia.identifier, in: store) == 1)
        let copied = ProfileBook.read(from: store).profile.first { $0.identifier == mia.identifier }
        #expect(copied?.channelLists.compactMap(\.channelListID).sorted() == ["list-1", "list-2"])
        #expect(copied?.jellyfin == nil, "Jellyfin stays each profile's own")
        #expect(SetupWorld.copyChannelLists(from: anna.identifier, to: mia.identifier, in: store) == 0)
    }
}
