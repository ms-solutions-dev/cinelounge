import CloudSync
import Core
import Foundation
import Testing

@testable import ProfileKit

/// The reconciliation between ledgers and zones — against the ``CloudSync/MockCloud``,
/// so without network and without an iCloud account.
@Suite("The profile in the cloud")
@MainActor
struct ProfileCloudTests {

    let server = MockCloud()
    let identifier = Profile.Identifier(rawValue: UUID().uuidString)

    func device(_ name: String = "max") -> (ProfileCloud, InMemoryStore) {
        let store = InMemoryStore()
        let hub = CloudHub(
            service: server.credential(name), file: nil,
            device: DeviceDescription(identifier: name, name: name, model: "Test rig"))
        return (
            ProfileCloud(hub: hub, store: store, moveBundle: nil, automatic: false), store
        )
    }

    func profile(name: String = "Max") -> Profile {
        var profile = Profile(identifier: identifier, name: name, color: .turquoise)
        profile.create(.channelList(identifier: "xtream|panel.example|max"))
        return profile
    }

    func create(_ profile: Profile, in store: InMemoryStore) {
        var ledger = ProfileBook.read(from: store)
        ledger.create(profile)
        ledger.write(in: store)
    }

    // MARK: - The circle

    @Test("What is created on the TV shows up on the phone afterwards")
    func backAndForth() async throws {
        let (tv, ablageTV) = device()
        let person = profile()
        create(person, in: ablageTV)

        var state = StillLedger.read(from: ablageTV, forItem: identifier.rawValue)
        state.record(.titlePosition(title: "film1", location: 4350, duration: 7200))
        state.record(.senderfavorit(key: "das erste hd", true))
        state.write(in: ablageTV, forItem: identifier.rawValue)

        await tv.reconcile(person)

        let (phone, ablagePhone) = device()
        create(Profile(identifier: identifier, name: "noch namenlos"), in: ablagePhone)
        await phone.reconcile(ProfileBook.read(from: ablagePhone).profile[0])

        let arrived = ProfileBook.read(from: ablagePhone).profile[0]
        #expect(arrived.name == "Max")
        #expect(arrived.color == .turquoise)
        #expect(arrived.credentials == [.channelList(identifier: "xtream|panel.example|max")])

        let statePhone = StillLedger.read(from: ablagePhone, forItem: identifier.rawValue).state
        #expect(statePhone.titlePositions["film1"]?.location == 4350)
        #expect(statePhone.channelFavorites == ["das erste hd"])
    }

    /// **The second sync pass writes nothing.**
    ///
    /// ``CloudSync/ProfileZone/write(_:now:)`` queues every record and sets `changed`
    /// anew. If the reconciliation wrote the whole ledger in every time, the device that
    /// merely **repeats** would beat the one that really changed something — and nobody would see
    /// it, because both states would look plausible.
    @Test("A pass without changes uploads nothing")
    func onlyTheDifference() async throws {
        let (tv, store) = device()
        let person = profile()
        create(person, in: store)

        #expect(tv.upload(person) > 0)
        await tv.reconcile(person)
        #expect(tv.upload(person) == 0)

        // A real change is queued, to be sure — and only it.
        var state = StillLedger.read(from: store, forItem: identifier.rawValue)
        state.record(.titlePosition(title: "film1", location: 120, duration: 100))
        state.write(in: store, forItem: identifier.rawValue)
        #expect(tv.upload(person) == 1)
    }

    /// **What arrives must not go into the journal.** The journal is outgoing mail (AP42); an
    /// entry for something that just arrived would go upward again on the next sync pass, and
    /// two devices would push the same state to each other endlessly.
    @Test("An arrived state does not fill the outbox")
    func noReturnMail() async throws {
        let (tv, ablageTV) = device()
        let person = profile()
        create(person, in: ablageTV)
        var state = StillLedger.read(from: ablageTV, forItem: identifier.rawValue)
        state.record(.titlePosition(title: "film1", location: 99, duration: 100))
        state.write(in: ablageTV, forItem: identifier.rawValue)
        await tv.reconcile(person)

        let (phone, ablagePhone) = device()
        create(person, in: ablagePhone)
        let previous = StillLedger.read(from: ablagePhone, forItem: identifier.rawValue).journal.count
        await phone.reconcile(person)

        let ledger = StillLedger.read(from: ablagePhone, forItem: identifier.rawValue)
        #expect(ledger.state.titlePositions["film1"]?.location == 99)
        #expect(ledger.journal.count == previous)
    }

