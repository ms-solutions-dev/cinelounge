import Core
import Flows
import Foundation
import JellyfinKit
import PlaylistKit
import PortalKit
import Testing

@testable import Features

// MARK: - The guard over the list

/// **Every state is in exactly one of the two lists.**
///
/// A case that falls through both is one that nobody has decided about — and
/// that is exactly what this check is meant to catch, not a single wrong button.
@Test func everyStateIsClassified() {
    for state in PlaybackPhase.allCases {
        let needs = InfoVersusAction.needsAction.contains(state)
        let without = InfoVersusAction.withoutAction.contains(state)
        #expect(needs != without, "\(state.rawValue) is in both lists or in neither")
    }
}

/// **What an action needs also has one** — and vice versa.
///
/// Reading is done from ``PlaybackPhase/form`` and not from the list: If the check read the list,
/// it would check it against itself.
@Test func whatAnActionNeedsAlsoHasOne() {
    for state in InfoVersusAction.needsAction {
        #expect(
            InfoVersusAction.hasAction(state),
            "\(state.rawValue) promises an action and has none")
    }
    for state in InfoVersusAction.withoutAction {
        #expect(
            !InfoVersusAction.hasAction(state),
            "\(state.rawValue) carries a button that does not belong there")
    }
}

/// **"The one connection is occupied" deliberately carries no button.**
///
/// A "Retry" would be an invitation to use up the one permitted connection a second
/// time — the action that makes the situation worse.
@Test func busyGetsNoRetryButton() {
    #expect(!InfoVersusAction.hasAction(.xtreamBusy))
}

/// **The phone's cases are not shown by the TV** — since AP58 R3 they are in the
/// shared state, but do not belong on this device.
///
/// A TV has no airplane mode, no mobile data, no camera and no
/// audio interruption by a call; until 2026-09-26 these cases were missing here entirely.
/// Now they are in ``PlaybackPhase/phoneOnly``, and the check records that the TV's
/// showcase does not demonstrate them and the TV's interpretation does not produce them.
///
/// **Twenty-seven remain** (AP25 + AP39): twenty shared ones, `jellyfinDisruption`,
/// `emptyPortalLevel`, `noConnection`, and since AP39 `xtreamAccessExpired`,
/// `portalProfileRequired`, `portalLoginRequired` and `certificateUnconfirmed`.
@Test func thePhoneSpecificCasesAreMissing() {
    let names = Set(PlaybackPhase.onTV.map(\.rawValue))
    for foreign in ["netzFlugmodus", "mobilfunkAngehalten", "abbruch", "netzFernseher", "kameraVerweigert"] {
        #expect(!names.contains(foreign), "\(foreign) does not belong on the TV")
    }
    let offline = NetworkWatch()
    offline.setForTesting(connected: false)
    for origin in Origin.allCases {
        #expect(
            !PlaybackPhase.phoneOnly.contains(
                DisruptionInterpretation.state(forItem: SomeError(), origin: origin, network: offline)))
    }
    #expect(PlaybackPhase.onTV.count == 27)
}

// MARK: - The disruption interpretation

private struct SomeError: Error {}

/// **Every source gets its own screen.**
///
/// The finding from the phone: Every error of every source became "No response from the
/// media server" — a message that sends the viewer to the wrong place.
@Test func everySourceGetsItsOwnScreen() {
    #expect(DisruptionInterpretation.state(forItem: SomeError(), origin: .jellyfin) == .networkJellyfin)
    #expect(DisruptionInterpretation.state(forItem: SomeError(), origin: .provider) == .networkXtream)
    #expect(DisruptionInterpretation.state(forItem: SomeError(), origin: .portals) == .networkPortals)
}

