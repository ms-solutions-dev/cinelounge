import Foundation
import ProfileKit
import Testing

@_spi(Check) @testable import Flows

/// **TV and phone walk the same machine** (AP88 wave 6) — the same inputs lead to the same states
/// and effects, except where ``SetupSteps`` says otherwise.
///
/// The deliberate differences, each with its own check below: the phone has no intro, so its
/// iCloud deadline runs from the start; it scans instead of showing a code, so A2 has no QR; and
/// it can fetch a profile only through the household zone, never over the home network.
///
/// Counter-checks: with `steps` ignored in `welcomeOffer` (a code on the phone)
/// ``phoneShowsNoCode()`` turns red; without `canFetch` in `choseFetchFromPhone`
/// ``phoneFetchesOnlyThroughCloud()``; a `steps` switch anywhere else in the machine turns one of
/// the paths in ``samePaths(_:)`` red.
@Suite("Setup — TV and phone walk the same machine")
struct SetupParityTests {

    typealias Run = SetupMachineTests.Run

    static let lea = SetupMachineTests.lea
    static let tom = SetupMachineTests.tom
    static let mia = SetupMachineTests.mia
    static let anna = SetupMachineTests.anna
    static let found = SetupMachineTests.found
    static let clServer = SetupMachineTests.clServer

    /// One path of AP88 §6.1 as inputs, with the start it needs.
    struct Path: Sendable, CustomTestStringConvertible {
        let name: String
        var start: SetupMachine.Start = .fresh(known: [])
        var pin = false
        var notice = false
        var online = true
        let inputs: [SetupInput]

        var testDescription: String { name }
    }

    static let paths: [Path] = [
        Path(
            name: "W1 returner",
            inputs: [
                .cloudAnswered(.profiles([lea, tom])), .chose(lea.id), .noticeAcknowledged,
                .searchFound(jellyfin: [found], clServer: clServer), .openSource(.jellyfin),
                .jellyfinSignedIn(userID: "lea-id", username: "lea"), .finishSources, .setStartChoice(true),
                .start,
            ]),
        Path(
            name: "W2 new household, three sources",
            inputs: [
                .cloudAnswered(.noProfiles), .choseNew, .draftSaved(anna), .openSource(.jellyfin),
                .noticeAcknowledged, .searchFound(jellyfin: [found], clServer: clServer),
                .jellyfinSignedIn(userID: "anna-id", username: "anna"), .openSource(.channelList),
                .sourceFinished(.channelList, .done(detail: "Anbieter")), .openSource(.portals),
                .sendJoinRequest,
                .requestState(.waiting(remainingSeconds: 300)), .back, .finishSources,
            ]),
        Path(
            name: "W3 child as a further profile",
            notice: true,
            inputs: [
                .cloudAnswered(.noProfiles), .choseNew, .draftSaved(anna), .openSource(.channelList),
                .sourceFinished(.channelList, .done(detail: "Anbieter")), .finishSources, .addAnotherProfile,
                .draftSaved(mia), .back, .addAnotherProfile, .draftSaved(mia), .householdPinSet,
                .openSource(.channelList), .openSource(.portals), .finishSources,
            ]),
        Path(
            name: "W4b no network",
            online: false,
            inputs: [
                .cloudDeadlinePassed, .choseFetchFromPhone, .choseNew, .draftSaved(anna),
                .openSource(.jellyfin),
                .openSource(.channelList), .sourceFinished(.channelList, .done(detail: "liste.example")),
                .networkChanged(online: true),
            ]),
        Path(
            name: "W5 only IPTV",
            inputs: [
                .cloudAnswered(.noProfiles), .choseNew, .draftSaved(anna), .openSource(.channelList),
                .sourceFinished(.channelList, .done(detail: "Anbieter")), .finishSources, .start,
            ]),
        Path(
            name: "W6 iCloud late in A2, A3 and A4",
            inputs: [
                .cloudDeadlinePassed, .cloudAnswered(.profiles([lea])), .choseNew,
                .cloudAnswered(.profiles([lea, tom])), .back, .chose(tom.id),
                .cloudAnswered(.profiles([mia])),
            ]),
        Path(
            name: "W9 resume into A4",
            start: .resume(anna), notice: true,
            inputs: [.searchFound(jellyfin: [], clServer: nil), .openSource(.portals), .back, .back]),
        Path(
            name: "G6 Quick Connect for someone else",
            notice: true,
            inputs: [
                .cloudAnswered(.profiles([lea])), .chose(lea.id), .openSource(.jellyfin),
                .jellyfinSignedIn(userID: "tom-id", username: "tom"), .acceptOtherUser,
            ]),
    ]

    /// The effects a path asks for — **without the deadline**, whose start is the one difference in
    /// timing (``phoneHasNoIntro()``).
    static func effects(_ run: Run) -> [SetupEffect] {
        run.effects.filter { $0 != .startCloudDeadline }
    }

    /// A state with the QR switched off — **the one difference in what A2 shows**
    /// (``phoneShowsNoCode()``).
    static func withoutCode(_ state: SetupState) -> SetupState {
        guard case .welcome(var offer) = state else { return state }
        offer.showsCode = false
        offer.canFetch = offer.canFetch && offer.pullMode == .cloud
        return .welcome(offer)
    }

    static func walk(_ path: Path, _ steps: SetupSteps) -> (run: Run, states: [SetupState]) {
        var run = Run(path.start, steps: steps, pin: path.pin, notice: path.notice, online: path.online)
        var states = [withoutCode(run.state)]
        for input in path.inputs {
            run.send(input)
            states.append(withoutCode(run.state))
        }
        return (run, states)
    }

