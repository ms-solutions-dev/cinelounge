import Core
import Foundation
import Testing

@testable import ProfileKit

@Suite("The profile book")
struct ProfileBookTests {

    private static let server = URL(string: "https://vault.example:8096")!

    private static func jellyfin(_ name: String) -> Access {
        .jellyfin(server: server, userID: name.lowercased(), username: name)
    }

    // MARK: - Was ein Profil ist

    /// **One Jellyfin server per profile**, several channel lists already: Two Jellyfin logins
    /// would be two truths about the same "Continue Watching" state; channel lists have
    /// no state they could contradict.
    @Test("A second Jellyfin replaces the first, a second list does not")
    func uniqueAccesses() {
        var person = Profile(name: "Max")
        person.create(Self.jellyfin("Max"))
        person.create(Self.jellyfin("Zweit"))
        person.create(.channelList(identifier: "a"))
        person.create(.channelList(identifier: "b"))

        #expect(person.credentials.filter { $0.kind == .jellyfin }.count == 1)
        #expect(person.jellyfin?.displayName == "Zweit")
        #expect(person.channelLists.count == 2)
    }

    @Test("The same access twice stays one")
    func noDuplicates() {
        var person = Profile(name: "Max")
        person.create(.channelList(identifier: "a"))
        person.create(.channelList(identifier: "a"))

        #expect(person.channelLists.count == 1)
    }

    @Test("An empty name yields a question mark and not an empty circle")
    func initial() {
        #expect(Profile(name: "").initial == "?")
        #expect(Profile(name: "max").initial == "M")
    }

    // MARK: - Die Lage

    /// **The replacement for ``Core/AccountState``, and it answers the same questions** —
    /// only for the **person** instead of for the device.
    @Test("The state comes from the active profile and not from the device")
    func stateFollowsProfile() {
        var parents = Profile(name: "Eltern")
        parents.create(Self.jellyfin("Eltern"))
        parents.create(.channelList(identifier: "iptv"))
        var kind = Profile(name: "Kind", kind: .kind)
        kind.create(Self.jellyfin("Kind"))

        var ledger = ProfileBook()
        ledger.create(parents)
        ledger.create(kind)

        #expect(ledger.state.hasChannelList)
        ledger.switchTo(zu: kind.identifier)
        // **This is the whole point of the package.** Until here the channel list hung on the
        // device: The child saw the parents' channels, and no switch changed that.
        #expect(ledger.state.hasChannelList == false)
        #expect(ledger.state.hasMediaServer)
        #expect(ledger.state.showsLive == false)
    }

    @Test("Without a profile nothing is set up — and that is an answer")
    func emptyState() {
        let empty = ProfileBook().state
        #expect(empty.isSetUp == false)
        #expect(empty.offersMediaServer)
    }

    @Test("The portals are a wish and not an access")
    func portalsAreAWish() {
        var person = Profile(name: "Max")
        person.create(.portals(person: nil))
        var ledger = ProfileBook()
        ledger.create(person)

        #expect(ledger.state.isSetUp)
        #expect(ledger.state.showsLibrary == false)
    }

    // MARK: - Wechseln und Entfernen

    @Test("The first profile becomes the active one at the same time")
    func firstBecomesActive() {
        var ledger = ProfileBook()
        let first = Profile(name: "Erste")
        ledger.create(first)
        ledger.create(Profile(name: "Zweite"))

        #expect(ledger.active == first.identifier)
        #expect(ledger.canSwitch)
    }

    @Test("An unknown profile does not become active")
    func unknownDoesNotBecomeActive() {
        var ledger = ProfileBook()
        let first = Profile(name: "Erste")
        ledger.create(first)

        ledger.switchTo(zu: .fresh())

        #expect(ledger.active == first.identifier)
    }

    /// **A ledger without an active profile while profiles exist would be a state the
    /// UI cannot draw.**
    @Test("If the active profile is removed, the first one moves up")
    func removalShiftsUp() {
        var ledger = ProfileBook()
        let first = Profile(name: "Erste")
        let second = Profile(name: "Zweite")
        ledger.create(first)
        ledger.create(second)
        ledger.switchTo(zu: second.identifier)

        ledger.remove(second.identifier)

        #expect(ledger.active == first.identifier)
        #expect(ledger.canSwitch == false)
    }

    @Test("An identifier without a profile is no selection")
    func unknownFromStore() {
        let ledger = ProfileBook(profile: [Profile(name: "Erste")], active: .fresh())
        #expect(ledger.activeProfile?.name == "Erste")
    }

