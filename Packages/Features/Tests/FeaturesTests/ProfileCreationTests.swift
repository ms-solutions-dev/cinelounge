import Core
import Foundation
import ProfileKit
import SourceProbe
import Testing

@testable import Features

/// **"Add profile" is always in "Who's watching?"** (AP45/AP48, owner decision 3
/// of 2026-09-25), and the number pad with "Forgot PIN" is the same in both places.
@MainActor
@Suite("Who's watching? — Creating and number pad")
struct ProfileCreationTests {

    @Test("The + card is there with zero, one and three profiles", arguments: [0, 1, 3])
    func alwaysThere(profile: Int) {
        let actionList = AccountSwitcher.actions(profile: profile, switchOnly: false)
        #expect(actionList.first == .create, "\"Create profile\" is missing with \(profile) profile(s)")
        #expect(actionList.contains(.manage))
    }

    /// **Nobody adds a profile from the child interface** — a new one would be one without a
    /// limit (strand A: `switchOnly`).
    @Test("When only switching, no card is there, not even the + card", arguments: [1, 3])
    func switchOnly(profile: Int) {
        #expect(AccountSwitcher.actions(profile: profile, switchOnly: true).isEmpty)
    }

    /// The connection: the switcher passes `switchOnly` on to the calculation.
    @Test("The switcher passes switchOnly on to the actions")
    func onlySwitchingWiredUp() throws {
        let source = try SourceText.read("AccountSwitcher.swift", in: .features)
        #expect(source.contains("Self.actions(profile: model.profile.count, switchOnly: switchOnly)"))
    }

    @Test("With an Apple account it is fetched via the code, without one via the wire")
    func pullMode() {
        #expect(ProfileCreation.pullMode(cloud: true) == .cloud)
        #expect(ProfileCreation.pullMode(cloud: false) == .wire)
    }

    @Test("Without the cloud no third button")
    func recovery() {
        #expect(ProfilePinSheet.offersEscape(cloud: true))
        #expect(!ProfilePinSheet.offersEscape(cloud: false))
    }

    /// **The connection:** Until now the management screen switched to a protected profile
    /// without a number pad — the press fizzled. What is read is that both places show the same
    /// number pad and give it the cloud, without which there is no way out.
    @Test("Switcher and management show the same number pad, cloud included")
    func passThrough() throws {
        let administration = try SourceText.read("ProfileView.swift", in: .features)
        let switcher = try SourceText.read("AccountSwitcher.swift", in: .features)

        #expect(
            administration.contains(
                "ProfilePinSheet(\n                    profile: target, cloud: ProfileCloud.attached"))
        #expect(switcher.contains("ProfilePinSheet(\n                    profile: target, cloud: cloud"))
        // The switch from the management screen (`case .pin:` → `pinTarget = profile`) was dropped
        // with AP59 N3 — a press there edits. The number pad stays for removing.
        #expect(!switcher.contains(/\bPinSheet\(/), "the switcher builds its own number pad again")
    }
}
