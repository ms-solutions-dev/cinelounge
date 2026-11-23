import CloudSync
import Core
import Foundation
import PortalKit
import ProfileKit
import SourceProbe
import Testing

@testable import Features

/// **The session follows a move from afar** (strand F, 2026-09-25).
///
/// Over the connection: The phone moves the TV's active profile into another one via a
/// move note, the TV syncs, and the shell reloads via
/// ``ProfileModel/loadAfterArrival()`` — the same call that ``ChildGuard`` makes on
/// ``ProfileKit/ProfileCloud/arrived``. Before, this path switched rule and profiles,
/// but not the media-server session.
@MainActor
@Suite("A remote move switches the session")
struct MoveSessionTests {

    let server = MockCloud()
    static let houseA = URL(string: "https://haus-a.example/")!
    static let houseB = URL(string: "https://haus-b.example/")!

    func device(_ name: String) -> (cloud: ProfileCloud, store: InMemoryStore) {
        let store = InMemoryStore()
        let hub = CloudHub(
            service: server.credential("max", name: name), file: nil,
            device: DeviceDescription(identifier: name, name: name, model: "Prüfstand"))
        let cloud = ProfileCloud(hub: hub, store: store, moveBundle: nil, automatic: false)
        cloud.startStore = nil
        return (cloud, store)
    }

    static func session(_ server: URL, _ name: String) -> ServerCredentials {
        ServerCredentials(
            serverURL: server, userID: name.lowercased(), username: name, accessToken: "marke-\(name)")
    }

    static func profile(_ name: String, kind: Profile.Kind = .adult, server: URL?) -> Profile {
        var profile = Profile(name: name, kind: kind)
        if let server {
            profile.create(.jellyfin(server: server, userID: name.lowercased(), username: name))
        }
        return profile
    }

    /// A parent profile is active on the TV and signed in to house A; the phone moves it into
    /// `target`. Returned are what the shell passed to `onSwitched`, and the session afterwards.
    func migration(
        after target: Profile, additionally: [ServerCredentials] = []
    ) async throws -> (episode: ProfileModel.SessionSequence, session: ServerCredentials?) {
        try await ProfilePointer.als(nil) {
            let sharedStore = SecureStore(service: "probe.\(UUID().uuidString)")
            defer { try? sharedStore.clearCredentials() }
            let papa = Self.profile("Papa", server: Self.houseA)
            for credential in [Self.session(Self.houseA, "Papa")] + additionally {
                try sharedStore.memorize(credential)
            }
            try sharedStore.switchTo(server: Self.houseA, user: "papa")

            let tv = device("fernseher")
            var ledger = ProfileBook()
            ledger.create(papa)
            ledger.create(target)
            ledger.switchTo(zu: papa.identifier)
            ledger.write(in: tv.store)
            _ = tv.cloud.household()
            let model = ProfileModel(
                keychain: sharedStore, store: tv.store, cloud: { tv.cloud },
                startStore: UserDefaults(suiteName: "probe.\(UUID().uuidString)")!)
            #expect(model.active == papa.identifier)

            let phone = device("telefon")
            phone.cloud.bury(papa.identifier, target: target.identifier)
            await phone.cloud.household()?.reconcile()
            await tv.cloud.household()?.reconcile()
            #expect(ProfileBook.read(from: tv.store).active == target.identifier)

            let episode = model.loadAfterArrival()
            #expect(model.active == target.identifier)
            // **No loop:** The second pass — the second report of the same
            // arrival — finds nothing left to do.
            #expect(model.loadAfterArrival() == .remains)
            return (episode, try? sharedStore.loadCredentials())
        }
    }

    @Test("For a profile with another Jellyfin server the session is switched")
    func differentServer() async throws {
        let mother = Self.profile("Mama", server: Self.houseB)
        let mothersAccess = Self.session(Self.houseB, "Mama")
        let (episode, session) = try await migration(after: mother, additionally: [mothersAccess])
        #expect(episode == .migrate(mothersAccess))
        #expect(session == mothersAccess)
    }

    /// **The child-protection case:** An adult moves their profile into that of a child
    /// without an account of their own. The adult's media server does not come along
    /// (``ProfileKit/ProfileMerge``) — and the session must not either.
    @Test("For a profile without a Jellyfin server the session is cleared")
    func withoutServer() async throws {
        let kind = Self.profile("Selin", kind: .kind, server: nil)
        let (episode, session) = try await migration(after: kind)
        #expect(episode == .migrate(nil))
        #expect(session == nil)
    }