/// **An expired sign-in comes before the origin — but each has its own
/// way back** (AP39, 2026-09-20).
///
/// **What this check fixed until 2026-09-20 was the error itself:** Both
/// sources produced ``PlaybackPhase/loginExpired``, because "an expired sign-in
/// demands the same action, no matter who reports it". For the sentence that is true. But the button
/// below it led to the **Jellyfin account**, and with an expired
/// provider password nothing can be done there.
@Test func everyOriginHasItsOwnWayBack() {
    #expect(
        DisruptionInterpretation.state(
            forItem: JellyfinSource.SourceFailure.unauthorized, origin: .jellyfin)
            == .loginExpired)
    #expect(
        DisruptionInterpretation.state(forItem: XtreamClient.Failure.unauthorized, origin: .provider)
            == .xtreamAccessExpired)

    // And the button leads to where it can be fixed — that is the whole point.
    #expect(target(from: .loginExpired) == .accounts)
    #expect(target(from: .xtreamAccessExpired) == .channelLists)
}

/// **The error type carries the origin, so the interpretation also holds across it.**
///
/// A collected list asks three sources; which of them the caller is currently reporting
/// is not always the one that threw. An Xtream `unauthorized` that arrives as a
/// media-server failure must still not lead to the Jellyfin account.
@Test func errorTypeDecidesNotTheCaller() {
    #expect(
        DisruptionInterpretation.state(
            forItem: XtreamClient.Failure.unauthorized, origin: .jellyfin)
            == .xtreamAccessExpired)
}

/// **The portal service says what it is missing — and is taken at its word.**
///
/// The finding from 2026-09-19: `401 auth.profile_required` ended up as `error.unreachable`,
/// that is "No response. Is the server running?". It had responded, and precisely.
@Test func portalsRequireProfileOrSignIn() {
    let withoutProfile = PortalBridge.TestError.cancelled(
        status: 401, code: "auth.profile_required", values: [:])
    let withoutSignIn = PortalBridge.TestError.cancelled(status: 401, code: "auth.required", values: [:])

    #expect(
        DisruptionInterpretation.state(forItem: withoutProfile, origin: .portals) == .portalProfileRequired)
    #expect(
        DisruptionInterpretation.state(forItem: withoutSignIn, origin: .portals) == .portalLoginRequired)

    // Both lead to the Portals settings, where profile choice and pairing are located.
    #expect(target(from: .portalProfileRequired) == .portalSettings)
    #expect(target(from: .portalLoginRequired) == .portalSettings)
}

/// **A refusal with an unknown code stays what it was** — the interpretation does not invent
/// a sign-in case just because "auth" is in the text.
@Test func foreignDeclinesStayUnresolvable() {
    let locked = PortalBridge.TestError.cancelled(
        status: 451, code: "stream.geo_blocked", values: ["country": "DE"])

    #expect(
        DisruptionInterpretation.state(forItem: locked, origin: .portals) == .portalUnresolvable)
}

/// **A leftover certificate question is more precise than any network sentence** (AP39).
///
/// The finding from 2026-09-19: The question exists only in setup; afterwards you see
/// "No response". Whoever sets up their home server anew never gets back in that way.
@Test func openCertificateQuestionBeatsTheNetworkSentence() {
    // **A dedicated mailbox and not `shared`** — checks run concurrently, and
    // a shared one turns two checks into one. For exactly that it has been
    // publicly constructible since 2026-09-17.
    let mailbox = CertificatePrompt()
    mailbox.location(
        CertificatePrompt.Pending(
            // **A name without a dot, and that is no coincidence:** The key check
            // (`scripts/strings.py`) recognises language keys by the form `area.name`
            // and reported `server.home` as a missing key. An exception list would be
            // the wrong place for that — the host name is arbitrary here.
            host: "vault", fingerprint: CertificateFingerprint(value: "AA:BB")))

    #expect(
        DisruptionInterpretation.state(
            forItem: SomeError(), origin: .jellyfin, certificatePrompt: mailbox)
            == .certificateUnconfirmed)

    // And the button pulls the question out, instead of merely explaining.
    #expect(target(from: .certificateUnconfirmed) == .certificate)
}

