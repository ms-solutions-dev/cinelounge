import Core
@_spi(Check) import Flows
import Foundation
import PlaylistKit
import ProfileKit
import Testing

@testable import FeaturesPhone

/// **The phone's first setup on the shared journey** (AP88 wave 6) — finding 1 is gone, and the
/// screens read the same states as the TV's.
///
/// **Finding 1 held on the phone as well:** `SetupState.create` stores with
/// ``ProfileKit/ProfileAccesses/create(_:in:)``, which writes only into the **active** profile,
/// and a fresh phone had none — the path choice of AP21 created the profile only at the end
/// (`createProfiles`), from what lay on the device. A book written from iCloud next to it has no
/// active profile either. These checks run the phone's **real** services
/// (``SetupHub/services(_:journey:)``) against in-memory stores and read the book back.
///
/// Counter-checks: without `.activate` in `SetupMachine.activate(_:effects:)`, or with an
/// `activate` service in ``SetupHub`` that does not switch, ``newProfileGetsItsSources()`` and
/// ``chosenFromCloudGetsJellyfin()`` turn red; ``oldPathLosesTheAccess()`` is the finding itself
/// and stays as it is.
@MainActor
@Suite("Setup — the phone's first setup")
struct SetupJourneyPhoneTests {

    nonisolated static let server = URL(string: "https://media.example:8096")!
    nonisolated static let listAddress = URL(string: "http://liste.example/tv.m3u")!

    @MainActor
    struct Device {
        let stores: SetupHub.Stores

        @MainActor
        init() {
            let name = "probe.\(UUID().uuidString)"
            stores = SetupHub.Stores(
                keychain: SecureStore(service: name), ledger: InMemoryStore(),
                lists: PlaylistStore(
                    store: InMemoryStore(), secrets: InMemoryStore(), ledger: InMemoryStore()),
                defaults: UserDefaults(suiteName: name) ?? .standard, cloud: { nil })
        }

        /// The phone's services — **only the network stays out**, everything that touches the book
        /// is the program's.
        @MainActor
        func services(cloud: CloudAnswer) -> SetupServices {
            var services = SetupHub.services(stores, journey: { nil })
            services.probeCloud = { cloud }
            services.wait = { try? await Task.sleep(for: $0 * 3600) }
            services.watchNetwork = { $0(true) }
            services.search = { .init() }
            services.checkToken = { _ in false }
            services.enroll = { _ in false }
            services.requestJoin = { _ in .none }
            services.adoptCloudProfile = { [stores] in ProfileSync.adopt(cloud: [$0], in: stores.ledger) }
            return services
        }

        @MainActor
        func journey(cloud: CloudAnswer) -> SetupJourney {
            SetupJourney(
                SetupMachine(steps: .phone, start: .fresh(known: []), isPinSet: false, noticeSeen: true),
                services: services(cloud: cloud))
        }

        var book: ProfileBook { ProfileBook.read(from: stores.ledger) }
    }

    static func credential(_ user: String) -> ServerCredentials {
        ServerCredentials(serverURL: server, userID: "\(user)-id", username: user, accessToken: "token")
    }

    @Test("Finding 1: without an active profile the phone's store writes the access nowhere")
    func oldPathLosesTheAccess() {
        ProfilePointer.als(nil) {
            let device = Device()
            device.stores.setupState.create(jellyfin: Self.credential("anna"))
            #expect(device.book.profile.isEmpty)
            #expect(device.book.profile.allSatisfy { $0.jellyfin == nil })
        }
    }

    @Test("A new profile: the Jellyfin sign-in and an IPTV list land in it")
    func newProfileGetsItsSources() async throws {
        try await ProfilePointer.als(nil) { try await newProfileRun() }
    }

    private func newProfileRun() async throws {
        let device = Device()
        let journey = device.journey(cloud: .noAnswer)
        journey.start()
        await journey.settle()
        ProfileSync.adopt(cloud: [Profile(name: "Lea"), Profile(name: "Tom")], in: device.stores.ledger)

        journey.send(.choseNew)
        let draft = ProfileDraft(name: "Anna", color: .moss, kind: .adult, limit: nil, avatar: nil)
        let anna = try #require(device.stores.management.save(draft, existing: nil))
        #expect(device.book.active == nil, "precondition: creating next to others activates nobody")
        let profile = try #require(device.book.profile.first { $0.identifier == anna })
        journey.send(.draftSaved(SetupProfile(profile)))
        #expect(device.book.active == anna, "active before the first source")

        journey.send(.openSource(.jellyfin))
        journey.signedIn(Self.credential("anna"))
        journey.send(.openSource(.channelList))
        let form = SourceFormModel(
            entry: .channelList, state: device.stores.setupState, deviceID: "probe",
            accessInfo: { _, _ in nil })
        form.createList(name: "Liste", address: Self.listAddress)
        journey.send(
            .sourceFinished(.channelList, .done(detail: SetupChannelListStep.detail(form.storedAddress))))

        let stored = try #require(device.book.profile.first { $0.identifier == anna })
        #expect(stored.jellyfin?.displayName == "anna")
        #expect(stored.channelLists.count == 1)
        guard case .sources(let page) = journey.state else {
            Issue.record("expected A4, got \(journey.state)")
            journey.stop()
            return
        }
        #expect(page.row(.jellyfin) == .done(detail: "anna"))
        #expect(page.row(.channelList) == .done(detail: "liste.example"))
        journey.stop()
    }

