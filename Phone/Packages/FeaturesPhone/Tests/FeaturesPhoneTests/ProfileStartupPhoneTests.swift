import CloudSync
import Core
import Foundation
import ParentalControls
import PlaylistKit
import ProfileKit
import SourceProbe
import Testing

@testable import FeaturesPhone

/// **The startup on the phone: move, clean cut, PIN requests** — tvOS roadmap AP44/
/// AP48 and counter-check track C (findings 5, 6, R3/R4), 2026-09-25.
@MainActor
@Suite("Profiles on the phone: migration, legacy data, PIN requests")
struct ProfileStartupPhoneTests {

    struct Setup {
        let setup: SetupState
        let sharedStore: SecureStore
        let store: UserDefaults
        let ledger: InMemoryStore
    }

    /// A phone that wants the portals — so that the takeover creates a profile.
    private func setup() -> Setup {
        let name = "probe.\(UUID().uuidString)"
        let sharedStore = SecureStore(service: name)
        let store = UserDefaults(suiteName: name) ?? .standard
        let ledger = InMemoryStore()
        store.set(true, forKey: SetupState.portalsKey)
        let setup = SetupState(
            keychain: sharedStore,
            listen: PlaylistStore(store: InMemoryStore(), secrets: InMemoryStore(), ledger: InMemoryStore()),
            store: store, ledgerStore: ledger)
        return Setup(setup: setup, sharedStore: sharedStore, store: store, ledger: ledger)
    }

    // MARK: - Umzug (R3/R4)

    /// **A move note on the device is completed at startup** — even without iCloud.
    @Test("Startup completes a migration marker")
    func moveDuringStartup() throws {
        try ProfilePointer.als(nil) {
            let a = setup()
            a.setup.createProfiles(fallbackName: "Telefon")
            let legacy = try #require(ProfileBook.read(from: a.ledger).profile.first)
            let target = Profile(identifier: .init(rawValue: "0-ziel"), name: legacy.name)
            var ledger = ProfileBook.read(from: a.ledger)
            ledger.create(target)
            ledger.write(in: a.ledger)
            ProfileTombstone.create(legacy.identifier, target: target.identifier, in: a.ledger)

            _ = ProfilePointer.als(nil) { a.setup.createProfiles(fallbackName: "Telefon") }

            let following = ProfileBook.read(from: a.ledger).profile.map(\.identifier)
            #expect(!following.contains(legacy.identifier), "the marker was not completed")
            #expect(following.contains(target.identifier))
        }
    }

    // MARK: - Sauberer Schnitt (Entscheidung 2)

    @Test("After the takeover the old child list is gone — with proof")
    func oldChildListGone() {
        ProfilePointer.als(nil) {
            let a = setup()
            a.store.set(["srv|kind"], forKey: "accounts.children")
            ChildAccountList(store: a.ledger).adoptOldLists(keychain: a.sharedStore, store: a.store)
            a.setup.createProfiles(fallbackName: "Telefon")
            #expect(ProfileBook.takeoverPending(in: a.ledger))
            #expect(a.store.stringArray(forKey: "accounts.children") == nil)
            #expect(ChildAccountList(store: a.ledger).all() == ["srv|kind"])
        }
    }

    @Test("Without proof the old list stays: content not fully taken over")
    func withoutEvidenceStays() {
        ProfilePointer.als(nil) {
            let a = setup()
            a.store.set(["srv|kind", "srv|fremd"], forKey: "accounts.children")
            ChildAccountList(store: a.ledger).set(kind: true, forItem: "srv|kind")
            a.setup.createProfiles(fallbackName: "Telefon")
            #expect(a.store.stringArray(forKey: "accounts.children") == ["srv|kind", "srv|fremd"])
        }
    }

    @Test("If the takeover fails, everything stays")
    func withoutAdoptionStays() {
        let a = setup()
        a.store.set(false, forKey: SetupState.portalsKey)
        a.store.set(["srv|kind"], forKey: "accounts.children")
        ChildAccountList(store: a.ledger).adoptOldLists(keychain: a.sharedStore, store: a.store)
        // No profile is created (nothing set up) — so nothing to clear.
        #expect(!a.setup.createProfiles(fallbackName: "Telefon"))
        #expect(!ProfileBook.takeoverPending(in: a.ledger))
        #expect(a.store.stringArray(forKey: "accounts.children") == ["srv|kind"])
    }

