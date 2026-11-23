import Core
import Foundation
import PlaylistKit
import ProfileKit
import Testing

@testable import SecondScreen

/// **The people in the bundle — version 2** (AP44, 2026-09-21).
///
/// The wire is the way back for devices without iCloud. Up to here it carried the
/// **signed-in access** and nothing else of the family: on the TV a set-up device arrived
/// with one person, while four stood on the phone.
@Suite("The profile ledger over the wire")
@MainActor
struct ProfileBundleTests {

    private func takeover(ledger: any KeyValueStore) -> Takeover {
        let name = "probe.\(UUID().uuidString)"
        return Takeover(
            keychain: SecureStore(service: name),
            listen: PlaylistStore(store: InMemoryStore(), secrets: InMemoryStore(), ledger: InMemoryStore()),
            trust: CertificateTrustStore(store: InMemoryStore()),
            store: UserDefaults(suiteName: name) ?? .standard,
            shelfStore: InMemoryStore(), ledgerStore: ledger)
    }

    @Test("The profiles from the bundle are in the ledger afterwards")
    func profilesArrive() throws {
        let bucket = InMemoryStore()
        let report = takeover(ledger: bucket).matches(
            code: SetupBundle(
                profile: [
                    Profile(name: "Alex", color: .turquoise),
                    Profile(name: "Sam", color: .coral, kind: .kind),
                ]))

        #expect(report.profile == 2)
        let ledger = ProfileBook.read(from: bucket)
        #expect(ledger.profile.map(\.name) == ["Alex", "Sam"])
        #expect(ledger.profile.last?.kind == .kind)
    }

    /// **The wire adds and takes nothing away.** The same rule as with the channel lists and
    /// the shelf order: whoever emptied their first device while setting up a second would lose
    /// something nobody had announced.
    @Test("A profile that is already here stays unchanged")
    func existingStays() throws {
        let bucket = InMemoryStore()
        let identifier = Profile.Identifier.fresh()
        var ledger = ProfileBook()
        ledger.create(Profile(identifier: identifier, name: "Alex on the TV", color: .moss))
        ledger.write(in: bucket)

        let report = takeover(ledger: bucket).matches(
            code: SetupBundle(
                profile: [
                    Profile(identifier: identifier, name: "Alex on the phone", color: .amber),
                    Profile(name: "Sam"),
                ]))

        // One is new, one was there.
        #expect(report.profile == 1)
        let following = ProfileBook.read(from: bucket)
        #expect(following.profile.count == 2)
        #expect(following.profile.first?.name == "Alex on the TV")
        #expect(following.profile.first?.color == .moss)
    }

    /// **Whoever sits in front of it is decided by this device.** A bundle that brought the
    /// active person along would switch the person on the TV — triggered by someone standing at
    /// the phone. That is why the field does not exist in the first place.
    @Test("The active person on the TV stays who they were")
    func activeOneStays() throws {
        let bucket = InMemoryStore()
        var ledger = ProfileBook()
        let otherProfile = Profile(name: "Pat")
        ledger.create(otherProfile)
        ledger.write(in: bucket)

        _ = takeover(ledger: bucket).matches(
            code: SetupBundle(profile: [Profile(name: "Alex")]))

        #expect(ProfileBook.read(from: bucket).active == otherProfile.identifier)
    }

    @Test("A bundle without profiles does not touch the ledger")
    func withoutProfiles() throws {
        let bucket = InMemoryStore()
        var ledger = ProfileBook()
        ledger.create(Profile(name: "Alex"))
        ledger.write(in: bucket)

        let report = takeover(ledger: bucket).matches(code: SetupBundle())
        #expect(report.profile == 0)
        #expect(ProfileBook.read(from: bucket).profile.count == 1)
    }

    // MARK: - The old version

    /// **A bundle of version 1 has no profile field** — and ``acceptable(version:)`` says yes
    /// to it anyway. Without a reader that tolerates the missing field, the promise "older
    /// bundles are understood completely" would run into a wall with the first old phone: the
    /// generated default reader throws when a key is missing.
    @Test("A bundle of version 1 can still be read")
    func oldVersionStaysReadable() throws {
        let legacy = """
            {"fassung":1,"senderlisten":[],"regalreihenfolge":["resume"],
             "sportarten":[],"gruppenreihenfolge":[],"versteckteGruppen":[],
             "sprache":"de"}
            """
        let bundles = try JSONDecoder().decode(
            SetupBundle.self, from: Data(legacy.utf8))

        #expect(bundles.version == 1)
        #expect(bundles.profile.isEmpty)
        #expect(bundles.language == "de")
        #expect(bundles.shelfOrder == ["resume"])
        #expect(SetupBundle.acceptable(version: bundles.version))
    }

    /// And the way there and back through the real channel.
    @Test("The profiles survive the sealed packet")
    func throughThePackage() throws {
        let key = HandoffKey.fresh(target: "CineLounge-ABCD")
        let bundles = SetupBundle(profile: [Profile(name: "Alex", color: .lilac)])
        let packet = try HandoffPackage.seal(bundles, using: key)
        let back = try HandoffPackage.open(packet, using: key)

        #expect(back.profile.map(\.name) == ["Alex"])
        #expect(back.profile.first?.color == .lilac)
    }
}