    /// **Strand G:** The session stays because the media server is the same — but the
    /// target has a different portal person. ``ProfileKit/ProfileSwitch/followUpMove(from:ledgerStore:keychain:deviceStore:)``
    /// rewrites the header; the standing source, built with the parent's header, is stale
    /// afterwards, and ``PortalHeaderGuard`` has to say so.
    @Test("If the session stays but the portal head moves, the bridge is rebuilt")
    func portalHeadMoves() async throws {
        try await ProfilePointer.als(nil) {
            let sharedStore = SecureStore(service: "probe.\(UUID().uuidString)")
            defer { try? sharedStore.clearCredentials() }
            var papa = Self.profile("Papa", server: Self.houseA)
            papa.create(.portals(person: "papa"))
            var second = Profile(name: "Selin")
            second.create(.jellyfin(server: Self.houseA, userID: "papa", username: "Papa"))
            second.create(.portals(person: "selin"))
            try sharedStore.memorize(Self.session(Self.houseA, "Papa"))
            try sharedStore.switchTo(server: Self.houseA, user: "papa")
            // Since 2026-09-28 the header is stored per profile (``Core/DeviceTrait``).
            let fatherSlot = ProfileStore(sharedStore, forItem: papa.identifier.rawValue)
            let secondSlot = ProfileStore(sharedStore, forItem: second.identifier.rawValue)
            DeviceTrait.saveProfile("papa", to: fatherSlot)

            let tv = device("fernseher")
            var ledger = ProfileBook()
            ledger.create(papa)
            ledger.create(second)
            ledger.switchTo(zu: papa.identifier)
            ledger.write(in: tv.store)
            _ = tv.cloud.household()
            let model = ProfileModel(
                keychain: sharedStore, store: tv.store, cloud: { tv.cloud },
                startStore: UserDefaults(suiteName: "probe.\(UUID().uuidString)")!)
            // The standing source, as ``MainView`` builds it at startup.
            let source = PortalSource(
                bridge: PortalBridge(
                    basis: URL(string: "https://bruecke.example/")!,
                    profile: DeviceTrait.profile(from: fatherSlot)))
            #expect(!PortalHeaderGuard.shouldRebuild(source, now: DeviceTrait.profile(from: fatherSlot)))

            let phone = device("telefon")
            phone.cloud.bury(papa.identifier, target: second.identifier)
            await phone.cloud.household()?.reconcile()
            await tv.cloud.household()?.reconcile()

            #expect(model.loadAfterArrival() == .remains)
            #expect(DeviceTrait.profile(from: secondSlot) == "selin")
            #expect(PortalHeaderGuard.shouldRebuild(source, now: DeviceTrait.profile(from: secondSlot)))
        }
    }

    /// **The shell asks the guard on all three switch paths** — arrival from afar,
    /// "Who's watching?" and profile management. ``MainView`` is view code; what is
    /// checked is therefore that the call appears in the source before the session switch.
    @Test("MainView updates the portals on every switch path")
    func wrapperAsksTheGuard() throws {
        let rows = try SourceText.read("MainView.swift", in: .features)
            .split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        let watcher = rows.indices.filter { rows[$0].contains("followPortalHeader()") }
        let switchObserver = rows.indices.filter { rows[$0].contains("onAccountSwitched(credential)") }
        #expect(switchObserver.count == 3)
        // Before every session switch, at most three lines above, stands the guard.
        for location in switchObserver {
            #expect(watcher.contains { (location - 3..<location).contains($0) }, "line \(location + 1)")
        }
    }

    @Test("Without a portal source nothing is built")
    func withoutSourceNothing() {
        #expect(!PortalHeaderGuard.shouldRebuild(nil, now: "selin"))
        #expect(PortalHeaderGuard.shouldRebuild(source: .some(nil), now: "selin"))
        #expect(!PortalHeaderGuard.shouldRebuild(source: .some("selin"), now: "selin"))
    }

    @Test("With the same Jellyfin server the session stays")
    func sameServer() async throws {
        var second = Profile(name: "Papa Zwei")
        second.create(.jellyfin(server: Self.houseA, userID: "papa", username: "Papa"))
        let (episode, session) = try await migration(after: second)
        #expect(episode == .remains)
        #expect(session == Self.session(Self.houseA, "Papa"))
    }
}
