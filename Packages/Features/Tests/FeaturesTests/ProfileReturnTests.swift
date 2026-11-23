import Core
import Flows
import Foundation
import ParentalControls
import PlaylistKit
import ProfileKit
import SourceProbe
import Testing

@testable import Features

/// **The clean cut** — AP48, owner decision 2 of 2026-09-25.
///
/// **Deliberately reversed.** Until 2026-09-25 this suite held that after the takeover
/// every legacy key stands unchanged ("one version readable, so that a rollback
/// is possible"), and named a built-in removal of the account list in the Keychain as its
/// counter-check. The owner decided: no rollback, no version grace period. Now this holds:
/// **After a successful takeover the legacy data is gone and the values are in the
/// profile — and only then.** If the takeover fails, nothing is deleted.
///
/// **Moved here from `ProfilTests`**, because the chain touches three packages (``ProfileKit``,
/// ``ParentalControls``, `PlaylistKit`) and only here are all three visible. What is tested is
/// the **store**, not the parameters — the same lesson as on 2026-09-23: whoever compares
/// the inputs only checks that Swift copies.
///
/// **And the credentials stay.** `server.accounts` carries the access tokens that the
/// profile does not have; whoever cleared them would sign every viewer out. Their staying
/// is therefore just as mandatory here as the disappearance of the rest.
@MainActor
@Suite("The clean cut after the takeover")
struct ProfileReturnTests {

    fileprivate static let server = URL(string: "https://vault.example:8096")!

    fileprivate static func credential(_ name: String) -> Access {
        .jellyfin(server: server, userID: name.lowercased(), username: name)
    }

    fileprivate static func tag(_ name: String) -> String {
        "\(server.absoluteString)|\(name.lowercased())"
    }

    /// What has to be cleared — in the Keychain.
    fileprivate static let deadCatalog = [
        "konten.kinder": "[\"\(tag("Kind"))\"]",
        "vod.memory.v1":
            #"{"film":{"position":4350,"duration":7200,"watched":false,"favorite":false}}"#,
        ["playlists", "favorites", "v1"].joined(separator: "."): #"["iptv#sender-1"]"#,
        "live.lastChannel": "iptv#sender-2",
        "live.lastChannel" + ".iptv": "iptv#sender-2",
    ]

    /// What has to stay although the takeover reads it.
    fileprivate static let alive = [
        "server." + "accounts": #"[{"user":"max"}]"#,
        "setup." + "deviceProfile": "max",
    ]

    fileprivate static var everything: [String: String] {
        deadCatalog.merging(alive) { links, _ in links }
    }

    @Test("After the takeover the old data is gone and the values are in the profile")
    func cut() throws {
        let device = TrialDevice()
        let cleaned = device.starts()

        for key in Self.deadCatalog.keys {
            #expect(device.value(key) == nil, "`\(key)` is still there after the takeover")
            #expect(cleaned.contains(key))
        }
        #expect(device.standard.stringArray(forKey: "accounts.children") == nil)

        let ledger = ProfileBook.read(from: device.ledger)
        let max = try #require(ledger.profile.first { $0.name == "Max" })
        let kind = try #require(ledger.profile.first { $0.name == "Kind" })
        #expect(ledger.active == max.identifier)
        #expect(kind.kind == .kind, "the child mark did not arrive in the profile")
        #expect(ChildAccountList(store: device.ledger).isChild(Self.tag("Kind")))

        let still = StillLedger.read(from: device.ledger, forItem: max.identifier.rawValue).state
        #expect(still.titlePositions["film"]?.location == 4350)
        #expect(still.channelFavorites == ["iptv#sender-1"])
        #expect(still.lastChannel["iptv"] == "iptv#sender-2")
    }

