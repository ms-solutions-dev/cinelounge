import Core
import Foundation
import Testing

@testable import ParentalControls

/// The mark "this is a child account" — **one list for both programs.**
///
/// **Moved here on 2026-09-20** (AP40, from `FeaturesTests/AccountsTests`). Until then
/// the type existed twice: on the TV in the Keychain under `accounts.children`, on the phone
/// in `UserDefaults` under `accounts.children`. A mark set on the TV therefore never
/// arrived on the other side — and the handoff could not take it along, because the bundle
/// has no field for it.
@Suite("The child-account mark")
struct ChildAccountListTests {

    /// The same format as ``Account/Identifier/stored`` in both programs — checked on 2026-09-20
    /// on both sides.
    private func identifier(_ server: String, _ user: String) -> String {
        "\(server)|\(user)"
    }

    @Test("Set and remove again")
    func setAndDelete() {
        let list = ChildAccountList(store: InMemoryStore())
        let who = identifier("https://haus-a.example/", "u1")

        #expect(list.isChild(who) == false)
        list.set(kind: true, forItem: who)
        #expect(list.isChild(who))
        list.set(kind: false, forItem: who)
        #expect(list.isChild(who) == false)
    }

    /// **A mark applies to exactly one account.**
    ///
    /// Two people on one server are two accounts; if the store were kept per server,
    /// a child account would make the adult a child too.
    @Test("A mark affects only one account")
    func onlyOneAccount() {
        let list = ChildAccountList(store: InMemoryStore())
        list.set(kind: true, forItem: identifier("https://haus-a.example/", "kind"))

        #expect(list.isChild(identifier("https://haus-a.example/", "kind")))
        #expect(list.isChild(identifier("https://haus-a.example/", "erwachsen")) == false)
    }

    /// **Removing deletes the entry and does not set it to false.**
    ///
    /// A list that keeps every account ever seen with a truth value grows with
    /// every removed account. The check is therefore made on the store itself.
    @Test("Removing leaves nothing behind")
    func removalLeavesNothingBehind() {
        let store = InMemoryStore()
        let list = ChildAccountList(store: store)
        let who = identifier("https://haus-a.example/", "u1")

        list.set(kind: true, forItem: who)
        list.set(kind: false, forItem: who)

        #expect((try? store.value(for: ChildAccountList.storeKey)) == "[]")
    }

    // MARK: - The move

    @Test("What was in the TV's Keychain comes over")
    func adoptsFromTV() throws {
        let old = InMemoryStore()
        try old.set("[\"https://haus-a.example/|kind\"]", for: "konten.kinder")

        let fresh = InMemoryStore()
        ChildAccountList(store: fresh).adoptOldLists(keychain: old)

        #expect(ChildAccountList(store: fresh).isChild("https://haus-a.example/|kind"))
    }

    /// **Both old places are merged and not weighed against each other.**
    ///
    /// Whoever has used both programs may have marked a different account on each device.
    /// Throwing one of the lists away would mean silently lifting a parental control —
    /// the union blocks, when in doubt, rather too much than too little.
    @Test("TV and phone are merged")
    func mergesBothPlaces() throws {
        let old = InMemoryStore()
        try old.set("[\"a|kind\"]", for: "konten.kinder")

        let defaults = UserDefaults(suiteName: "test.kinderkonten.\(UUID().uuidString)")!
        defaults.set(["b|kind"], forKey: "accounts.children")

        let fresh = InMemoryStore()
        ChildAccountList(store: fresh).adoptOldLists(keychain: old, store: defaults)

        let list = ChildAccountList(store: fresh)
        #expect(list.isChild("a|kind"))
        #expect(list.isChild("b|kind"))
    }

    /// **Exactly once.** Whoever removes a mark after the move should not find it again on the next
    /// start.
    @Test("The move runs only while nothing is at the new place")
    func onlyOnce() throws {
        let old = InMemoryStore()
        try old.set("[\"a|kind\"]", for: "konten.kinder")

        let fresh = InMemoryStore()
        let list = ChildAccountList(store: fresh)
        list.adoptOldLists(keychain: old)
        list.set(kind: false, forItem: "a|kind")

        list.adoptOldLists(keychain: old)
        #expect(list.isChild("a|kind") == false)
    }
}
