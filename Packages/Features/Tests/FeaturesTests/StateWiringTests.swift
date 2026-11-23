import Core
import DesignSystem
import Flows
import Foundation
import JellyfinKit
import SourceProbe
import Testing

@testable import Features

/// **No view builds its own empty or error screen any more** — AP25,
/// 2026-09-11. This is the "done when" promise of this package, as a check.
///
/// **Before, ``StateView`` and ``StateBlock`` had zero callers in the entire
/// production code.** E50 had built them, tested them and given them a
/// demo in Diagnostics; next to it four places drew their own
/// screen — each with its own icon, its own sentence and its own focus rule. Two
/// home-built ones interpret the same failure differently sooner or later, and that
/// was exactly the finding on the phone from 2026-09-06.
@Test("The state view has callers outside the showcase")
func theStatesAreConnected() throws {
    var locations: [String] = []
    for file in try SourceText.files(in: .features) {
        // The folder of the states itself does not count — there stands the construction, not
        // its use. Neither does the demo in Diagnostics.
        guard !("/" + file.relative).contains("/Zustaende/"),
            file.name != "DiagnosticsSettings.swift"
        else { continue }
        for row in file.content.split(separator: "\n") {
            let raw = row.trimmingCharacters(in: .whitespaces)
            guard !raw.hasPrefix("//") else { continue }
            if raw.contains("StateView(") || raw.contains("StateBlock(") {
                locations.append(file.name)
            }
        }
    }

    #expect(
        Set(locations).count >= 3,
        """
        The state views are used in \(Set(locations).count) places: \
        \(Set(locations).sorted().joined(separator: ", ")). At least three are expected \
        (Home screen, portal level, playback start) — otherwise somebody builds their \
        own screen again.
        """
    )
}

/// **Every media-server failure has exactly one state** — from a table.
///
/// Before, there were four translation keys in ``HomeModel``, and whoever read them got
/// a sentence without an icon, without a heading and without a way out.
@Test("The failure table covers every case and separates what needs separating")
func everyFailureHasItsState() {
    #expect(PlaybackPhase.forItem(.unauthorized) == .loginExpired)
    // **"No response" stays separate from "the server reports something".** There you look
    // at the network, here at the server — two different paths for the viewer.
    #expect(PlaybackPhase.forItem(.unreachable) == .networkJellyfin)
    #expect(PlaybackPhase.forItem(.notFound) == .jellyfinDisruption)
    #expect(PlaybackPhase.forItem(.server(status: 500)) == .jellyfinDisruption)
    #expect(PlaybackPhase.forItem(.badRequest) == .jellyfinDisruption)

    // And the same table carries the three views that still show only a text.
    #expect(HomeModel.messageKey(for: .unreachable) == PlaybackPhase.networkJellyfin.message)
}

/// **Without a network the server is not blamed.**
///
/// **Before 2026-09-11 this check was red:** A TV without a network cable and one
/// with the server switched off looked the same — both reported "No response from the
/// media server. Is it running, and is the TV on the same network?". In the first case
/// you then look at the wrong device.
@Test("If the network is missing the interpretation says so — and nothing about the server")
func withoutNetworkTheServerIsNotBlamed() {
    let error = URLError(.timedOut)

    // **A dedicated guard and not the shared one.** Swift Testing runs concurrently;
    // whoever changes ``NetworkWatch/shared`` changes it for everything running alongside.
    let withNetwork = NetworkWatch()
    let offline = NetworkWatch()
    offline.setForTesting(connected: false)

    #expect(
        DisruptionInterpretation.state(forItem: error, origin: .jellyfin, network: withNetwork)
            == .networkJellyfin)

    for origin in [DisruptionInterpretation.SourceKind.jellyfin, .provider, .portals] {
        #expect(
            DisruptionInterpretation.state(forItem: error, origin: origin, network: offline)
                == .noConnection,
            "\(origin) still blames its source without a network")
    }
}

/// **An expired sign-in stays expired, even without a network.**
///
/// The order in ``DisruptionInterpretation`` says what the viewer can change **first** —
/// and a token that the server rejected is rejected, regardless of whether
/// a cable is plugged in.
@Test("The expired sign-in comes before the network question")
func signInComesFirst() {
    let offline = NetworkWatch()
    offline.setForTesting(connected: false)

    #expect(
        DisruptionInterpretation.state(
            forItem: JellyfinSource.SourceFailure.unauthorized, origin: .jellyfin,
            network: offline) == .loginExpired)
}

/// **The network guard's default is "connected".**
///
/// The safe direction: As long as the guard has reported nothing, the app behaves as
/// before. Whoever defaulted to `false` here would show "no
/// connection" for a moment at startup above a network that has long been there.
@Test("A fresh network watch does not claim the network is gone")
func theWatchClaimsNothing() {
    #expect(NetworkWatch().connected)
}