    /// **On first contact the cloud wins — but it takes nothing away.**
    ///
    /// The ledgers keep no change time per field. Everything a device writes upward
    /// would therefore carry the timestamp *now* and beat every value of the other
    /// device, however old the local one is — a freshly set up phone would flatten the
    /// TV's state. What the cloud does not know yet still goes
    /// upward.
    @Test("On first contact the cloud wins, local data stays anyway")
    func firstContact() async throws {
        let (tv, ablageTV) = device()
        let person = profile(name: "Max")
        create(person, in: ablageTV)
        var top = StillLedger.read(from: ablageTV, forItem: identifier.rawValue)
        top.record(.titlePosition(title: "film-wolke", location: 4350, duration: 7200))
        top.write(in: ablageTV, forItem: identifier.rawValue)
        await tv.reconcile(person)

        // The phone knows the same profile under a different name and has a
        // title of its own that the cloud does not know.
        let (phone, ablagePhone) = device()
        create(Profile(identifier: identifier, name: "Platzhalter", color: .coral), in: ablagePhone)
        var bottom = StillLedger.read(from: ablagePhone, forItem: identifier.rawValue)
        bottom.record(.titlePosition(title: "film-lokal", location: 600, duration: 1200))
        bottom.write(in: ablagePhone, forItem: identifier.rawValue)

        await phone.reconcile(ProfileBook.read(from: ablagePhone).profile[0])

        let following = ProfileBook.read(from: ablagePhone).profile[0]
        #expect(following.name == "Max")
        #expect(following.color == .turquoise)

        let state = StillLedger.read(from: ablagePhone, forItem: identifier.rawValue).state
        #expect(state.titlePositions["film-wolke"]?.location == 4350)
        #expect(state.titlePositions["film-lokal"]?.location == 600)

        // And from the second sync pass on, what happens here applies again.
        var now = StillLedger.read(from: ablagePhone, forItem: identifier.rawValue)
        now.record(.titlePosition(title: "film-wolke", location: 20, duration: 7200))
        now.write(in: ablagePhone, forItem: identifier.rawValue)
        await phone.reconcile(ProfileBook.read(from: ablagePhone).profile[0])
        #expect(
            StillLedger.read(from: ablagePhone, forItem: identifier.rawValue).state
                .titlePositions["film-wolke"]?.location == 20)
    }

    // MARK: - Finding

    /// **The sentence AP43 is built for:** A profile created on the phone then appears
    /// in the switcher on the TV, without anyone creating it there again.
    @Test("A profile created on the phone is found on the TV")
    func found() async throws {
        let (phone, ablagePhone) = device()
        let person = profile(name: "Sina")
        create(person, in: ablagePhone)
        await phone.reconcile(person)

        let (tv, ablageTV) = device()
        #expect(ProfileBook.read(from: ablageTV).profile.isEmpty)

        let found = await tv.find()
        #expect(found.map(\.name) == ["Sina"])
        #expect(tv.adopt(found) == 1)
        #expect(ProfileBook.read(from: ablageTV).profile.map(\.name) == ["Sina"])

        // A second run finds nothing more — it is already there.
        #expect(await tv.find().isEmpty)
    }

    /// A zone that is only just being created does not have its `name` yet. Building an
    /// empty profile from it would mean putting an empty circle into the switcher.
    @Test("A nameless zone does not become a profile")
    func nameless() async throws {
        let (tv, _) = device()
        let zone = ZoneID(profile: UUID())
        try await server.credential("max").create(zone)
        #expect(await tv.find().isEmpty)
    }

    /// **AP88: the first setup has to tell "empty" from "unread".** An empty iCloud offers
    /// "New profile" at once; an unread one waits for its deadline. ``ProfileCloud/find(now:)``
    /// answers `[]` for both, and stays so for the sync.
    @Test("The setup's search tells found, empty, no account and unread apart")
    func findReporting() async throws {
        let (phone, phoneStore) = device()
        let person = profile(name: "Sina")
        create(person, in: phoneStore)
        await phone.reconcile(person)

        let (tv, _) = device()
        let reading = await tv.findReporting()
        guard case .found(let found) = reading else {
            Issue.record("expected a found reading, got \(reading)")
            return
        }
        #expect(found.map(\.name) == ["Sina"])

        let (empty, _) = device("leer")
        #expect(await empty.findReporting() == .found([]))

        server.reachable = false
        #expect(await tv.findReporting() == .unread)
        #expect(await tv.find().isEmpty, "the sync keeps its reading")
        server.reachable = true

        server.setAccount("max", .noAccount)
        #expect(await tv.findReporting() == .noAccount)
        server.setAccount("max", .restricted)
        #expect(await tv.findReporting() == .restricted)
    }

    /// **Adopting switches nothing.** Whoever is watching right now should not end up on
    /// another profile in the middle of a film just because one was created on the phone.
    @Test("A found profile does not displace the active one")
    func activeStays() {
        let (tv, store) = device()
        let me = profile()
        var ledger = ProfileBook(profile: [me], active: me.identifier)
        ledger.write(in: store)

        let foreign = Profile(identifier: .fresh(), name: "Selin")
        #expect(tv.adopt([foreign]) == 1)
        ledger = ProfileBook.read(from: store)
        #expect(ledger.active == me.identifier)
        #expect(ledger.profile.count == 2)
    }

    /// **What comes from afar lands in the ledger without any action.**
    ///
    /// The silent push goes through ``CloudSync/CloudHub`` and over nobody's
    /// call list. If every place that triggers a sync pass had to call
    /// ``ProfileCloud/download(_:)`` afterwards, the one that forgets would be exactly the one where
    /// the state does not arrive.
    @Test("A remote arrival writes itself into the book")
    func arrival() async throws {
        let (tv, ablageTV) = device()
        let person = profile()
        create(person, in: ablageTV)
        await tv.reconcile(person)

        let (phone, ablagePhone) = device()
        create(person, in: ablagePhone)
        await phone.reconcile(person)

        var reported = 0
        phone.arrival = { reported += 1 }

        // The TV changes something and goes upward.
        var state = StillLedger.read(from: ablageTV, forItem: identifier.rawValue)
        state.record(.titlePosition(title: "film-neu", location: 300, duration: 1200))
        state.write(in: ablageTV, forItem: identifier.rawValue)
        await tv.reconcile(person)

        // The phone only does the sync pass — nobody calls `download`.
        await phone.zone(forItem: identifier)?.reconcile()

        #expect(
            StillLedger.read(from: ablagePhone, forItem: identifier.rawValue).state
                .titlePositions["film-neu"]?.location == 300)
        #expect(reported > 0)
    }

    /// **Without a list connection the reconciliation does not touch the channel lists.**
    ///
    /// This is the most dangerous line of this type: A program that does not manage the lists
    /// — an extension, a preview, a test bench — would otherwise on the first
    /// sync pass **clear them all from the cloud**, because it knows none. And that would arrive on
    /// every one of the viewer's devices.
    @Test("Whoever does not keep the channel lists does not delete them either")
    func withoutListConnection() async throws {
        let (tv, ablageTV) = device()
        let person = profile()
        create(person, in: ablageTV)
        tv.channelLists = {
            [
                ChannelListAccess(
                    key: "xtream|a|b", name: "Anbieter", kind: .xtream,
                    address: URL(string: "http://a")!, user: "b")
            ]
        }
        await tv.reconcile(person)
        #expect(tv.zone(forItem: identifier)?.read(ChannelListMapping.contentType).count == 1)

        // A second device without a connection takes the same path — and leaves them standing.
        //
        // **Twice, and that is the point.** On the first sync pass nothing is cleared
        // anyway (see ``ProfileCloud/reconcile(_:now:)``); the danger lies in the
        // **second**, when the zone counts as known and the reconciliation believes it
        // knows everything that belongs in it.
        let (phone, ablagePhone) = device()
        create(person, in: ablagePhone)
        #expect(phone.channelLists == nil)
        await phone.reconcile(person)
        await phone.reconcile(person)
        #expect(phone.zone(forItem: identifier)?.read(ChannelListMapping.contentType).count == 1)

        await tv.reconcile(person)
        #expect(tv.zone(forItem: identifier)?.read(ChannelListMapping.contentType).count == 1)
    }

    /// A channel list that comes from afar is passed through — with its secret.
    @Test("Arrived channel lists go to the connection")
    func channelListsArrive() async throws {
        let (tv, ablageTV) = device()
        let person = profile()
        create(person, in: ablageTV)
        tv.channelLists = {
            [
                ChannelListAccess(
                    key: "xtream|panel|max", name: "Anbieter",
                    kind: .xtream, address: URL(string: "http://panel")!,
                    user: "max", secret: "kennwort")
            ]
        }
        await tv.reconcile(person)

        let (phone, ablagePhone) = device()
        create(person, in: ablagePhone)
        var arrived: [ChannelListAccess] = []
        phone.channelLists = { [] }
        phone.adoptsChannelLists = { arrived = $0 }
        await phone.reconcile(person)

        #expect(arrived.map(\.key) == ["xtream|panel|max"])
        #expect(arrived.first?.secret == "kennwort")
    }

    // MARK: - Without iCloud

    /// **The explicit requirement from AP43:** "Check that the app keeps running without
    /// iCloud sign-in — profile stays local, no storm of notices."
    ///
    /// Without an account the reconciliation does nothing, **and it takes nothing away either.** The second
    /// part is the more important one: A reconciliation that treats an empty server as the truth
    /// empties the viewer's ledger — and that would be visible on every device
    /// as soon as an account is there again.
    @Test("Without an iCloud account everything stays as it is")
    func withoutAccount() async throws {
        let (tv, store) = device("max")
        server.setAccount("max", .noAccount)

        let person = profile()
        create(person, in: store)
        var state = StillLedger.read(from: store, forItem: identifier.rawValue)
        state.record(.titlePosition(title: "film1", location: 600, duration: 1200))
        state.write(in: store, forItem: identifier.rawValue)

        await tv.reconcile(person)

        // The ledger stands there unchanged.
        #expect(ProfileBook.read(from: store).profile == [person])
        #expect(
            StillLedger.read(from: store, forItem: identifier.rawValue).state
                .titlePositions["film1"]?.location == 600)
        // And nothing was found that there would be to adopt.
        #expect(await tv.find().isEmpty)
    }

    /// And when the account is there later, everything goes upward — **the queue
    /// waited.** Without that, "reconcile later" would be a promise without backing.
    @Test("What was created without an account goes up after sign-in")
    func afterTheFact() async throws {
        let (tv, store) = device("max")
        server.setAccount("max", .noAccount)
        let person = profile()
        create(person, in: store)
        await tv.reconcile(person)

        server.setAccount("max", .available)
        await tv.reconcile(person)

        let (phone, ablagePhone) = device("max")
        create(Profile(identifier: identifier, name: "Platzhalter"), in: ablagePhone)
        await phone.reconcile(ProfileBook.read(from: ablagePhone).profile[0])
        #expect(ProfileBook.read(from: ablagePhone).profile[0].name == "Max")
    }

    // MARK: - Limits

    /// A foreign record type stays put: It comes from a newer program on the
    /// same account, and whoever clears it takes the other device's state away.
    @Test("The sync deletes only what belongs to it")
    func foreignStays() async throws {
        let (tv, store) = device()
        let person = profile()
        create(person, in: store)
        await tv.reconcile(person)

        let zone = try #require(tv.zone(forItem: identifier))
        zone.write(CloudRecord(contentType: "Lesesitzung", name: "s1", fields: ["seiten": .integer(42)]))
        await zone.reconcile()

        tv.upload(person)
        #expect(zone.read("Lesesitzung").count == 1)
    }

    /// No UUID, no zone — and with it no half reconciliation that looks
    /// as if it were running.
    @Test("An identifier without a UUID gets no zone")
    func noZone() {
        let (tv, _) = device()
        #expect(tv.zone(forItem: Profile.Identifier(rawValue: "max")) == nil)
        #expect(tv.upload(Profile(identifier: Profile.Identifier(rawValue: "max"), name: "X")) == 0)
    }

    @Test("The profile identifier is derived from the zone name")
    func idFromZone() {
        let uuid = UUID()
        #expect(
            ProfileCloud.identifier(from: ZoneID(profile: uuid))
                == Profile.Identifier(rawValue: uuid.uuidString))
        #expect(ProfileCloud.identifier(from: ZoneID(name: "etwas-anderes")) == nil)
        #expect(ProfileCloud.identifier(from: ZoneID(name: "profil-keine-uuid")) == nil)
    }

    // MARK: - Diagnostics coverage (2026-09-27)

    /// **The number that ``ProfileCloud/adopt(_:now:)`` has since reported as a line.**
    /// Same Jellyfin server login, different names: no decision possible, both
    /// stay and ``ProfileSync/openQuestions(from:)`` lists the pair — exactly the
    /// value that the new line names under "unresolved". The number is tested via the
    /// existing, already tested store (``ProfileSync``), not via the diagnostic
    /// output itself — that is a side effect via `os.log`/`Trace` and in a
    /// check run with many suites no reliable place for a deterministic check.
    @Test("A sync with the same credential and a different name stays as an open question")
    func syncWithOpenQuestion() {
        let (cloud, store) = device()
        let account = Access.jellyfin(
            server: URL(string: "https://jellyfin.example")!, userID: "max",
            username: "Max")
        var here = Profile(name: "Max")
        here.create(account)
        create(here, in: store)

        var there = Profile(name: "Papa")
        there.create(account)

        let changed = cloud.adopt([there])
        #expect(changed == 1, "the undecided second profile goes into the book")
        #expect(ProfileBook.read(from: store).profile.count == 2)
        #expect(ProfileSync.openQuestions(from: store).count == 1)
    }

    /// **The flip side:** Without a contradiction no open question arises, and the line
    /// stays with the calmer case ("changed", without "unresolved").
    @Test("An unambiguous sync leaves no open question")
    func syncWithoutOpenQuestion() {
        let (cloud, store) = device()
        let here = Profile(name: "Max")
        create(here, in: store)
        let there = Profile(name: "Max")

        _ = cloud.adopt([there])
        #expect(ProfileSync.openQuestions(from: store).isEmpty)
    }
}
