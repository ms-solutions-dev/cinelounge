import Foundation
import SourceProbe
import Testing

@testable import Features

/// **The remote listens before anyone is signed in** — AP39, 2026-09-20.
///
/// The finding of 2026-09-19: ``RemoteControl/start()`` has been only in
/// ``MainView/onStart()`` since AP8, and that runs only behind the sign-in. On a fresh TV,
/// however, the sign-in field is exactly the place where typing is most expensive — the
/// fields there have long carried the remote-keyboard tap, the listener was missing.
///
/// **A guard over the source and not a check on the network.** What counts here is the place
/// of the call; opening a real `NWListener` in a check would mean registering a service on
/// the home network in every run.
@Test("The listener starts at program start and not only after login")
func remoteListensBeforeSignIn() throws {
    let entry = try SourceText.read("CineLoungeApp.swift", in: .tvApp)

    let invocations = entry.split(separator: "\n")
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        .contains { $0.contains("RemoteControl.shared.start()") }

    #expect(
        invocations,
        """
        `RemoteControl.shared.start()` is missing from the program entry point. Without it \
        nobody listens on the sign-in screen, and the remote keyboard is unreachable \
        exactly where it saves the most effort.
        """
    )
}