    @Test("A profile chosen from iCloud: the first Jellyfin sign-in lands in it")
    func chosenFromCloudGetsJellyfin() async {
        await ProfilePointer.als(nil) { await chosenFromCloudRun() }
    }

    private func chosenFromCloudRun() async {
        let device = Device()
        let lea = Profile(name: "Lea")
        let tom = Profile(name: "Tom", color: .coral)
        let journey = device.journey(cloud: .profiles([SetupProfile(lea), SetupProfile(tom)]))
        journey.start()
        await journey.settle()
        ProfileSync.adopt(cloud: [lea, tom], in: device.stores.ledger)
        #expect(device.book.active == nil, "precondition: iCloud sets nobody active")

        journey.send(.chose(lea.identifier))
        journey.send(.openSource(.jellyfin))
        journey.signedIn(Self.credential("lea"))

        #expect(device.book.profile.first { $0.identifier == lea.identifier }?.jellyfin?.displayName == "lea")
        #expect(device.book.profile.first { $0.identifier == tom.identifier }?.jellyfin == nil)
        journey.stop()
    }

    // MARK: - Where the phone's setup begins

    @Test("An empty phone begins at A1, an active profile without sources resumes in A4")
    func entry() {
        let device = Device()
        #expect(SetupHub.entry(stores: device.stores) == .fresh(known: []))

        var book = ProfileBook()
        let anna = Profile(name: "Anna")
        book.create(anna)
        book.switchTo(zu: anna.identifier)
        book.write(in: device.stores.ledger)
        #expect(SetupHub.entry(stores: device.stores) == .resume(SetupProfile(anna)))
    }

    @Test("A profile that can play here lets the gate stay shut, and the shell resumes for the one in front")
    func gateShutResumesActive() throws {
        let device = Device()
        let list = Playlist(name: "Liste", kind: .m3u(Self.listAddress))
        device.stores.lists.add(list, password: nil)
        var book = ProfileBook()
        var lea = Profile(name: "Lea")
        lea.create(.channelList(identifier: list.id))
        let tom = Profile(name: "Tom", color: .coral)
        book.create(lea)
        book.create(tom)
        book.switchTo(zu: tom.identifier)
        book.write(in: device.stores.ledger)

        #expect(SetupHub.start(stores: device.stores) == nil, "Lea can play: no setup by the gate")
        #expect(SetupHub.entry(stores: device.stores) == .resume(SetupProfile(tom)))
    }
}

/// The screens read the machine's values — **the same decisions as the TV's**, without a screen.
@Suite("Setup — the phone's screens")
struct SetupScreensPhoneTests {

    @Test("A4 rows: every state has its look, the same cases as on the TV")
    func rowLooks() {
        let access = Access.jellyfin(
            server: URL(string: "https://media.example:8096")!, userID: "lea-id", username: "lea")
        typealias Look = SetupSourcesView.Look
        let cases: [(Access.Kind, SourceRowState, String?, Look)] = [
            (.jellyfin, .empty, nil, Look(caption: .empty(.jellyfin), badge: .add)),
            (
                .jellyfin, .found(detail: "Wohnzimmer"), nil,
                Look(caption: .foundOn("Wohnzimmer"), badge: .found)
            ),
            (
                .jellyfin, .fromProfile(access), nil,
                Look(caption: .fromProfile(user: "lea", host: "media.example"), badge: .confirm)
            ),
            (
                .channelList, .suggested(from: "Lea"), nil,
                Look(caption: .suggested(from: "Lea"), badge: .takeOver)
            ),
            (.channelList, .done(detail: "Lea"), "Lea", Look(caption: .copied(from: "Lea"), badge: .done)),
            (.channelList, .done(detail: ""), nil, Look(caption: .ready, badge: .done)),
            (.jellyfin, .done(detail: "lea"), nil, Look(caption: .detail("lea"), badge: .done)),
            (.portals, .waiting, nil, Look(caption: .waiting, badge: .waiting)),
            (.portals, .unavailable(.noNetwork), nil, Look(caption: .noNetwork, badge: .unavailable)),
            (
                .portals, .unavailable(.notForChildren), nil,
                Look(caption: .notForChildren, badge: .unavailable)
            ),
        ]
        for (kind, state, copied, expected) in cases {
            #expect(SetupSourcesView.look(kind, state, copiedFrom: copied) == expected, "\(kind) \(state)")
        }
    }

