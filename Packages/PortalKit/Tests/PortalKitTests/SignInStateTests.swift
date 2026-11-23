import Foundation
import Testing

@testable import PortalKit

/// What each situation allows the screen.
///
/// **The situations themselves are checked by the live series** — they arise from three requests and
/// five refusals, and a test double for that would only check the replica. Here is what follows from
/// a **given** situation, and that is the question every screen asks.
@Suite("What a sign-in state allows")
struct SignInStateTests {

    private func person(permissions: AccessRights?) -> HouseholdPerson {
        let bodyContent =
            permissions == nil
            // `##"…"##`, because `"#` in the colour would otherwise close the raw string.
            ? ##"{"id":"max","name":"Max","role":"admin","color":"#E2564A"}"##
            : ##"{"id":"max","name":"Max","role":"admin","color":"#E2564A","adult":true,"rights":{"pair_devices":true,"watch":true}}"##
        return try! JSONDecoder().decode(HouseholdPerson.self, from: Data(bodyContent.utf8))
    }

    /// The bridge knows no persons — and holds up anyway.
    @Test("The bridge works without sign-in, but may manage nothing")
    func bridge() {
        let state = SignInState.bridge
        #expect(state.carries)
        #expect(state.person == nil)
        #expect(state.isAllowed(\.pairDevices) == false)
    }

    @Test("Signed in works and may, what the rights say")
    func signedIn() {
        let full = person(permissions: AccessRights.all)
        let state = SignInState.signedIn(full, isBorrowed: false)
        #expect(state.carries)
        #expect(state.person?.name == "Max")
        #expect(state.isAllowed(\.pairDevices))
        #expect(state.isAllowed(\.workshop) == false)
    }

    /// **The case that otherwise falls through.** A borrowed profile may watch and not manage — **even
    /// if it is an admin.** The server rejects it with `403 auth.borrowed_profile`; the app should not
    /// offer the buttons beforehand.
    @Test("A borrowed profile may watch, not manage")
    func isBorrowed() {
        let state = SignInState.signedIn(person(permissions: AccessRights.all), isBorrowed: true)
        #expect(state.carries)
        #expect(state.person?.role == "admin")
        #expect(state.isAllowed(\.pairDevices) == false)
        #expect(state.isAllowed(\.watch) == false)
    }

    @Test("No state without sign-in works")
    func withoutSignIn() {
        for state: SignInState in [
            .setupRequired, .notSignedIn([]), .profileRequired([]), .unreachable,
            .appZuAlt(version: "9.9.9"),
        ] {
            #expect(state.carries == false)
            #expect(state.isAllowed(\.watch) == false)
        }
    }

    /// The profile choice travels along, so that the screen does not ask a second time.
    @Test("Profile picker and profile loan carry their list along")
    func listsTravelAlong() {
        let people = [person(permissions: nil)]
        guard case .notSignedIn(let a) = SignInState.notSignedIn(people),
            case .profileRequired(let b) = SignInState.profileRequired(people)
        else { Issue.record("state without a list"); return }
        #expect(a.count == 1)
        #expect(b.first?.name == "Max")
        // In the profile choice the list is harmless: no age, no rights.
        #expect(a.first?.permissions == nil)
    }
}

extension AccessRights {
    /// A set of rights for tests — `pair_devices` and `watch`, nothing else.
    fileprivate static var all: AccessRights {
        try! JSONDecoder().decode(
            AccessRights.self, from: Data(#"{"pair_devices":true,"watch":true}"#.utf8))
    }
}
