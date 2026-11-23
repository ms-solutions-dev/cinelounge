import Foundation
import PortalKit
import Testing

@testable import Household

/// **Who gets a mark of their own: the right decides, not the role label** (AP85, 2026-11-09).
///
/// Since the console rebuild roles are data. A person in the adult role with the 18+ lock
/// is still reported as `child` in the derived label — and asking the label kept her from
/// signing in a second device of her own, although the server allows it (`own_devices`).
@Suite("A mark of one's own")
struct OwnMarkTests {

    private func person(role: String, rights: String?) throws -> HouseholdPerson {
        let rightsPart = rights.map { #","rights":{\#($0)}"# } ?? ""
        let raw = ##"{"id":"p","name":"P","role":"\##(role)","color":"#4A90D9"\##(rightsPart)}"##
        return try JSONDecoder().decode(HouseholdPerson.self, from: Data(raw.utf8))
    }

    @Test("Labelled child, but own devices allowed: gets a mark")
    func lockedAdultRole() throws {
        #expect(TokenReconciliation.holdsOwnMark(try person(role: "child", rights: #""own_devices":true"#)))
    }

    @Test("Labelled adult, but own devices not allowed: no mark")
    func adultWithoutTheRight() throws {
        #expect(!TokenReconciliation.holdsOwnMark(try person(role: "adult", rights: #""own_devices":false"#)))
    }

    /// An older server names no `own_devices` — there the label still decides.
    @Test("Older server without the right: the label decides as before")
    func olderServer() throws {
        #expect(!TokenReconciliation.holdsOwnMark(try person(role: "child", rights: #""watch":true"#)))
        #expect(TokenReconciliation.holdsOwnMark(try person(role: "adult", rights: #""watch":true"#)))
        #expect(TokenReconciliation.holdsOwnMark(try person(role: "adult", rights: nil)))
    }
}
