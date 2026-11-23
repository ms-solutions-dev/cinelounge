import Foundation
import JellyfinKit
import ProfileKit
import Testing

@testable import Flows

/// The paths of the first setup through the pure machine — **without a clock and without a store**
/// (AP88 §6.1).
///
/// Counter-checks (§6.3), each against the line it guards: without `.activate` in
/// `SetupMachine.activate(_:effects:)` ``returner()`` and ``newHousehold()`` turn red; with an
/// `.activate` in the late-answer branch ``lateInSources()``; without the child switch in
/// `openSource` ``childNeverRequests()``; with `selectable: true` for children
/// ``childWithoutPinIsGrey()``; without the user comparison in `jellyfinSignedIn`
/// ``otherUserAsks()``; with `startSearches` on entering A4 ``newHousehold()`` (G8); with a
/// different "back" target from A4 ``backKeepsProfile()``.
@Suite("Setup — the machine")
struct SetupMachineTests {

    static let server = URL(string: "https://media.example:8096")!
    static let clServer = URL(string: "http://cl.example:8100")!
    static let leaAccess = Access.jellyfin(server: server, userID: "lea-id", username: "lea")

    static let lea: SetupProfile = {
        var profile = Profile(name: "Lea")
        profile.create(leaAccess)
        return SetupProfile(profile)
    }()
    static let tom = SetupProfile(Profile(name: "Tom", color: .coral))
    static let mia = SetupProfile(Profile(name: "Mia", color: .lilac, kind: .kind))
    static let anna = SetupProfile(Profile(name: "Anna", color: .moss))
    static let found = ServerDiscovery.Found(id: "j1", name: "Wohnzimmer", address: server)

    /// A machine and every effect it asked for, in order.
    struct Run {
        var machine: SetupMachine
        var effects: [SetupEffect] = []

        init(
            _ start: SetupMachine.Start = .fresh(known: []), steps: SetupSteps = .tv, pin: Bool = false,
            notice: Bool = false, online: Bool = true
        ) {
            machine = SetupMachine(
                steps: steps, start: start, isPinSet: pin, noticeSeen: notice, online: online)
            effects = machine.begin()
        }

        @discardableResult
        mutating func send(_ inputs: SetupInput...) -> [SetupEffect] {
            var fresh: [SetupEffect] = []
            for input in inputs { fresh += machine.handle(input) }
            effects += fresh
            return fresh
        }

        var state: SetupState { machine.state }

        var page: SourcesPage? {
            if case .sources(let page) = state { return page }
            return nil
        }

        var offer: WelcomeOffer? {
            if case .welcome(let offer) = state { return offer }
            return nil
        }
    }

    // MARK: - W1 Returner

