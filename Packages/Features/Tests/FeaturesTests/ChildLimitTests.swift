import Core
import Foundation
import ParentalControls
import ProfileKit
import Testing

@testable import Features

/// **A child's limit, set on the child** — AP45, decision 7 of 2026-09-24.
///
/// Until here there was only one write path, and it went to the **device**. What an adult
/// wanted to set for a child thereby landed at the base of everyone — or, had the identifier
/// simply been passed through, at the **active** profile, that is, at the adult themself.
/// Both silent.
@MainActor
@Suite("The limit on the child profile")
struct ChildLimitTests {

    private func state(_ store: InMemoryStore) -> ParentalControlsState {
        ParentalControlsState(
            store: store, childAccounts: ChildAccountList(store: InMemoryStore()),
            profileStore: InMemoryStore(),
            childMode: ChildMode(store: UserDefaults(suiteName: UUID().uuidString)!))
    }

    /// **The connection:** written on the child, read on the child — and nowhere else.
    @Test("The limit belongs to the child and not to the device")
    func belongsToChild() {
        let store = InMemoryStore()
        let state = state(store)
        state.set(limit: .from6, forItem: "selin")
        #expect(state.ownLimit(forItem: "selin") == .from6)
        #expect(AgeLimit.read(from: store) == nil, "the device baseline stays untouched")
        #expect(state.ownLimit(forItem: "max") == nil, "another profile gets none of it")
    }

    /// **And it takes effect where it is read** — over the same route the state uses when
    /// blocking. A limit that is stored somewhere other than where it is read would look like
    /// "nothing set".
    @Test("The set limit is the one in force for this child")
    func appliesWhenReading() {
        let store = InMemoryStore()
        state(store).set(limit: .from6, forItem: "selin")
        #expect(AgeLimit.applicable(from: store, forItem: "selin") == .from6)
    }

    /// **"As on the device" really means as on the device:** Without a limit of its own the base
    /// applies, with one of its own the stricter of the two.
    @Test("Without its own limit the baseline applies, with one the stricter of the two")
    func baseAndStricter() {
        let store = InMemoryStore()
        AgeLimit.write(.from12, in: store)
        let state = state(store)
        #expect(AgeLimit.applicable(from: store, forItem: "selin") == .from12)
        state.set(limit: .from6, forItem: "selin")
        #expect(AgeLimit.applicable(from: store, forItem: "selin") == .from6)
        state.set(limit: .from16, forItem: "selin")
        #expect(
            AgeLimit.applicable(from: store, forItem: "selin") == .from12,
            "a looser limit on the child does not lift the baseline")
        state.set(limit: nil, forItem: "selin")
        #expect(state.ownLimit(forItem: "selin") == nil)
    }

    /// **The edited profile, not the active one** — and for a new one the freshly assigned
    /// identifier.
    @Test("The limit belongs to the edited profile or to the newly created one")
    func targetProfile() {
        let kind = Profile(identifier: .init(rawValue: "selin"), name: "Selin", kind: .kind)
        #expect(ProfileTarget.limitBelongsTo(kind, fresh: nil) == .init(rawValue: "selin"))
        #expect(ProfileTarget.limitBelongsTo(nil, fresh: .init(rawValue: "neu")) == .init(rawValue: "neu"))
        #expect(ProfileTarget.limitBelongsTo(nil, fresh: nil) == nil)
    }
}