/// **An empty mailbox changes nothing** — otherwise the certificate question would sit above
/// every error there is.
@Test func withoutQuestionItStaysWithTheNetworkSentence() {
    #expect(
        DisruptionInterpretation.state(
            forItem: SomeError(), origin: .jellyfin, certificatePrompt: CertificatePrompt())
            == .networkJellyfin)
}

/// The button's target — `nil` if the state has none.
private func target(from state: PlaybackPhase) -> ActionTarget? {
    if case .job(let job) = state.form { return job.target }
    return nil
}

/// **A drop in the engine is not a network error** — the server did respond.
@Test func dropInEngineIsNotNetworkError() {
    #expect(
        DisruptionInterpretation.state(
            forItem: SomeError(), origin: .jellyfin, fromPlayer: true)
            == .jellyfinWontPlay)
}

/// **A raw stream is not an occupied connection**, and the address decides.
///
/// The finding from 2026-09-06: The screen said "occupied" with zero active connections.
/// "Occupied" was a guess about every engine drop; by the file extension it can be refuted.
@Test func rawStreamIsNotABusyConnection() {
    let raw = URL(string: "http://anbieter.example/live/1.ts")!
    let done = URL(string: "http://anbieter.example/live/1.m3u8")!

    #expect(
        DisruptionInterpretation.state(
            forItem: SomeError(), origin: .provider, fromPlayer: true, address: raw)
            == .xtreamRawStreamOnly)
    #expect(
        DisruptionInterpretation.state(
            forItem: SomeError(), origin: .provider, fromPlayer: true, address: done)
            == .xtreamBusy)
}

/// **Without a drop it stays a network error**, even with a raw address: Whoever has not
/// reached the source at all has learned nothing about the stream.
@Test func withoutDropTheAddressDecidesNothing() {
    let raw = URL(string: "http://anbieter.example/live/1.ts")!
    #expect(
        DisruptionInterpretation.state(forItem: SomeError(), origin: .provider, address: raw)
            == .networkXtream)
}

/// **The bridge that refuses is not a network disturbance.**
@Test func rejectedBridgeIsNotNetworkError() {
    let rejected = PortalBridge.TestError.rejected(status: 502, reason: "kein Host")
    #expect(
        DisruptionInterpretation.state(forItem: rejected, origin: .portals) == .portalUnresolvable)
}

/// **And the server that declines likewise** (2026-09-12).
///
/// It names a code instead of a sentence. Without this case the app would interpret **every**
/// refusal by the CineLounge server as a network disturbance — "Connection lost" for a
/// portal that has answered and given a reason.
@Test func declinedServerIsNotNetworkError() {
    let cancelled = PortalBridge.TestError.cancelled(status: 502, code: "stream.no_host", values: [:])
    #expect(
        DisruptionInterpretation.state(forItem: cancelled, origin: .portals) == .portalUnresolvable)
}

/// **The system player's certificate is reported and never guessed.**
///
/// On the TV this case is derived and not observed; it may therefore occur only
/// if the caller explicitly states the situation.
@Test func certificateIsReportedAndNeverGuessed() {
    #expect(
        DisruptionInterpretation.state(forItem: SomeError(), origin: .jellyfin) != .certificateSystemPlayer)
    #expect(
        DisruptionInterpretation.state(
            forItem: SomeError(), origin: .jellyfin, certificateTrustedByAppOnly: true)
            == .certificateSystemPlayer)
}

// MARK: - The hookup of the error screen (stage 2)

/// **The state takes precedence because it knows more.**
///
/// `ErrorSummary` knows only the error and says "network error" for every provider drop,
/// while the situation is called "the one permitted connection is occupied". Where the interpretation knows
/// something more precise, it applies.
@Test func stateTakesPrecedenceOverErrorView() {
    let rejection = DisruptionInterpretation.rejection(
        forItem: SomeError(), origin: .provider, fromPlayer: true)
    #expect(rejection == PlaybackPhase.xtreamBusy.headline)
    #expect(rejection != ErrorSummary.key(forItem: SomeError()))
}