    @Test("A4 speaks with the TV's keys, and all of them are in the shared catalog")
    func sharedKeys() {
        let captions: [SetupSourcesView.Look.Caption] = [
            .empty(.jellyfin), .empty(.channelList), .empty(.portals), .foundOn(""),
            .fromProfile(user: "", host: ""), .suggested(from: ""), .copied(from: ""), .ready, .waiting,
            .noNetwork, .notForChildren,
        ]
        let badges: [SetupSourcesView.Look.Badge] = [.add, .found, .confirm, .takeOver]
        let keys = captions.compactMap(SetupSourcesView.captionKey) + badges.map(SetupSourcesView.badgeKey)
        #expect(keys.count == captions.count + badges.count)
        for key in keys {
            #expect(AppLanguageSetting.catalog(forItem: key) != .main, "\(key) is not shared")
        }
        #expect(SetupSourcesView.captionKey(.detail("x")) == nil)
    }

    @Test("A2's sentence follows the same choice as on the TV")
    func welcomeSubtitle() {
        let lea = SetupProfile(Profile(name: "Lea"))
        func offer(_ cloud: CloudAnswer, cards: [SetupProfile]) -> WelcomeOffer? {
            var machine = SetupMachine(
                steps: .phone, start: .fresh(known: cards), isPinSet: true, noticeSeen: true)
            _ = machine.begin()
            _ = machine.handle(.cloudAnswered(cloud))
            guard case .welcome(let offer) = machine.state else {
                Issue.record("expected A2, got \(machine.state)")
                return nil
            }
            return offer
        }
        #expect(
            offer(.profiles([lea]), cards: []).map(SetupWelcomeView.subtitle) == "setup.welcome.fromCloud")
        #expect(offer(.noProfiles, cards: []).map(SetupWelcomeView.subtitle) == "setup.welcome.fresh")
        #expect(offer(.noProfiles, cards: [lea]).map(SetupWelcomeView.subtitle) == "setup.welcome.known")
        #expect(offer(.noAccount, cards: [])?.canFetch == false, "the phone scans only through iCloud")
        #expect(offer(.noProfiles, cards: [])?.canFetch == true)
    }

    @Test("The back arrow stands where the machine knows a way back")
    func raskoHaubla() {
        let lea = Profile.Identifier(rawValue: "lea")
        let page = SourcesPage(profile: lea, rows: [], focus: nil)
        #expect(!SetupView.hasBack(.probing(introOver: false)))
        #expect(!SetupView.hasBack(.finished(lea)))
        #expect(!SetupView.hasBack(.jellyfin(lea, .fresh)), "A5 draws its own, the sheet answers first")
        #expect(SetupView.hasBack(.creating(isFirst: true, lateCloudHint: false)))
        #expect(SetupView.hasBack(.householdPin(for: lea)))
        #expect(SetupView.hasBack(.networkNotice(then: lea, open: nil)))
        #expect(SetupView.hasBack(.sources(page)))
        #expect(SetupView.hasBack(.channelList(lea)))
        #expect(SetupView.hasBack(.clServer(lea, .searching)))
        #expect(SetupView.hasBack(.fetchingFromPhone(.cloud)))
    }

    @Test("A7 lists what is done or waiting, nothing untouched")
    func doneRows() {
        let rows = [
            SourceRow(kind: .jellyfin, state: .done(detail: "anna")),
            SourceRow(kind: .channelList, state: .empty),
            SourceRow(kind: .portals, state: .waiting),
        ]
        #expect(SetupDoneView.listed(rows).map(\.kind) == [.jellyfin, .portals])
    }

    @Test("A6 pages: one per answer, a child is never asked to request")
    func clServerPages() {
        #expect(SetupClServerView.page(.searching) == .searching)
        #expect(SetupClServerView.page(.notFound) == .notFound)
        #expect(SetupClServerView.page(.childPairing) == .childPairing)
        #expect(SetupClServerView.page(.request(.none)) == .ask)
        #expect(SetupClServerView.page(.request(.notForChildren)) == .childPairing)
        #expect(SetupClServerView.page(.request(.rejected)) == .ended(.rejected))
    }

    @Test("A head names the profile and the source")
    func stepHead() {
        #expect(
            SetupStepHead.title(profile: SetupProfile(Profile(name: "Lea")), source: "IPTV") == "Lea · IPTV")
        #expect(SetupStepHead.title(profile: nil, source: "IPTV") == "IPTV")
    }
}
