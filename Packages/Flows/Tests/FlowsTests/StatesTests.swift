import Core
import Foundation
import JellyfinKit
import PlaylistKit
import PortalKit
import SourceProbe
import Testing
import WordingKit

@testable import Flows

#if canImport(AppKit)
    import AppKit
#endif

/// The one state table of both devices — **list, texts, symbols** (AP58 R3).
///
/// What is stated here applied per platform on its own until 2026-09-26, and that is
/// exactly where the versions drifted apart. The platforms' checks (`ZustandTests` on the
/// TV, `StateTextTests` on the phone) keep running against the same table; this file
/// covers what belongs to no platform.
@Suite("State table")
struct StateTableTests {

    // MARK: - Die Liste

    /// **Every state is in exactly one of the two lists.**
    @Test("Every state is classified — information or task")
    func everyOneIsClassified() {
        for state in PlaybackPhase.allCases {
            let needs = InfoVersusAction.needsAction.contains(state)
            let without = InfoVersusAction.withoutAction.contains(state)
            #expect(needs != without, "\(state.rawValue) is in both lists or in neither")
        }
    }

    /// **What an action needs also has one** — read from the shape, not from the list.
    @Test("The shape keeps what the list promises")
    func formHoldsList() {
        for state in PlaybackPhase.allCases {
            #expect(
                InfoVersusAction.hasAction(state)
                    == InfoVersusAction.needsAction.contains(state),
                "\(state.rawValue)")
        }
    }

    /// **No state belongs to one platform alone.**
    @Test("The platform lists do not overlap")
    func platformLists() {
        #expect(PlaybackPhase.tvOnly.isDisjoint(with: PlaybackPhase.phoneOnly))
        #expect(PlaybackPhase.phoneOnly.contains(.networkAirplaneMode))
        #expect(PlaybackPhase.tvOnly.contains(.noConnection))
    }

    /// **The union: 27 on the TV, 29 on the phone, 32 together.**
    ///
    /// Until 2026-09-26 the TV carried 27 and the phone 26. The phone gains three that it now
    /// reaches through the shared interpretation (`jellyfinDisruption` and the two sign-in
    /// situations of the portals); the TV stays at its 27.
    @Test("The number is a decision and not an addition")
    func count() {
        #expect(PlaybackPhase.allCases.count == 32)
        #expect(PlaybackPhase.allCases.count - PlaybackPhase.phoneOnly.count == 27)
        #expect(PlaybackPhase.allCases.count - PlaybackPhase.tvOnly.count == 29)
    }

    /// **The occupied connection carries no button — on no device.**
    ///
    /// On the phone it carried "Check where it is running" until 2026-09-26, and the button
    /// tried again: It used up the one permitted connection a second time.
    @Test("Occupied means wait")
    func busyWithoutButton() {
        #expect(!PlaybackPhase.xtreamBusy.form.hasButton)
    }

    /// **Every button leads to where the situation can be changed.**
    @Test("The targets of the sign-ins")
    func loginTargets() {
        #expect(PlaybackPhase.loginExpired.form.target == .accounts)
        #expect(PlaybackPhase.xtreamAccessExpired.form.target == .channelLists)
        #expect(PlaybackPhase.portalProfileRequired.form.target == .portalSettings)
        #expect(PlaybackPhase.portalLoginRequired.form.target == .portalSettings)
        #expect(PlaybackPhase.certificateUnconfirmed.form.target == .certificate)
        #expect(PlaybackPhase.cameraDenied.form.target == .systemSettings)
    }

    // MARK: - The texts

    /// **Every key of the table is in the shared catalog — in all three languages.**
    ///
    /// A missing key breaks neither the build nor the check; on the device it appears as a
    /// bare name. Lookup uses a placeholder as fallback: If it comes back, the key is missing
    /// in that language.
    @Test("Every key is translated", arguments: ["de", "en", "tr"])
    func everyKeyTranslated(language: String) {
        let bundles = WordingKit.languageBundle(language, in: WordingKit.bundles)
        for key in Self.allKeys {
            let text = bundles.localizedString(forKey: key, value: "∅", table: nil)
            #expect(text != "∅" && text != key, "\(key) missing in \(language)")
        }
    }

    /// **One key set: `state.*`.** Until 2026-09-26 three TV states read `cert.*` and
    /// `error.auth.*` — sets from other areas that said other things there.
    @Test("Every key of a state lives under state.")
    func namespace() {
        for key in Self.stateKeys {
            #expect(key.hasPrefix("state."), "\(key) is outside")
        }
    }

    /// **No two states carry the same heading or the same sentence** — with the one named
    /// exception: ``PlaybackPhase/loadingLong`` is the second stage of ``PlaybackPhase/loadingStart`` and
    /// carries the same first sentence.
    @Test("Headings and sentences are distinct")
    func ownTexts() {
        var headers: [String: PlaybackPhase] = [:]
        var wordings: [String: PlaybackPhase] = [:]
        for state in PlaybackPhase.allCases where state != .loadingLong {
            if let header = state.headline {
                #expect(headers[header] == nil, "\(state) and \(headers[header]!) share \(header)")
                headers[header] = state
            }
            if let message = state.message {
                #expect(wordings[message] == nil, "\(state) and \(wordings[message]!) share \(message)")
                wordings[message] = state
            }
        }
    }

    /// **The stall board has five sentences, and each finding has its own.**
    @Test("The stall sentences are distinct and translated")
    func stall() {
        let wordings = StallInterpretation.Finding.allCases.map(StallWording.key)
        #expect(Set(wordings).count == StallInterpretation.Finding.allCases.count)
        #expect(StallWording.key(nil) == StallWording.key(.undetermined))
    }

    // MARK: - The glyphs

    /// **A typo in a symbol breaks nothing and leaves an empty area.**
    ///
    /// Here every name is actually resolved — on the Mac, so against the macOS catalog.
    /// Whether the glyph also exists on the device with tvOS/iOS 18 is checked by
    /// ``iconsFromMinimumVersion()``.
    @Test("Every glyph resolves")
    func iconsResolve() {
        #if canImport(AppKit)
            for state in PlaybackPhase.allCases {
                guard let name = state.icon else { continue }
                #expect(
                    NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil,
                    "\(state.rawValue): \(name) does not exist")
            }
        #endif
    }

    /// **The Mac runs macOS 27, the device at least 18** (check finding B6 of 2026-09-27): A
    /// glyph from SF Symbols 7 resolved on the Mac and would stay empty on the device.
    @Test("Every glyph exists from the minimum version")
    func iconsFromMinimumVersion() throws {
        let catalog = try #require(GlyphSet.systemSet, "name_availability.plist missing")
        for state in PlaybackPhase.allCases {
            guard let name = state.icon else { continue }
            let defect = catalog.defect(name)
            #expect(defect == nil, "\(state.rawValue): \(defect ?? "")")
        }
    }

    // MARK: - Helpers

    /// The keys that a state carries itself.
    static var stateKeys: [String] {
        PlaybackPhase.allCases.flatMap { state -> [String] in
            switch state.form {
            case .info(let a): [a.headline, a.message] + [a.sidePath].compactMap { $0 }
            case .job(let a):
                [a.headline, a.message, a.button] + [a.sidePath].compactMap { $0 }
            case .load(let l): [l.message, LoadingInfo.slowWording] + [l.sidePath].compactMap { $0 }
            case .muted: []
            }
        }
    }

    /// Plus the path probe and the stall board.
    static var allKeys: [String] {
        stateKeys + RouteProbe.fallbackViaBridge.steps.map(\.message)
            + StallInterpretation.Finding.allCases.map(StallWording.key)
    }
}