    @Test("The same inputs lead to the same states and effects", arguments: paths)
    func samePaths(_ path: Path) {
        let tv = Self.walk(path, .tv)
        let phone = Self.walk(path, .phone)
        #expect(tv.states == phone.states)
        #expect(Self.effects(tv.run) == Self.effects(phone.run))
        #expect(tv.run.machine.clServerAddress == phone.run.machine.clServerAddress)
    }

    @Test("Every path reaches somewhere other than its start on both devices", arguments: paths)
    func pathsMove(_ path: Path) {
        for steps in [SetupSteps.tv, .phone] {
            let walked = Self.walk(path, steps)
            #expect(walked.states.last != walked.states.first, "\(path.name) stays in place")
        }
    }

    // MARK: - The deliberate differences

    @Test("The phone has no intro: the deadline starts with the setup, the TV's after the clip")
    func phoneHasNoIntro() {
        let tv = Run(steps: .tv)
        let phone = Run(steps: .phone)
        #expect(!tv.effects.contains(.startCloudDeadline))
        #expect(phone.effects.contains(.startCloudDeadline))
        #expect(Self.effects(tv) == Self.effects(phone))
    }

    @Test("A2 on the phone shows no code; the TV shows one with a network")
    func phoneShowsNoCode() {
        for cloud in [CloudAnswer.noProfiles, .noAccount, .noAnswer] {
            var tv = Run(steps: .tv)
            var phone = Run(steps: .phone)
            tv.send(.cloudAnswered(cloud))
            phone.send(.cloudAnswered(cloud))
            #expect(tv.offer?.showsCode == true)
            #expect(phone.offer?.showsCode == false)
        }
    }

    @Test("The phone fetches only through iCloud; the TV also over the home network")
    func phoneFetchesOnlyThroughCloud() {
        var tv = Run(steps: .tv)
        var phone = Run(steps: .phone)
        tv.send(.cloudAnswered(.noAccount), .choseFetchFromPhone)
        phone.send(.cloudAnswered(.noAccount), .choseFetchFromPhone)
        #expect(tv.state == .fetchingFromPhone(.wire))
        #expect(phone.offer?.canFetch == false)
        guard case .welcome = phone.state else {
            Issue.record("the phone left A2 without a way to fetch: \(phone.state)")
            return
        }

        var cloudPhone = Run(steps: .phone)
        cloudPhone.send(.cloudAnswered(.noProfiles), .choseFetchFromPhone)
        #expect(cloudPhone.state == .fetchingFromPhone(.cloud))
    }

    @Test("Without a network neither device fetches")
    func nobodyFetchesOffline() {
        for steps in [SetupSteps.tv, .phone] {
            var run = Run(steps: steps, online: false)
            run.send(.cloudDeadlinePassed)
            #expect(run.offer?.canFetch == false)
            #expect(run.offer?.showsCode == false)
        }
    }

    @Test("The phone's steps are the concept's table")
    func phoneSteps() {
        #expect(SetupSteps.phone.coversIntro == false)
        #expect(SetupSteps.phone.fetchFromPhone == .scan)
        #expect(SetupSteps.phone.networkNoticeBeforeSearch == SetupSteps.tv.networkNoticeBeforeSearch)
        #expect(SetupSteps.phone.deviceKind == .phone)
    }
}

/// The journey on the phone — **no code is ever issued**, the scan replaces it.
@MainActor
@Suite("Setup — the phone's journey")
struct SetupPhoneJourneyTests {

    @Test("A2 on the phone asks for no code, also when it stands for a while")
    func noCodeOnThePhone() async {
        let clock = SetupClock()
        var issued = 0
        var services = SetupServices.mock(cloud: .noProfiles)
        services.wait = { await clock.wait($0) }
        services.issueCode = {
            issued += 1
            return "c\(issued)"
        }
        let journey = SetupJourney(
            SetupMachine(steps: .phone, start: .fresh(known: []), isPinSet: false, noticeSeen: false),
            services: services)
        journey.start()
        await journey.settle()
        await SetupClock.drain()
        guard case .welcome = journey.state else {
            Issue.record("expected A2, got \(journey.state)")
            journey.stop()
            return
        }
        await clock.advance(by: .seconds(400))
        #expect(issued == 0)
        #expect(journey.pairingCode == nil)
        journey.stop()
    }

    @Test("The phone's deadline: without an iCloud answer A2 comes after the grace, without a clip")
    func deadlineWithoutClip() async {
        let clock = SetupClock()
        let latch = SetupLatch<CloudAnswer>()
        var services = SetupServices.mock()
        services.wait = { await clock.wait($0) }
        services.probeCloud = { await latch.wait() }
        let journey = SetupJourney(
            SetupMachine(steps: .phone, start: .fresh(known: []), isPinSet: false, noticeSeen: false),
            services: services)
        journey.start()
        await SetupClock.drain()
        #expect(journey.state == .probing(introOver: false))
        await clock.advance(by: SetupMachine.cloudGrace)
        guard case .welcome(let offer) = journey.state else {
            Issue.record("expected A2, got \(journey.state)")
            journey.stop()
            return
        }
        #expect(offer.cloud == .noAnswer)
        latch.release(.profiles([SetupMachineTests.lea]))
        await journey.settle()
        await SetupClock.drain()
        guard case .welcome(let late) = journey.state else {
            Issue.record("expected A2, got \(journey.state)")
            journey.stop()
            return
        }
        #expect(late.cards.map(\.profile.id) == [SetupMachineTests.lea.id], "the late answer adds its card")
        journey.stop()
    }
}