    @Test("Editing leaves the profile in its place")
    func change() {
        var ledger = ProfileBook()
        let person = Profile(name: "Max")
        ledger.create(person)
        ledger.create(Profile(name: "Zweite"))

        ledger.update(person.identifier) { $0.kind = .kind }

        #expect(ledger.profile.first?.kind == .kind)
        #expect(ledger.profile.map(\.name) == ["Max", "Zweite"])
    }

    // MARK: - Ablage

    @Test("Profiles and the active identifier survive writing and reading")
    func storeHolds() {
        let bucket = InMemoryStore()
        var ledger = ProfileBook()
        var parents = Profile(name: "Eltern", color: .turquoise)
        parents.create(Self.jellyfin("Eltern"))
        parents.create(.channelList(identifier: "iptv"))
        let kind = Profile(name: "Kind", color: .coral, kind: .kind)
        ledger.create(parents)
        ledger.create(kind)
        ledger.switchTo(zu: kind.identifier)
        ledger.write(in: bucket)

        let back = ProfileBook.read(from: bucket)

        #expect(back.profile.map(\.name) == ["Eltern", "Kind"])
        #expect(back.activeProfile?.kind == .kind)
        #expect(back.profile.first?.color == .turquoise)
        #expect(back.profile.first?.channelLists.count == 1)
        #expect(back.profile.first?.jellyfin?.displayName == "Eltern")
    }

    @Test("An empty book removes the file")
    func emptyBookCleans() {
        let bucket = InMemoryStore()
        var ledger = ProfileBook()
        let person = Profile(name: "Max")
        ledger.create(person)
        ledger.write(in: bucket)

        ledger.remove(person.identifier)
        ledger.write(in: bucket)

        #expect((try? bucket.value(for: ProfileBook.key)) == nil)
        #expect(ProfileBook.read(from: bucket).profile.isEmpty)
    }

    @Test("Unreadable data in the store yields an empty book and no crash")
    func unreadable() {
        let bucket = InMemoryStore()
        try? bucket.set("{kein JSON", for: ProfileBook.key)

        #expect(ProfileBook.read(from: bucket).profile.isEmpty)
    }

    /// **No password and no access token in the file.** They stay in the
    /// Keychain; only who they belong to is recorded here. From AP43 this file moves into the
    /// cloud — whatever ends up in it here then lies there.
    @Test("The file contains no secret")
    func noSecretsInFile() throws {
        let bucket = InMemoryStore()
        var ledger = ProfileBook()
        var person = Profile(name: "Max")
        person.create(Self.jellyfin("Max"))
        person.create(.channelList(identifier: "iptv"))
        ledger.create(person)
        ledger.write(in: bucket)

        let text = try bucket.value(for: ProfileBook.key)
        #expect(text.contains("vault.example"))
        #expect(text.contains("iptv"))
        // There is no field in which a password could be stored — this check pins that
        // down, so that a later field is noticed here and not only in the cloud.
        #expect(!text.lowercased().contains("kennwort"))
        #expect(!text.lowercased().contains("password"))
        #expect(!text.lowercased().contains("token"))
    }

    // MARK: - Niemand davor

    /// **An emptied "active" stays empty** (check of 2026-09-25 evening): on reading, on
    /// re-storing an existing profile through the reconciliation and on merging
    /// with the cloud. If another one moved up in the process, a profile with a PIN would be in front, without
    /// anyone having entered it.
    @Test("Without an active profile none moves up when reading, storing and merging")
    @MainActor
    func emptyActiveStays() {
        let bucket = InMemoryStore()
        let papa = Profile(name: "Papa")
        let grandmother = Profile(name: "Oma")
        var ledger = ProfileBook()
        ledger.create(papa)
        ledger.create(grandmother)
        #expect(ledger.active == papa.identifier, "the first becomes the active one at the same time")
        ledger.clearActive()
        ledger.write(in: bucket)
        #expect(ProfileBook.read(from: bucket).active == nil)

        var read = ProfileBook.read(from: bucket)
        read.create(papa)
        #expect(read.active == nil, "a sync stores Papa anew and does not make him active")

        ProfileSync.adopt(cloud: [Profile(name: "Selin")], in: bucket)
        #expect(ProfileBook.read(from: bucket).profile.count == 3)
        #expect(ProfileBook.read(from: bucket).active == nil)
    }
}