/// **Where the interpretation knows nothing more precise than "the network", `ErrorSummary` stays.**
///
/// There it distinguishes timeout, name resolution and certificate — a
/// distinction that the state does not carry and that must not be lost.
@Test func onNetworkErrorViewStaysTheFinerTool() {
    let time = URLError(.timedOut)
    let name = URLError(.cannotFindHost)

    #expect(
        DisruptionInterpretation.rejection(forItem: time, origin: .jellyfin)
            == ErrorSummary.key(forItem: time))
    #expect(
        DisruptionInterpretation.rejection(forItem: time, origin: .jellyfin)
            != DisruptionInterpretation.rejection(forItem: name, origin: .jellyfin))
}

/// **An expired sign-in is not a network error** — not even in the refusal.
@Test func expiredSignInHasItsOwnSentence() {
    #expect(
        DisruptionInterpretation.rejection(
            forItem: JellyfinSource.SourceFailure.unauthorized, origin: .jellyfin)
            == PlaybackPhase.loginExpired.headline)
}

// MARK: - The shapes

/// **The row shows only what has no button.**
///
/// Drawing an order as a row would mean taking its button away — and then
/// ``InfoVersusAction`` would promise something that does not arrive on the screen.
@Test func theRowShowsOnlyWhatHasNoButton() {
    for state in PlaybackPhase.allCases {
        #expect(
            StateRow.showsOnly(state) == !InfoVersusAction.hasAction(state),
            "\(state.rawValue)")
    }
    #expect(StateRow.showsOnly(.xtreamBusy))
    #expect(!StateRow.showsOnly(.loginExpired))
}

// MARK: - The fallback in steps (stage 3)

/// **Failed steps count as done** — they have been tried.
///
/// Not counting them would leave the display standing while the app long since carries on.
@Test func failedStepsCountAsDone() {
    let probe = RouteProbe.fallbackViaBridge
    #expect(probe.steps.count == 4)
    // resolved (done) + direct (failed) = 2
    #expect(probe.done == 2)
}

/// **Exactly one step is running.** Two running would mean the display claims two things
/// at once; none would mean it has stalled.
@Test func exactlyOneStepRuns() {
    let running = RouteProbe.fallbackViaBridge.steps.filter { $0.state == .isRunning }
    #expect(running.count == 1)
}

/// **Every step carries its own sentence.** A path with four steps and two
/// labels explains less than a spinner, because it also looks wrong.
@Test func everyStepCarriesItsOwnSentence() {
    let wordings = RouteProbe.fallbackViaBridge.steps.map(\.message)
    #expect(Set(wordings).count == wordings.count)
    #expect(wordings.allSatisfy { $0.hasPrefix("state.portal.fallback.") })
}

// MARK: - The state showcase

/// **The showcase demonstrates every state and none twice.**
///
/// It is the tool with which the pointers after AP33 can be worked off at all:
/// Producing twenty-seven failures on the device would not be possible, and none
/// of them repeatable.
@Test func theShowcasePresentsEveryState() {
    #expect(PlaybackPhase.onTV.count == 27)
    #expect(Set(PlaybackPhase.onTV.map(\.rawValue)).count == 27)
}

/// **Every state names a place where it would appear in a real emergency.**
///
/// A state without a place would be one that the showcase shows and the app never — exactly the
/// kind of entry that silently goes stale.
@Test func everyStateNamesItsPlace() {
    let locations = Set(PlaybackPhase.allCases.map(\.host))
    #expect(locations.contains(.media))
    #expect(locations.contains(.live))
    #expect(locations.contains(.portals))
    #expect(locations.contains(.search))
    #expect(locations.contains(.favorites))
}
