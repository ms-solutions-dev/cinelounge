import Flows
import Foundation
import ProfileKit
import Testing

@testable import Features

/// A2 on the TV — **only what the view decides itself** (AP88 §6: the TV screens get switch
/// checks, the paths are checked in `Flows`).
///
/// Counter-checks: with the profile prefix dropped from `offerFocus` ``focusRoundTrip()`` turns
/// red; with "fromCloud" for every card ``subtitleNamesICloudOnlyWhenItAnswered()``.
@Suite("Setup — A2 on the TV")
struct SetupWelcomeTests {

    static let lea = SetupProfile(Profile(name: "Lea"))

    /// Assembled, so that `scripts/strings.py` does not count the check as a use of the key.
    static func key(_ name: String) -> String { ["setup", "welcome", name].joined(separator: ".") }

    static func offer(_ known: [SetupProfile], cloud: CloudAnswer) -> WelcomeOffer? {
        var machine = SetupMachine(
            steps: .tv, start: .fresh(known: known), isPinSet: false, noticeSeen: false)
        _ = machine.handle(.cloudAnswered(cloud))
        guard case .welcome(let offer) = machine.state else { return nil }
        return offer
    }

    @Test("The focus travels to the machine and back unchanged")
    func focusRoundTrip() {
        for focus in [WelcomeOffer.Focus.newProfile, .profile(Self.lea.id)] {
            #expect(WelcomeView.offerFocus(WelcomeView.focusID(focus)) == focus)
        }
        #expect(
            WelcomeView.offerFocus(WelcomeView.fetchID) == nil, "the machine does not track the fetch button")
        #expect(WelcomeView.offerFocus("lang-de") == nil)
        #expect(WelcomeView.offerFocus(nil) == nil)
    }

    @Test("\"Your iCloud already holds profiles\" only when iCloud brought them")
    func subtitleNamesICloudOnlyWhenItAnswered() throws {
        let fromCloud = try #require(Self.offer([], cloud: .profiles([Self.lea])))
        #expect(WelcomeView.subtitle(for: fromCloud) == Self.key("fromCloud"))
        let known = try #require(Self.offer([Self.lea], cloud: .noProfiles))
        #expect(WelcomeView.subtitle(for: known) == Self.key("known"))
        let fresh = try #require(Self.offer([], cloud: .noAccount))
        #expect(WelcomeView.subtitle(for: fresh) == Self.key("fresh"))
    }
}
