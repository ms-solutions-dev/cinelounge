import Foundation
import SourceProbe
import Testing

@testable import Features

/// **The password fields and the paired wire** — AP39, 2026-09-25.
///
/// The pairing itself is tested in the `SecondScreen` package over the real wire. Here it is
/// about the two places where it arrives in the program: Every password field with a remote
/// keyboard registers **as secret**, and the mirror of the remote control arises only through
/// ``SecondScreen/StateMirror/withRemoteKeyboard()`` — there a password stays empty. A
/// source guard, because both are tvOS UI that `swift test` does not draw.
@Suite("Remote pairing wired into the app")
struct RemotePairingWiringTests {

    static func files() throws -> [(String, [Substring])] {
        var all: [(String, [Substring])] = []
        for location in [CodeLocation.tvApp, .features] {
            for file in try SourceText.files(in: location) {
                all.append(
                    (file.name, file.content.split(separator: "\n", omittingEmptySubsequences: false))
                )
            }
        }
        return all
    }

    @Test("Every password field with a remote keyboard registers as secret — and the sign-in field has one")
    func passwordFieldsSecret() throws {
        var withRemoteKeyboard = 0
        for (name, rows) in try Self.files() {
            for (number, row) in rows.enumerated() {
                let raw = row.trimmingCharacters(in: .whitespaces)
                guard !raw.hasPrefix("//"), !raw.hasPrefix("///"), raw.contains("SecureField(") else {
                    continue
                }
                var end = min(number + 7, rows.count)
                if let next = rows[(number + 1)..<end].firstIndex(where: {
                    $0.contains("} else") || $0.contains("TextField(")
                }) {
                    end = next
                }
                let window = rows[number..<end].joined(separator: "\n")
                guard window.contains(".remoteKeyboard(") else { continue }
                withRemoteKeyboard += 1
                #expect(
                    window.contains("isSecret: true"),
                    "\(name):\(number + 1) — a password field with a remote keyboard without `geheim: true`")
            }
        }
        // **Two since AP88 wave 5:** the channel-list form and the hidden field of the
        // ``InputRow``; the old sign-in screen is gone, and the setup's Jellyfin sheet signs in
        // through that hidden field.
        #expect(
            withRemoteKeyboard >= 2,
            "The channel-list form and the hidden field of the input row carry the remote keyboard")
        let jellyfin = try SourceText.read("JellyfinConfirmView.swift", in: .features)
        #expect(jellyfin.contains("isHidden: true, identifier: \"secret\""))
    }

    @Test("The remote-control mirror is created only via mitFerntastatur")
    func mirrorOnlyViaTheBoard() throws {
        let controller = try SourceText.read("RemoteControl.swift", in: .features)
        #expect(controller.components(separatedBy: ".withRemoteKeyboard()").count == 3)
        #expect(!controller.contains("tastaturtext: Ferntastatur.text"))
        #expect(controller.contains("RemotePairingLedger(SecureStore(thisDeviceOnly: true))"))
    }
}