    @Test("Credentials and the login to the CineLounge server stay in place")
    func aliveStays() {
        let device = TrialDevice()
        device.starts()
        for (key, value) in Self.alive {
            #expect(
                device.value(key) == value,
                "`\(key)` is no legacy leftover but the current store")
        }
    }

    @Test("If the takeover fails, nothing is deleted")
    func failed() {
        let device = TrialDevice(ledger: SwallowingStore())
        let cleaned = device.starts()

        #expect(ProfileBook.read(from: device.ledger).profile.isEmpty, "the takeover should fail")
        #expect(cleaned.isEmpty)
        for (key, value) in Self.everything {
            #expect(
                device.value(key) == value,
                "`\(key)` was deleted although nothing was taken over")
        }
        #expect(device.standard.stringArray(forKey: "accounts.children") != nil)
    }

    @Test("A state that has reached no profile stops the cleanup")
    func stateWithoutProfile() {
        let device = TrialDevice()
        StateTransfer.fromDevice(listen: ["iptv"], from: device.keychain, in: device.ledger)
        ProfileBook.adopt(
            jellyfin: [Self.credential("Max")], fallbackName: "Zuhause", version: "1.0",
            in: device.ledger)
        let cleaned = LegacyData.cleanUp(
            ledgerStore: device.ledger, keychain: device.keychain,
            standard: device.standard, listen: ["iptv"])
        #expect(cleaned.isEmpty, "the state sits only in the device base, in no profile yet")
        #expect(device.value("vod.memory.v1") != nil)
    }

    @Test("A child mark that is missing at the new location stays at the old one")
    func childMarkerMissing() {
        let device = TrialDevice()
        device.starts()
        // After the takeover someone still writes to the old place — an older version, say.
        try? device.keychain.set(#"["fremd|kind"]"#, for: "konten.kinder")
        LegacyData.cleanUp(
            ledgerStore: device.ledger, keychain: device.keychain,
            standard: device.standard, listen: ["iptv"])
        #expect(device.value("konten.kinder") != nil, "a child mark that was not taken over got lost")
    }

    /// **The sequence of the startup has been shared since AP58 R2** (``Flows/ProfileStartup``) and is
    /// tested there — including the order "first the state, then clear"
    /// (`ProfileStartupTests`). What remains here is that the TV calls it with **its** steps.
    @Test("The app's startup takes the shared sequence with the TV's steps")
    func wiring() throws {
        let source = try SourceText.read("ProfileStartup.swift", in: .tvApp)
        #expect(source.contains("extension ProfileStartup"))
        #expect(source.contains(".tv,"))
        #expect(!source.contains("LegacyData.cleanUp("), "a second sequence in the app target")
        #expect(!source.contains("ProfileStates.adopt("), "a second sequence in the app target")
    }
}

/// A device with legacy data — Keychain, file store and the phone's old store.
@MainActor
private struct TrialDevice {
    let keychain = InMemoryStore()
    let ledger: any KeyValueStore
    let standard = UserDefaults(suiteName: "probe.\(UUID().uuidString)")!

    init(ledger: any KeyValueStore = InMemoryStore()) {
        self.ledger = ledger
        for (key, value) in ProfileReturnTests.everything {
            try? keychain.set(value, for: key)
        }
        standard.set([ProfileReturnTests.tag("Kind")], forKey: "accounts.children")
    }

    /// The same sequence as `App/Sources/CineLoungeApp.swift` and `App/Sources/ProfileStartup.swift`
    /// — child tokens, state, profiles, state into the profile, then clear.
    @discardableResult
    func starts() -> [String] {
        ChildAccountList(store: ledger).adoptOldLists(
            keychain: keychain, store: standard)
        StateTransfer.fromDevice(listen: ["iptv"], from: keychain, in: ledger)
        ProfileBook.adopt(
            jellyfin: [
                ProfileReturnTests.credential("Max"), ProfileReturnTests.credential("Kind"),
            ],
            children: ChildAccountList(store: ledger).all(),
            channelLists: ["iptv"], wantsPortals: true, portalPerson: "max",
            signedIn: ProfileReturnTests.tag("Max"),
            fallbackName: "Zuhause", version: "1.0", in: ledger)
        ProfileStates.adopt(ProfileBook.read(from: ledger), store: ledger)
        return LegacyData.cleanUp(
            ledgerStore: ledger, keychain: keychain, standard: standard,
            listen: ["iptv"])
    }

    func value(_ key: String) -> String? { try? keychain.value(for: key) }
}

/// A store that swallows the profile book — the on-device finding of 2026-08-16 (`9554c73`).
private final class SwallowingStore: KeyValueStore, @unchecked Sendable {
    let inside = InMemoryStore()
    func value(for key: String) throws -> String { try inside.value(for: key) }
    func set(_ value: String, for key: String) throws {
        guard key != ProfileBook.key else { return }
        try inside.set(value, for: key)
    }
    func remove(_ key: String) throws { try inside.remove(key) }
}
