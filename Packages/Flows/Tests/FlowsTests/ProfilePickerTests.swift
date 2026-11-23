import Core
import Foundation
import ParentalControls
import ProfileKit
import Testing

@testable import Flows

/// **"Who's watching?" is the same rule on both devices** (G3, finding B2) — checked via
/// the shared ``ProfileManagement``, which both devices call, and the interpretation in
/// ``ProfilePicker``.
@MainActor
@Suite("Who is watching? — shared rule")
struct ProfilePickerTests {

    private func administration() -> (ProfileManagement, SecureStore) {
        let secureStore = SecureStore(service: "probe.\(UUID().uuidString)")
        let administration = ProfileManagement(
            keychain: secureStore, store: InMemoryStore(), cloud: { nil },
            startStore: UserDefaults(suiteName: "probe.\(UUID().uuidString)")!)
        return (administration, secureStore)
    }

    /// **Finding 2026-11-09:** after an install the TV stood in the main screen without an
    /// active profile — and everything personal (CL-Server key, join request) failed silently.
    @Test("Profiles but none active: the question comes, whatever the curtain says")
    func asksWithoutActive() {
        #expect(ProfilePicker.asksWithoutActive(active: nil, profiles: 1, protectionActive: false))
        #expect(ProfilePicker.asksWithoutActive(active: nil, profiles: 3, protectionActive: false))
        #expect(!ProfilePicker.asksWithoutActive(active: nil, profiles: 0, protectionActive: false))
        #expect(
            !ProfilePicker.asksWithoutActive(
                active: Profile.Identifier(rawValue: "a"), profiles: 3, protectionActive: false))
        #expect(
            !ProfilePicker.asksWithoutActive(active: nil, profiles: 3, protectionActive: true),
            "the protection has its own door")
    }

    @Test("A profile without a media server is selectable and clears the session")
    func withoutMediaServer() throws {
        let (administration, _) = administration()
        try ProfilePointer.als(nil) {
            let parent = try #require(
                administration.create(name: "Parent", color: .turquoise, kind: .adult, avatar: nil))
            let kind = try #require(
                administration.create(name: "Child", color: .moss, kind: .kind, avatar: nil))
            #expect(ProfilePicker.reply(to: administration.switchTo(zu: parent)) == .switched)
            let outcome = administration.switchTo(zu: kind)
            #expect(ProfilePicker.reply(to: outcome) == .switched)
            #expect(ProfilePointer.active == kind.rawValue)
            let foreign = ServerCredentials(
                serverURL: try #require(URL(string: "https://jellyfin.beispiel")), userID: "parent",
                username: "Parent", accessToken: "t")
            #expect(outcome.result?.didSwitchSession == false)
            #expect(
                ProfilePicker.session(after: outcome.result, load: { foreign }) == nil,
                "only a switched session is passed on")
        }
    }

    @Test("A profile PIN requires the keypad, the right one switches")
    func withPin() throws {
        let (administration, secureStore) = administration()
        try ProfilePointer.als(nil) {
            let parent = try #require(
                administration.create(name: "Parent", color: .turquoise, kind: .adult, avatar: nil))
            let grandmother = try #require(
                administration.create(name: "Grandma", color: .moss, kind: .adult, avatar: nil))
            defer { ProfilePIN(store: secureStore, forItem: grandmother).forget() }
            #expect(
                ProfilePINMaintenance.set(
                    "4711", old: nil, forItem: grandmother, keychain: secureStore, cloud: nil,
                    now: Date()) == .isSet)
            #expect(administration.switchTo(zu: parent).result != nil)
            #expect(ProfilePicker.reply(to: administration.switchTo(zu: grandmother)) == .pin)
            #expect(ProfilePicker.reply(to: administration.switchTo(zu: grandmother, pin: "0000")) == .pin)
            #expect(administration.active == parent, "a wrong PIN switches nothing")
            #expect(
                ProfilePicker.reply(to: administration.switchTo(zu: grandmother, pin: "4711")) == .switched)
        }
    }

    @Test("Create is always there, except when merely switching")
    func actions() {
        #expect(ProfilePicker.actions(switchOnly: false).first == .create)
        #expect(ProfilePicker.actions(switchOnly: false) == [.create, .manage])
        #expect(ProfilePicker.actions(switchOnly: true).isEmpty)
    }

    @Test("The own profile does not trigger a switch")
    func own() {
        let identifier = Profile(name: "A").identifier
        #expect(!ProfilePicker.triggers(identifier, active: identifier))
        #expect(ProfilePicker.triggers(identifier, active: nil))
    }

    // MARK: - Creating and changing via the shared draft (B1)

    @Test("A new child gets its limit, an adult none")
    func creatingWithLimit() throws {
        let (administration, secureStore) = administration()
        let kind = try #require(
            administration.save(
                ProfileDraft(name: "Sam", color: .moss, kind: .kind, limit: .from6, avatar: nil),
                existing: nil))
        defer { AgeLimit.write(nil, in: secureStore, forItem: kind.rawValue) }
        #expect(administration.profile.first { $0.identifier == kind }?.kind == .kind)
        #expect(administration.limit(forItem: kind) == .from6)

        let grownUp = try #require(
            administration.save(
                ProfileDraft(name: "Parent", color: .turquoise, kind: .adult, limit: .from6, avatar: nil),
                existing: nil))
        #expect(administration.limit(forItem: grownUp) == nil, "the limit applies only to a child")
    }

    @Test("Changing keeps the kind and sets the limit on the edited profile")
    func changingKeepsKind() throws {
        let (administration, secureStore) = administration()
        let kind = try #require(
            administration.create(name: "Sam", color: .moss, kind: .kind, avatar: nil))
        defer { AgeLimit.write(nil, in: secureStore, forItem: kind.rawValue) }
        let previous = try #require(administration.profile.first { $0.identifier == kind })
        let fresh = administration.save(
            ProfileDraft(name: "Sam M.", color: .coral, kind: .adult, limit: .from12, avatar: nil),
            existing: previous)
        #expect(fresh == nil, "Changing creates nothing")
        let after = try #require(administration.profile.first { $0.identifier == kind })
        #expect(after.name == "Sam M.")
        #expect(after.color == .coral)
        #expect(after.kind == .kind, "the kind stays as it was created")
        #expect(administration.limit(forItem: kind) == .from12)
        #expect(administration.profile.count == 1)
    }

    @Test("An empty name does not save")
    func emptyName() {
        let (administration, _) = administration()
        let draft = ProfileDraft(name: "   ", color: .moss, kind: .adult, limit: nil, avatar: nil)
        #expect(!draft.isValid)
        #expect(administration.save(draft, existing: nil) == nil)
        #expect(administration.profile.isEmpty)
    }

    @Test("The curtain at start: only without an active lock")
    func gate() {
        #expect(ProfilePicker.asksAtStart(.whoIsWatching, protectionActive: false))
        #expect(!ProfilePicker.asksAtStart(.whoIsWatching, protectionActive: true))
        #expect(!ProfilePicker.asksAtStart(.none, protectionActive: false))
    }

    /// **Once per program run** (audit wrapper H3): a rebuild of the wrapper through the
    /// language of the chosen profile is not a start. A No also consumes the start.
    @Test("The curtain appears once per program run, on both devices")
    func curtainOnce() {
        ProfilePointer.als(nil) {
            #expect(ProfilePicker.asksNow(.whoIsWatching, protectionActive: false))
            #expect(!ProfilePicker.asksNow(.whoIsWatching, protectionActive: false))
        }
        ProfilePointer.als(nil) {
            #expect(!ProfilePicker.asksNow(.whoIsWatching, protectionActive: true))
            #expect(!ProfilePicker.asksNow(.whoIsWatching, protectionActive: false))
        }
    }
}
