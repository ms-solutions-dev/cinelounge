import Foundation
import Testing

@testable import Core

/// **One rule, one text, both apps** (AP41, 2026-09-21).
///
/// Until here this decision was made twice and **in opposite ways**: on the TV
/// "without a verifiable identifier" was a screen that asks; on the phone a dead end
/// with no way forward. The shared rule is: **do not guess, ask.**
@Suite("Is the server moving?")
struct ServerMigrationTests {

    @Test("The identifier is compared — and where there is none, nothing is guessed")
    func comparison() {
        #expect(
            ServerMove.compare(reported: "abc", previous: "abc", name: "vault")
                == .sameOne(name: "vault"))
        // **The same name is no proof.** "Jellyfin" is the delivery name, and two servers
        // with that name are not rare.
        #expect(
            ServerMove.compare(reported: "xyz", previous: "abc", name: "vault")
                == .other(name: "vault"))
        #expect(
            ServerMove.compare(reported: "abc", previous: nil, name: "vault")
                == .withoutIdentifier(name: "vault"))
    }

    /// **The same server always moves, a different one never** — a consent changes
    /// nothing about that. Whoever presses "yes" confirms that checking **was not
    /// possible**; it does not cancel a finding that speaks against it.
    @Test("The consent applies only to the unverified case")
    func consentAppliesOnlyThere() {
        #expect(ServerMove.mayMove(.sameOne(name: "v"), confirmed: false))
        #expect(ServerMove.mayMove(.other(name: "v"), confirmed: true) == false)
        #expect(ServerMove.mayMove(.withoutIdentifier(name: "v"), confirmed: false) == false)
        #expect(ServerMove.mayMove(.withoutIdentifier(name: "v"), confirmed: true))
    }
}