/// The one failure interpretation — **its order** (AP58 R3).
///
/// Which rule yields which state is still checked by the platforms through their thin
/// entry points (`ZustandTests`, `DisruptionInterpretationTests`, `SpielerTests`); this file
/// covers **who decides before whom** — exactly where the two versions diverged.
@Suite("Disruption interpretation")
struct DisruptionInterpretationOrderTests {

    private struct Anything: Error {}
    private struct Missing: CarriesState {
        var state: PlaybackPhase { .notSetUpYet }
    }
    private struct Dropout: EngineDropout {}

    /// **1 before 3: What the error itself knows also holds without a network.**
    @Test("An error that carries its state takes precedence over the network")
    func ownBeforeNetwork() {
        #expect(
            DisruptionInterpretation.state(
                forItem: Missing(), source: .jellyfin, offline: .networkAirplaneMode)
                == .notSetUpYet)
    }

    /// **2 before 3: A response is more precise than the network situation** — on the phone
    /// the network came first until 2026-09-26.
    @Test("An answer from the other side takes precedence over the network")
    func responseBeforeNetwork() {
        #expect(
            DisruptionInterpretation.state(
                forItem: JellyfinSource.SourceFailure.unauthorized, source: .jellyfin,
                offline: .networkAirplaneMode) == .loginExpired)
        #expect(
            DisruptionInterpretation.state(
                forItem: XtreamClient.Failure.unauthorized, source: .provider,
                offline: .noConnection) == .xtreamAccessExpired)
    }

    /// **3 before 5: Without a network, no source is blamed** — and each platform says so
    /// with its own state.
    @Test(
        "Without a network the interpretation says that, and not something about the source",
        arguments: DisruptionInterpretation.Source.allCases)
    func networkBeforeOrigin(source: DisruptionInterpretation.Source) {
        #expect(
            DisruptionInterpretation.state(forItem: Anything(), source: source, offline: .noConnection)
                == .noConnection)
        #expect(
            DisruptionInterpretation.state(forItem: Anything(), source: source, offline: .networkAirplaneMode)
                == .networkAirplaneMode)
    }

    /// **3 before 4: Without a network, a stale question is no information about now.**
    @Test("The network takes precedence over the certificate question, the question of the origin")
    func certificatePrompt() {
        let mailbox = CertificatePrompt()
        mailbox.location(
            CertificatePrompt.Pending(
                host: "vault", fingerprint: CertificateFingerprint(value: "AA:BB")))
        #expect(
            DisruptionInterpretation.state(
                forItem: Anything(), source: .provider, offline: .noConnection,
                certificatePrompt: mailbox) == .noConnection)
        #expect(
            DisruptionInterpretation.state(
                forItem: Anything(), source: .provider, certificatePrompt: mailbox)
                == .certificateUnconfirmed)
    }

    /// **The server that answers and gets nowhere is not a network error** — on both devices.
    /// Until 2026-09-26 the phone said "No response" for it.
    @Test("404, 400 and 500 are a disruption on the server")
    func disruptionOnServer() {
        for failure in [
            JellyfinSource.SourceFailure.notFound, .badRequest, .server(status: 500),
        ] {
            #expect(
                DisruptionInterpretation.state(forItem: failure, source: .jellyfin)
                    == .jellyfinDisruption)
        }
        #expect(
            DisruptionInterpretation.state(
                forItem: JellyfinSource.SourceFailure.unreachable, source: .jellyfin)
                == .networkJellyfin)
    }

    /// **An engine abort is the same whether reported as a flag or as an error type.**
    @Test("Marker and error type both count as a dropout")
    func dropoutTwoRoutes() {
        #expect(
            DisruptionInterpretation.state(forItem: Dropout(), source: .jellyfin)
                == .jellyfinWontPlay)
        #expect(
            DisruptionInterpretation.state(forItem: Anything(), source: .jellyfin, fromPlayer: true)
                == .jellyfinWontPlay)
        #expect(DisruptionInterpretation.state(forItem: Dropout(), source: .portals) == .portalAddressExpired)
    }

    /// **The portal errors run through the interpretation** — on both devices they bypassed it
    /// until 2026-09-26, and in opposite directions: on the TV everything came out as
    /// "not resolvable", on the phone everything as "Bridge does not respond".
    @Test("Portal error by kind")
    func portalError() {
        #expect(
            DisruptionInterpretation.state(forItem: PortalBridge.TestError.unreadable, source: .portals)
                == .networkPortals)
        #expect(
            DisruptionInterpretation.state(
                forItem: PortalBridge.TestError.rejected(status: 502, reason: "no host"),
                source: .portals) == .portalUnresolvable)
        #expect(
            DisruptionInterpretation.state(
                forItem: PortalBridge.TestError.cancelled(
                    status: 401, code: "auth.profile_required", values: [:]),
                source: .portals) == .portalProfileRequired)
    }

    /// **The refusal names the state's heading**, and for the network the finer error picture.
    @Test("The rejection")
    func rejection() {
        #expect(
            DisruptionInterpretation.rejection(forItem: Anything(), source: .provider, fromPlayer: true)
                == PlaybackPhase.xtreamBusy.headline)
        let time = URLError(.timedOut)
        #expect(
            DisruptionInterpretation.rejection(forItem: time, source: .jellyfin)
                == ErrorSummary.key(forItem: time))
    }
}