    @Test("W1 Returner: A1 → A2 → notice → A4 → A5 → A7, activate before every source")
    func returner() throws {
        var run = Run()
        #expect(run.effects == [.probeCloud, .watchNetwork], "the iCloud question runs from the cold start")
        #expect(run.send(.introEnded) == [.startCloudDeadline])
        #expect(run.state == .probing(introOver: true))

        let leaving = run.send(.cloudAnswered(.profiles([Self.lea, Self.tom])))
        #expect(leaving.contains(.drawReady))
        #expect(run.offer?.focus == .profile(Self.lea.id))
        #expect(run.offer?.pullMode == .cloud)

        #expect(
            run.send(.chose(Self.lea.id)) == [.adoptCloudProfile(Self.lea.profile), .activate(Self.lea.id)])
        #expect(
            run.state == .networkNotice(then: Self.lea.id, open: nil), "Lea's token needs the home network")

        let acknowledged = run.send(.noticeAcknowledged)
        #expect(acknowledged.contains(.rememberNotice))
        #expect(acknowledged.contains(.startSearches))
        #expect(acknowledged.contains(.checkToken(Self.lea.id, Self.leaAccess)))
        #expect(run.page?.row(.jellyfin) == .fromProfile(Self.leaAccess))

        run.send(.openSource(.jellyfin))
        #expect(run.state == .jellyfin(Self.lea.id, .confirm(Self.leaAccess)))
        #expect(run.send(.jellyfinSignedIn(userID: "lea-id", username: "lea")) == [.storeJellyfin])
        #expect(run.page?.row(.jellyfin) == .done(detail: "lea"))
        #expect(run.page?.focus == .channelList, "the focus goes to the next open row")

        run.send(.finishSources)
        guard case .done(let summary) = run.state else {
            Issue.record("expected A7, got \(run.state)")
            return
        }
        #expect(summary.profile == Self.lea.id)
        #expect(!summary.offersChildLimit)
        run.send(.setStartChoice(true))
        #expect(run.send(.start) == [.applyStartChoice(Self.lea.id)])
        #expect(run.state == .finished(Self.lea.id))

        let activate = try #require(run.effects.firstIndex(of: .activate(Self.lea.id)))
        let store = try #require(run.effects.firstIndex(of: .storeJellyfin))
        #expect(activate < store, "the profile is active before its first source")
    }

    @Test("W1b A token still in the Keychain: Jellyfin is ✓ without A5")
    func returnerWithToken() {
        var run = Run(notice: true)
        run.send(.cloudDeadlinePassed, .cloudAnswered(.profiles([Self.lea])), .chose(Self.lea.id))
        #expect(
            run.page?.row(.jellyfin) == .fromProfile(Self.leaAccess), "notice already ran: straight to A4")
        run.send(.tokenChecked(Self.lea.id, valid: true))
        #expect(run.page?.row(.jellyfin) == .done(detail: "lea"))
        #expect(run.page?.canFinish == true)
        #expect(!run.effects.contains(.storeJellyfin), "nothing to store — the token is there")
    }

    @Test("An invalid token leaves the row on \"confirm\"")
    func returnerWithDeadToken() {
        var run = Run(notice: true)
        run.send(
            .cloudAnswered(.profiles([Self.lea])), .chose(Self.lea.id),
            .tokenChecked(Self.lea.id, valid: false))
        #expect(run.page?.row(.jellyfin) == .fromProfile(Self.leaAccess))
    }

    // MARK: - W2 New household

    @Test("W2 New household: A3 before A4, three sources in one pass, notice before the first search")
    func newHousehold() {
        var run = Run()
        run.send(.cloudAnswered(.noProfiles))
        #expect(run.offer?.cards.isEmpty == true)
        #expect(run.offer?.focus == .newProfile)

        run.send(.choseNew)
        #expect(run.state == .creating(isFirst: true, lateCloudHint: false))
        #expect(run.send(.draftSaved(Self.anna)) == [.activate(Self.anna.id)])
        #expect(run.page?.rows.map(\.state) == [.empty, .empty, .empty])
        #expect(!run.effects.contains(.startSearches), "G8: no search before the notice")

        run.send(.openSource(.jellyfin))
        #expect(run.state == .networkNotice(then: Self.anna.id, open: .jellyfin))
        #expect(!run.effects.contains(.startSearches), "G8: no search before the notice")
        #expect(run.send(.noticeAcknowledged).contains(.startSearches))
        #expect(run.state == .jellyfin(Self.anna.id, .fresh))
        run.send(.searchFound(jellyfin: [Self.found], clServer: Self.clServer))
        #expect(run.state == .jellyfin(Self.anna.id, .fresh), "a search answer does not close a sheet")

        run.send(.jellyfinSignedIn(userID: "anna-id", username: "anna"))
        #expect(run.page?.focus == .channelList)
        run.send(.openSource(.channelList), .sourceFinished(.channelList, .done(detail: "Anbieter")))
        #expect(run.page?.row(.portals) == .found(detail: "cl.example"))

        run.send(.openSource(.portals))
        #expect(run.state == .clServer(Self.anna.id, .request(.none)))
        #expect(run.send(.sendJoinRequest) == [.requestJoin(Self.anna.id)])
        run.send(.requestState(.waiting(remainingSeconds: 300)), .back)
        #expect(run.page?.row(.portals) == .waiting)

        run.send(.finishSources)
        guard case .done(let summary) = run.state else {
            Issue.record("expected A7, got \(run.state)")
            return
        }
        #expect(summary.rows.map(\.state) == [.done(detail: "anna"), .done(detail: "Anbieter"), .waiting])
        #expect(run.effects.filter { $0 == .startSearches }.count == 1)
    }

    @Test("W8 \"Done\" without a source does nothing")
    func doneNeedsSource() {
        var run = Run()
        run.send(.cloudAnswered(.noProfiles), .choseNew, .draftSaved(Self.anna))
        let before = run.state
        #expect(run.page?.canFinish == false)
        #expect(run.send(.finishSources).isEmpty)
        #expect(run.state == before)
    }

    // MARK: - W3 Child

    /// A household with Anna on A7 — IPTV done, so a second profile can take it over.
    func annaDone(pin: Bool = false) -> Run {
        var run = Run(pin: pin, notice: true)
        run.send(
            .cloudAnswered(.noProfiles), .choseNew, .draftSaved(Self.anna), .openSource(.channelList),
            .sourceFinished(.channelList, .done(detail: "Anbieter")), .finishSources)
        return run
    }

    @Test("W3 Child as a further profile: the household PIN comes first, back leads to A7 and not to A4")
    func childNeedsPin() {
        var run = annaDone()
        run.send(.addAnotherProfile)
        #expect(run.state == .creating(isFirst: false, lateCloudHint: false))
        #expect(run.send(.draftSaved(Self.mia)).isEmpty, "no activate before the PIN")
        #expect(run.state == .householdPin(for: Self.mia.id))

        run.send(.back)
        guard case .done(let summary) = run.state else {
            Issue.record("expected A7, got \(run.state)")
            return
        }
        #expect(summary.profile == Self.anna.id)
    }

    @Test("W3 After the PIN: activate, IPTV as a one-press suggestion, CL-Server not for children")
    func childAfterPin() {
        var run = annaDone()
        run.send(.addAnotherProfile, .draftSaved(Self.mia))
        #expect(run.send(.householdPinSet).first == .activate(Self.mia.id))
        #expect(run.page?.row(.channelList) == .suggested(from: "Anna"))
        #expect(run.page?.row(.portals) == .unavailable(.notForChildren))

        #expect(
            run.send(.openSource(.channelList)) == [.copyChannelLists(from: Self.anna.id, to: Self.mia.id)])
        #expect(run.page?.row(.channelList) == .done(detail: "Anna"))
        #expect(run.machine.listsCopied(for: Self.mia.id) == "Anna")
        #expect(run.machine.listsCopied(for: Self.anna.id) == nil)

        run.send(.finishSources)
        guard case .done(let summary) = run.state else {
            Issue.record("expected A7, got \(run.state)")
            return
        }
        #expect(summary.offersChildLimit, "no limit of its own on this device")
    }

    @Test("A child with its own limit is not offered the limit row")
    func childWithLimit() {
        var run = annaDone(pin: true)
        var mia = Self.mia
        mia.hasOwnLimit = true
        run.send(.addAnotherProfile, .draftSaved(mia), .openSource(.channelList), .finishSources)
        guard case .done(let summary) = run.state else {
            Issue.record("expected A7, got \(run.state)")
            return
        }
        #expect(!summary.offersChildLimit)
    }

    @Test("The suggestion is never a silent copy, and the own form stays open")
    func suggestionNeedsPress() {
        var run = annaDone(pin: true)
        run.send(.addAnotherProfile, .draftSaved(Self.tom))
        #expect(!run.effects.contains { if case .copyChannelLists = $0 { true } else { false } })
        run.send(.addOwnChannelList)
        #expect(run.state == .channelList(Self.tom.id))
    }

    @Test("W3b Child with a household PIN: no PIN step")
    func childWithPin() {
        var run = annaDone(pin: true)
        run.send(.addAnotherProfile)
        #expect(run.send(.draftSaved(Self.mia)).first == .activate(Self.mia.id))
        #expect(run.page?.profile == Self.mia.id)
    }

    @Test("W3c G3 A child's CL-Server row leads to pairing and never to a request")
    func childNeverRequests() {
        var run = annaDone(pin: true)
        run.send(
            .addAnotherProfile, .draftSaved(Self.mia), .searchFound(jellyfin: [], clServer: Self.clServer))
        #expect(run.page?.row(.portals) == .unavailable(.notForChildren), "never \"found\" for a child")
        run.send(.openSource(.portals))
        #expect(run.state == .clServer(Self.mia.id, .childPairing))
        #expect(run.send(.sendJoinRequest).isEmpty)
        #expect(!run.effects.contains(.requestJoin(Self.mia.id)))
        #expect(!run.effects.contains(.enroll(Self.mia.id)))
    }

    @Test("G5 A child from iCloud is grey without a household PIN, selectable with one")
    func childWithoutPinIsGrey() {
        var run = Run()
        run.send(.cloudAnswered(.profiles([Self.mia, Self.lea])))
        #expect(run.offer?.cards.map(\.selectable) == [false, true])
        #expect(run.offer?.asksForAdultFirst == true)
        #expect(run.offer?.focus == .profile(Self.lea.id), "the focus skips the grey card")
        let before = run.state
        #expect(run.send(.chose(Self.mia.id)).isEmpty)
        #expect(run.state == before)

        var withPin = Run(pin: true)
        withPin.send(.cloudAnswered(.profiles([Self.mia])))
        #expect(withPin.offer?.cards.map(\.selectable) == [true])
        #expect(withPin.send(.chose(Self.mia.id)).contains(.activate(Self.mia.id)))
    }

    // MARK: - W4 Without iCloud or network

    @Test(
        "W4 No Apple account: A2 fetches over the home network",
        arguments: [CloudAnswer.noAccount, .restricted])
    func noAccount(_ answer: CloudAnswer) {
        var run = Run()
        run.send(.cloudAnswered(answer))
        #expect(run.offer?.pullMode == .wire)
        #expect(run.offer?.cards.isEmpty == true)
        run.send(.choseFetchFromPhone)
        #expect(run.state == .fetchingFromPhone(.wire))
        run.send(.profileFetched(Self.tom))
        #expect(run.effects.contains(.activate(Self.tom.id)))
        #expect(run.page?.profile == Self.tom.id)
    }

    @Test("The QR on A2: a profile from the phone leads into its A4 without a press")
    func codeOnWelcome() {
        var run = Run()
        run.send(.cloudAnswered(.noProfiles))
        #expect(run.offer?.showsCode == true)
        let effects = run.send(.profileFetched(Self.tom))
        #expect(effects.first == .activate(Self.tom.id), "the profile is active before its sources")
        #expect(run.page?.profile == Self.tom.id)
    }

    @Test("A profile from the phone after A2 changes nothing — it waits in \"Who is watching?\"")
    func lateFetchIsIgnored() {
        var run = Run()
        run.send(.cloudAnswered(.noProfiles), .choseNew)
        #expect(run.send(.profileFetched(Self.tom)).isEmpty)
        #expect(run.state == .creating(isFirst: true, lateCloudHint: false))
    }

    @Test("W4b No network: A2 without QR, A4 says \"No network\" for Jellyfin and CL-Server")
    func offline() {
        var run = Run()
        run.send(.networkChanged(online: false), .introEnded, .cloudDeadlinePassed)
        #expect(run.offer?.cloud == .noAnswer)
        #expect(run.offer?.showsCode == false)
        let before = run.state
        run.send(.choseFetchFromPhone)
        #expect(run.state == before, "both ways to the phone need a network")

        run.send(.choseNew, .draftSaved(Self.anna))
        #expect(
            run.page?.rows.map(\.state) == [
                .unavailable(.noNetwork), .empty, .unavailable(.noNetwork),
            ])
        let atSources = run.state
        run.send(.openSource(.jellyfin))
        #expect(run.state == atSources)
        run.send(.openSource(.channelList))
        #expect(run.state == .channelList(Self.anna.id), "IPTV works without a network")

        run.send(.back, .networkChanged(online: true))
        #expect(run.page?.row(.jellyfin) == .empty, "the network back, the row back")
    }

    @Test("The network back in A4: the search catches up once the notice ran")
    func searchAfterNetworkReturns() {
        var run = Run(notice: true, online: false)
        run.send(.cloudAnswered(.noProfiles), .choseNew, .draftSaved(Self.anna))
        #expect(!run.effects.contains(.startSearches), "nothing is searched without a network")
        #expect(run.send(.networkChanged(online: true)).contains(.startSearches))
        #expect(run.send(.networkChanged(online: true)).isEmpty, "a repeated report searches nothing")
        run.send(.searchFound(jellyfin: [Self.found], clServer: Self.clServer))
        #expect(run.page?.row(.jellyfin) == .found(detail: "Wohnzimmer"))
    }

    @Test("The network back before the notice: still no search")
    func noSearchBeforeNoticeWhenNetworkReturns() {
        var run = Run(online: false)
        run.send(.cloudAnswered(.noProfiles), .choseNew, .draftSaved(Self.anna))
        #expect(!run.send(.networkChanged(online: true)).contains(.startSearches))
    }

    @Test("The IPTV sheet learns whether there is a network")
    func onlineIsReadable() {
        var run = Run(online: false)
        #expect(!run.machine.isOnline)
        run.send(.networkChanged(online: true))
        #expect(run.machine.isOnline)
    }

    // MARK: - Several profiles from the phone

    @Test("Several profiles from the phone stand in A2 as cards, nobody becomes active")
    func severalArrivals() {
        var run = Run()
        run.send(.cloudAnswered(.profiles([Self.tom])))
        run.send(.focusMoved(.newProfile))
        let effects = run.send(.profilesArrived([Self.anna, Self.mia]))
        #expect(effects.isEmpty)
        #expect(run.offer?.cards.map(\.profile.id) == [Self.tom.id, Self.anna.id, Self.mia.id])
        #expect(run.offer?.focus == .newProfile, "the focus stays where it stood")
        #expect(run.offer?.cards.last?.selectable == false, "a child stays grey without a household PIN")
    }

    @Test("Several profiles through the embedded fetching path lead back to A2")
    func severalArrivalsWhileFetching() {
        var run = Run()
        run.send(.cloudAnswered(.noProfiles), .choseFetchFromPhone)
        run.send(.profilesArrived([Self.tom, Self.anna]))
        #expect(run.offer?.cards.count == 2)
        #expect(run.offer?.focus == .profile(Self.tom.id))
    }

    @Test("A card that already stands keeps its place when it arrives again")
    func repeatedArrivalKeepsOrder() {
        var run = Run(.fresh(known: [Self.tom, Self.anna]))
        run.send(.cloudAnswered(.noProfiles))
        run.send(.profilesArrived([Self.tom, Self.lea]))
        #expect(run.offer?.cards.map(\.profile.id) == [Self.tom.id, Self.anna.id, Self.lea.id])
    }

    @Test("Profiles from the phone after A2 change nothing")
    func lateArrivalsAreIgnored() {
        var run = Run()
        run.send(.cloudAnswered(.noProfiles), .choseNew)
        run.send(.profilesArrived([Self.tom, Self.anna]))
        #expect(run.state == .creating(isFirst: true, lateCloudHint: false))
    }

    // MARK: - W5 Only IPTV

    @Test("W5 Only IPTV: no notice and no search on the whole way")
    func onlyChannelList() {
        var run = Run()
        run.send(
            .cloudAnswered(.noProfiles), .choseNew, .draftSaved(Self.anna), .openSource(.channelList))
        #expect(run.state == .channelList(Self.anna.id))
        run.send(.sourceFinished(.channelList, .done(detail: "Anbieter")), .finishSources, .start)
        #expect(run.state == .finished(Self.anna.id))
        #expect(!run.effects.contains(.startSearches))
        #expect(!run.effects.contains(.rememberNotice))
    }

    // MARK: - W6 iCloud too late

    @Test("W6 Late in A2: the profiles appear, the focus stays")
    func lateInWelcome() {
        var run = Run()
        run.send(.introEnded, .cloudDeadlinePassed)
        #expect(run.offer?.cloud == .noAnswer)
        #expect(run.offer?.pullMode == .wire)
        run.send(.focusMoved(.newProfile))
        let late = run.send(.cloudAnswered(.profiles([Self.lea, Self.tom])))
        #expect(run.offer?.cards.count == 2)
        #expect(run.offer?.focus == .newProfile)
        #expect(run.offer?.pullMode == .cloud)
        #expect(!late.contains(.drawReady), "drawn once, at leaving A1")
    }

    @Test("W6b Late in A3: a hint, the sheet stays")
    func lateInCreating() {
        var run = Run()
        run.send(.cloudDeadlinePassed, .choseNew, .cloudAnswered(.profiles([Self.lea])))
        #expect(run.state == .creating(isFirst: true, lateCloudHint: true))
    }

    @Test("W6c G2 Late in A4: nothing changes, nobody becomes active")
    func lateInSources() {
        var run = Run()
        run.send(.cloudDeadlinePassed, .choseNew, .draftSaved(Self.anna))
        let before = run.state
        let late = run.send(.cloudAnswered(.profiles([Self.lea])))
        #expect(run.state == before)
        #expect(!late.contains { if case .activate = $0 { true } else { false } })
    }

    // MARK: - W7 Second TV

    @Test("W7 Second TV: the person token enrolls once the CL-Server is found")
    func secondTV() {
        var lea = Self.lea
        lea.hasPersonTag = true
        var run = Run()
        run.send(.cloudAnswered(.profiles([lea])), .chose(lea.id), .noticeAcknowledged)
        #expect(!run.effects.contains(.enroll(lea.id)), "no address yet")
        #expect(run.send(.searchFound(jellyfin: [], clServer: Self.clServer)) == [.enroll(lea.id)])
        run.send(.enrolled(lea.id, success: true))
        #expect(run.page?.row(.portals) == .done(detail: "cl.example"))
    }

    @Test("W7 A failed enrollment leaves the row \"found\" and A6 asks")
    func secondTVEnrollFails() {
        var lea = Self.lea
        lea.hasPersonTag = true
        var run = Run(notice: true)
        run.send(
            .cloudAnswered(.profiles([lea])), .chose(lea.id),
            .searchFound(jellyfin: [], clServer: Self.clServer), .enrolled(lea.id, success: false))
        #expect(run.page?.row(.portals) == .found(detail: "cl.example"))
        run.send(.openSource(.portals))
        #expect(run.state == .clServer(lea.id, .request(.none)))
    }

    @Test("A6 before the search answered: searching, then not found")
    func clServerSearching() {
        var run = Run(notice: true)
        run.send(.cloudAnswered(.noProfiles), .choseNew, .draftSaved(Self.anna), .openSource(.portals))
        #expect(run.state == .clServer(Self.anna.id, .searching))
        run.send(.searchFound(jellyfin: [], clServer: nil))
        #expect(run.state == .clServer(Self.anna.id, .notFound))
    }

    // MARK: - A5 details

    @Test("G6 Quick Connect signs in someone else: a question, nothing stored")
    func otherUserAsks() {
        var run = Run(notice: true)
        run.send(.cloudAnswered(.profiles([Self.lea])), .chose(Self.lea.id), .openSource(.jellyfin))
        #expect(run.send(.jellyfinSignedIn(userID: "tom-id", username: "tom")).isEmpty)
        #expect(
            run.state
                == .jellyfin(
                    Self.lea.id, .otherUser(signedIn: "tom", expected: "lea", access: Self.leaAccess)))
        run.send(.back)
        #expect(run.state == .jellyfin(Self.lea.id, .confirm(Self.leaAccess)), "\"Once more\"")
        run.send(.jellyfinSignedIn(userID: "tom-id", username: "tom"))
        #expect(run.send(.acceptOtherUser) == [.storeJellyfin])
        #expect(run.page?.row(.jellyfin) == .done(detail: "tom"))
    }

    // MARK: - Back

    @Test("G9 Back from A4 leads to A2 and keeps the profile")
    func backKeepsProfile() {
        var run = Run()
        run.send(.cloudAnswered(.noProfiles), .choseNew, .draftSaved(Self.anna))
        #expect(run.send(.back).isEmpty)
        #expect(run.offer?.cards.map(\.profile.id) == [Self.anna.id])
    }

    @Test("Back in A2 and A1 does nothing")
    func backInWelcome() {
        var run = Run()
        #expect(run.send(.back).isEmpty)
        #expect(run.state == .probing(introOver: false))
        run.send(.cloudAnswered(.noProfiles))
        let before = run.state
        run.send(.back)
        #expect(run.state == before)
    }

    @Test("A refused switch leads back to A2")
    func activationRefused() {
        var run = Run()
        run.send(.cloudAnswered(.profiles([Self.tom])), .chose(Self.tom.id), .activationRefused(Self.tom.id))
        #expect(run.offer != nil)
    }

    // MARK: - Steps and resume

    @Test("The phone has no intro: its deadline runs from the start")
    func phoneWithoutIntro() {
        let run = Run(steps: .phone)
        #expect(run.effects == [.probeCloud, .watchNetwork, .startCloudDeadline])
    }

    @Test("W9 Resume: straight into A4 of the active profile, drawn at once")
    func resume() {
        let run = Run(.resume(Self.anna), notice: true)
        #expect(run.page?.profile == Self.anna.id)
        #expect(run.effects.contains(.drawReady))
        #expect(run.effects.contains(.startSearches))
        #expect(!run.effects.contains(.probeCloud))
    }

    @Test("Resume before the notice: A4 without a search")
    func resumeBeforeNotice() {
        let run = Run(.resume(Self.anna))
        #expect(run.page?.profile == Self.anna.id)
        #expect(!run.effects.contains(.startSearches))
    }
    // MARK: - Retrofit from the settings

    @Test("Retrofit Jellyfin: the sheet at once, a sign-in ends the journey")
    func retrofitJellyfin() {
        var run = Run(.retrofit(Self.anna, .jellyfin), notice: true)
        #expect(run.state == .jellyfin(Self.anna.id, .fresh))
        #expect(!run.effects.contains(.probeCloud))
        #expect(run.send(.jellyfinSignedIn(userID: "anna-id", username: "anna")) == [.storeJellyfin])
        #expect(run.state == .finished(Self.anna.id))
    }

    @Test("Retrofit Jellyfin from the profile: confirm, and a valid token closes it")
    func retrofitConfirm() {
        var run = Run(.retrofit(Self.lea, .jellyfin), notice: true)
        #expect(run.state == .jellyfin(Self.lea.id, .confirm(Self.leaAccess)))
        #expect(run.effects.contains(.checkToken(Self.lea.id, Self.leaAccess)))
        run.send(.tokenChecked(Self.lea.id, valid: true))
        #expect(run.state == .finished(Self.lea.id))
    }

    @Test("Retrofit: back from the sheet ends it, nothing is stored")
    func retrofitBack() {
        var run = Run(.retrofit(Self.anna, .channelList), notice: true)
        #expect(run.state == .channelList(Self.anna.id))
        #expect(run.send(.back).isEmpty)
        #expect(run.state == .finished(Self.anna.id))
    }

    @Test("Retrofit before the notice: the notice first, back from it ends the journey")
    func retrofitNotice() {
        var run = Run(.retrofit(Self.anna, .portals))
        #expect(run.state == .networkNotice(then: Self.anna.id, open: .portals))
        run.send(.back)
        #expect(run.state == .finished(Self.anna.id))
    }

    @Test("Retrofit CL-Server: the request sheet; a waiting request ends the journey")
    func retrofitClServer() {
        var run = Run(.retrofit(Self.anna, .portals), notice: true)
        #expect(run.state == .clServer(Self.anna.id, .searching))
        run.send(.searchFound(jellyfin: [], clServer: Self.clServer))
        #expect(run.state == .clServer(Self.anna.id, .request(.none)))
        run.send(.sourceFinished(.portals, .waiting))
        #expect(run.state == .finished(Self.anna.id))
    }

    @Test("Retrofit Jellyfin never enrolls the CL-Server on the side")
    func retrofitOnlyItsKind() {
        var lea = Self.lea
        lea.hasPersonTag = true
        var run = Run(.retrofit(lea, .jellyfin), notice: true)
        run.send(.searchFound(jellyfin: [], clServer: Self.clServer))
        #expect(!run.effects.contains(.enroll(lea.id)))
    }

    @Test("Retrofit offline: the fallback page, back and done both end it")
    func retrofitOffline() {
        var run = Run(.retrofit(Self.anna, .jellyfin), notice: true, online: false)
        #expect(run.page?.row(.jellyfin) == .unavailable(.noNetwork))
        run.send(.finishSources)
        #expect(run.state == .finished(Self.anna.id))
    }
}