    /// **The side finding:** "No limit" removes the entry in the Keychain, and the
    /// takeover brought back the limit from before 2026-09-20 at the next start.
    @Test("A disabled limit does not come back after a restart")
    func limitDoesNotReturn() {
        let name = "probe.\(UUID().uuidString)"
        let legacy = UserDefaults(suiteName: name) ?? .standard
        let sharedStore = InMemoryStore()
        legacy.set(AgeLimit.from12.rawValue, forKey: "childLock.ageLimit")
        let first = ParentalControlsState(store: legacy, keychain: sharedStore)
        first.adoptFromStore()
        #expect(first.limit == .from12)
        first.set(limit: nil)

        let restart = ParentalControlsState(store: legacy, keychain: sharedStore)
        restart.adoptFromStore()
        #expect(restart.limit == nil, "the old limit is back")
    }

    // MARK: - PIN requests (finding 6)

    @Test("The requests carry profile name and device — parental controls first")
    func escapeList() {
        let childProfile = Profile(identifier: .init(rawValue: "k-selin"), name: "Selin")
        let max = Profile(identifier: .init(rawValue: "k-max"), name: "Max")
        let list = PinFallbacks(
            parentalControls: .wartetAufServer(device: "Wohnzimmer"),
            profile: [
                childProfile.identifier: .due(device: "Kids room"),
                .init(rawValue: "k-fremd"): .wartetAufServer(device: "Keller"),
                max.identifier: .none,
            ],
            ledger: [max, childProfile])
        #expect(list.entries.map(\.id) == ["aktuell", "profil-k-selin", "profil-k-fremd"])
        #expect(list.entries.map(\.name) == [nil, "Selin", "k-fremd"])
        #expect(list.state(forItem: childProfile.identifier) == .due(device: "Kids room"))
        #expect(list.state(forItem: max.identifier) == nil)
    }

    /// **The connection via the cloud:** A TV requests for a profile, the
    /// phone sees the request, confirms it — and can cancel it.
    @Test("A profile request from the TV can be confirmed and canceled on the phone")
    func profileRequestViaCloud() async {
        let server = MockCloud()
        func device(_ name: String) -> ProfileCloud {
            ProfileCloud(
                hub: CloudHub(
                    service: server.credential("max"), file: nil,
                    device: DeviceDescription(identifier: name, name: name, model: "Test rig")),
                store: InMemoryStore(), moveBundle: nil, automatic: false)
        }
        let tv = device("fernseher")
        let phone = device("telefon")
        let childProfile = Profile(identifier: .init(rawValue: "k-selin"), name: "Selin")
        let ledger = InMemoryStore()
        var entry = ProfileBook()
        entry.create(childProfile)
        entry.write(in: ledger)

        tv.requestPinRecovery(forItem: .profile(childProfile.identifier), device: "Wohnzimmer")
        _ = await tv.household()?.reconcile()

        let seen = await PinFallbacks.read(cloud: phone, ledgerStore: ledger)
        #expect(seen.entries.map(\.name) == ["Selin"])
        #expect(seen.entries.first?.state.pending == true)

        #expect(await PinFallbacks.confirm(.profile(childProfile.identifier), cloud: phone, device: "iPhone"))
        // The check matches by itself (`automatic: false`); in operation the process runs on its own.
        _ = await phone.household()?.reconcile()
        _ = await tv.household()?.reconcile()
        #expect(tv.pinState(forItem: .profile(childProfile.identifier)) == .confirmed(device: "Wohnzimmer"))

        await PinFallbacks.cancel(.profile(childProfile.identifier), cloud: phone)
        _ = await phone.household()?.reconcile()
        _ = await tv.household()?.reconcile()
        #expect(tv.pinState(forItem: .profile(childProfile.identifier)) == .none)
    }

    @Test("The cloud startup reports a request to the surface")
    func startupReports() throws {
        let text = try SourceText.read("CloudStartup.swift", in: .phoneApp)
            .split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        #expect(text.contains("built.pinEscape = { NotificationCenter.default.post(name: .pinEscape"))
    }

    /// **An interpolated value belongs in the key `%@`, not in the string**
    /// (finding of 2026-09-25, three places): `Text(appKey: "childLock.reset.waiting \(device)")`
    /// assembles the text **before** the lookup, and the screen showed the raw
    /// key including the device name. Runtime keys with a dot (`"subtitles.\(scenario)"`)
    /// remain allowed — what is searched for is the space before the interpolation.
    @Test("No Text(appKey:) with an interpolated value")
    func noInsertedKey() throws {
        var discoveries: [String] = []
        for file in try SourceText.files(in: .featuresPhone) {
            for row in file.content.split(separator: "\n")
            where row.contains(/appKey: "[^"]* \\\(/) {
                discoveries.append("\(file.name): \(row.trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(discoveries.isEmpty, "\(discoveries)")
    }
}
