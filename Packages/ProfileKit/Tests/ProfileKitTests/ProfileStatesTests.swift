import Core
import Foundation
import Testing

@testable import ProfileKit

/// **The state goes to exactly one profile** (AP42, row 5 — 2026-09-21).
///
/// The control test for ``ProfileShelvesTests``: There *everyone* gets the device's arrangement,
/// here **one** gets the state. Whoever treats both alike puts the parents' half-watched
/// films under "Continue Watching" for the child — and thereby restores exactly the finding
/// for which the state ledger was built.
@Suite("The state per profile")
struct ProfileStatesTests {

    private func deviceState() -> StillLedger {
        var state = StillLedger()
        state.record(.titlePosition(title: "l#movie#7", location: 600, duration: 5400))
        state.record(.senderGewaehlt(list: "l", channels: "l#xtream#1"))
        return state
    }

    @Test("Only the signed-in profile gets the device's state")
    func onlyTheSignedIn() {
        let bucket = InMemoryStore()
        deviceState().write(in: bucket)

        let parents = Profile(name: "Eltern")
        let kind = Profile(name: "Kind", kind: .kind)
        let ledger = ProfileBook(profile: [parents, kind], active: parents.identifier)

        #expect(ProfileStates.adopt(ledger, store: bucket))

        #expect(
            StillLedger.read(from: bucket, forItem: parents.identifier.rawValue).state
                .titlePositions["l#movie#7"]?.location == 600)
        #expect(StillLedger.read(from: bucket, forItem: kind.identifier.rawValue) == StillLedger())
    }

    /// **The device baseline stays** — it is the state before the first setup,
    /// and as long as ``ProfileBook`` is empty, the app keeps reading it.
    @Test("The device baseline stays in place")
    func baseStays() {
        let bucket = InMemoryStore()
        deviceState().write(in: bucket)
        let parents = Profile(name: "Eltern")

        ProfileStates.adopt(ProfileBook(profile: [parents], active: parents.identifier), store: bucket)

        #expect(StillLedger.read(from: bucket).state.titlePositions["l#movie#7"]?.location == 600)
    }

    @Test("A second takeover does not replace a grown state")
    func secondAdoptionLeavesAlone() {
        let bucket = InMemoryStore()
        deviceState().write(in: bucket)
        let parents = Profile(name: "Eltern")
        let ledger = ProfileBook(profile: [parents], active: parents.identifier)

        ProfileStates.adopt(ledger, store: bucket)

        var grown = StillLedger.read(from: bucket, forItem: parents.identifier.rawValue)
        grown.record(.senderGewaehlt(list: "l", channels: "l#xtream#9"))
        grown.write(in: bucket, forItem: parents.identifier.rawValue)

        #expect(!ProfileStates.adopt(ledger, store: bucket))
        #expect(
            StillLedger.read(from: bucket, forItem: parents.identifier.rawValue).state.lastChannel["l"]
                == "l#xtream#9")
    }

    @Test("Without a state on the device nothing happens")
    func withoutState() {
        let bucket = InMemoryStore()
        let parents = Profile(name: "Eltern")

        #expect(
            !ProfileStates.adopt(
                ProfileBook(profile: [parents], active: parents.identifier), store: bucket))
    }

    @Test("Without profiles nothing happens")
    func withoutProfiles() {
        let bucket = InMemoryStore()
        deviceState().write(in: bucket)

        #expect(!ProfileStates.adopt(ProfileBook(), store: bucket))
    }
}
