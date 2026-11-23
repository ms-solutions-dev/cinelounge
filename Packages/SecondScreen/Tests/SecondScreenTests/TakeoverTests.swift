import Core
import Foundation
import ParentalControls
import PlaylistKit
import Testing

@testable import SecondScreen

/// What an arrived bundle really does on the second device.
///
/// **The check that exists without two devices.** Whether the wire holds is told only by a
/// TV; what becomes of the bundle once it is there is told by this file — and at the places
/// where a failure would stay **silent**: an account list that stays empty although the
/// sign-in stands; parental controls that stand switched on without a PIN that opens them;
/// a channel list without its password.
@Suite("A bundle is applied")
@MainActor
struct TakeoverTests {

    /// - Parameter regale: The store of the shelf order. **Always passed in**, otherwise a
    ///   check would write into the file of the running device.
    private func setup(
        shelves: any KeyValueStore = InMemoryStore()
    ) -> (Takeover, SecureStore, PlaylistStore, UserDefaults) {
        let name = "probe.\(UUID().uuidString)"
        let secureStore = SecureStore(service: name)
        let listen = PlaylistStore(store: InMemoryStore(), secrets: InMemoryStore(), ledger: InMemoryStore())
        let store = UserDefaults(suiteName: name) ?? .standard
        let takeover = Takeover(
            keychain: secureStore, listen: listen,
            trust: CertificateTrustStore(store: InMemoryStore()), store: store,
            shelfStore: shelves)
        return (takeover, secureStore, listen, store)
    }

    @Test("The media server lands in the account list AND in the session")
    func serverLandsInBoth() throws {
        let (takeover, secureStore, _, _) = setup()
        let bundles = SetupBundle(
            jellyfin: .init(
                address: URL(string: "https://jellyfin.example")!, userID: "u1",
                username: "Alex", accessToken: "token"))

        let report = takeover.matches(code: bundles)

        // **Both, and that is not redundant.** Writing only the session was the bug on the phone
        // that a third of all findings hung on: the account list always stayed empty in the
        // shipping path, and the account switch had nothing to switch.
        #expect((try? secureStore.loadCredentials())?.userID == "u1")
        #expect(secureStore.allAccounts().contains { $0.userID == "u1" }, "the account list is filled")
        #expect(report.jellyfin == "Alex")
    }

    @Test("The certificate trust comes along")
    func trustComesAlong() {
        let name = "probe.\(UUID().uuidString)"
        let trust = CertificateTrustStore(store: InMemoryStore())
        let takeover = Takeover(
            keychain: SecureStore(service: name),
            listen: PlaylistStore(store: InMemoryStore(), secrets: InMemoryStore(), ledger: InMemoryStore()),
            trust: trust, store: UserDefaults(suiteName: name) ?? .standard)

        takeover.matches(
            code: SetupBundle(
                jellyfin: .init(
                    address: URL(string: "https://jellyfin.example")!, userID: "u1",
                    username: "Alex", accessToken: "token",
                    trusted: ["jellyfin.example": "ab:cd:ef"])))

        // Without the fingerprint, the first load would raise a security question nobody can
        // answer — there is nothing to compare against.
        //
        // **It is compared against the normalized spelling**, not against the text from the
        // bundle: ``CertificateFingerprint`` uppercases. That is the commitment the handoff stands
        // on — two devices that spell the same digest differently would take the same server for
        // two.
        #expect(
            trust.fingerprint(for: "jellyfin.example")
                == CertificateFingerprint(value: "ab:cd:ef"))
    }

    @Test("A channel list arrives together with its password")
    func listComesWithPassword() {
        let (takeover, _, listen, _) = setup()

        takeover.matches(
            code: SetupBundle(channelLists: [
                .init(
                    identifier: "xtream1", name: "iptvhost",
                    address: URL(string: "http://anbieter.example")!, user: "alex",
                    password: "secret")
            ]))

        #expect(listen.playlists.count == 1)
        #expect(listen.password(for: "xtream1") == "secret", "otherwise the TV asks for it")
        if case .xtream(_, let user) = listen.playlists.first?.kind {
            #expect(user == "alex")
        } else {
            Issue.record("a credential with a user name is an Xtream credential, not an M3U file")
        }
    }

    @Test("Without a user name it is an M3U file")
    func withoutUserItIsM3U() {
        let (takeover, _, listen, _) = setup()

        takeover.matches(
            code: SetupBundle(channelLists: [
                .init(
                    identifier: "liste1", name: "Datei",
                    address: URL(string: "http://beispiel.example/liste.m3u")!)
            ]))

        if case .m3u = listen.playlists.first?.kind {
        } else {
            Issue.record("without a user name there is no provider credential")
        }
    }

    @Test("Parental controls are in place only once their PIN is in place")
    func parentalControlsWithPIN() {
        let name = "probe.\(UUID().uuidString)"
        let secureStore = SecureStore(service: name)
        let store = UserDefaults(suiteName: name) ?? .standard
        let takeover = Takeover(
            keychain: secureStore,
            listen: PlaylistStore(store: InMemoryStore(), secrets: InMemoryStore(), ledger: InMemoryStore()),
            trust: CertificateTrustStore(store: InMemoryStore()), store: store)

        // The extract of a PIN "4711" from another device.
        let phonePin = Pin(store: InMemoryStore())
        #expect(phonePin.set("4711"))
        let extract = phonePin.extract

        takeover.matches(
            code: SetupBundle(
                parentalControls: .init(active: true, pin: extract, ageLimit: 12)))

        // **The actual commitment:** the switch is on — and the PIN that opens it is set too. A
        // lock without a key would be a TV nobody can get out of.
        #expect(store.bool(forKey: Takeover.kidsModeKey))
        #expect(Pin(store: secureStore).matches("4711"))

        // **Read back the way the TV side does it** — and that is exactly what the silent bug
        // hung on (AP22, 2026-09-11): the line used to check `store.object(…) as? Int`, that is,
        // the store that *this* file wrote to. It was green while the limit never arrived at the
        // TV. A check that only queries its own write direction checks nothing.
        #expect(AgeLimit.read(from: secureStore) == .from12)
    }

    /// **A number that does not exist as a level is discarded.**
    ///
    /// The bundle may be older than this device and therefore carries a raw `Int`. "From 14"
    /// exists in no rating; a guessed neighboring level would be a claim about something the
    /// sender never said.
    @Test("An unknown age tier does not arrive as a guessed limit")
    func unknownTierIsDiscarded() {
        let name = "probe.\(UUID().uuidString)"
        let secureStore = SecureStore(service: name)
        let takeover = Takeover(
            keychain: secureStore,
            listen: PlaylistStore(store: InMemoryStore(), secrets: InMemoryStore(), ledger: InMemoryStore()),
            trust: CertificateTrustStore(store: InMemoryStore()),
            store: UserDefaults(suiteName: name) ?? .standard)

        let phonePin = Pin(store: InMemoryStore())
        #expect(phonePin.set("4711"))

        takeover.matches(
            code: SetupBundle(
                parentalControls: .init(active: true, pin: phonePin.extract, ageLimit: 14)))

        #expect(AgeLimit.read(from: secureStore) == nil)
    }

    /// **A bundle does not lift an existing lock** — AP23, 2026-09-11.
    ///
    /// **Before this package this check was red, and the case is the most dangerous of the whole
    /// channel:** a bundle with `active: false` and without a PIN switched off the receiver's
    /// child mode. No sheet, no question, no message — the TV was open afterwards, and the
    /// report said "parental controls applied".
    ///
    /// **Tightening falls under it as well**, and that is deliberate: whoever may set the lock
    /// of a foreign device may also loosen it; the difference could not be checked here because
    /// the sender supplies the values.
    @Test("An existing PIN is not overwritten by a bundle")
    func bundleDoesNotLiftLock() {
        let name = "probe.\(UUID().uuidString)"
        let secureStore = SecureStore(service: name)
        let store = UserDefaults(suiteName: name) ?? .standard

        // This TV already has a responsible person.
        let own = Pin(store: secureStore)
        #expect(own.set("1234"))
        AgeLimit.write(.from6, in: secureStore)
        store.set(true, forKey: Takeover.kidsModeKey)

        let takeover = Takeover(
            keychain: secureStore,
            listen: PlaylistStore(store: InMemoryStore(), secrets: InMemoryStore(), ledger: InMemoryStore()),
            trust: CertificateTrustStore(store: InMemoryStore()), store: store)

        // A bundle that switches the lock off and brings no PIN.
        let report = takeover.matches(
            code: SetupBundle(
                parentalControls: .init(active: false, pin: nil, ageLimit: nil)))

        #expect(store.bool(forKey: Takeover.kidsModeKey), "The kids mode dropped")
        #expect(Pin(store: secureStore).matches("1234"), "The PIN was overwritten")
        #expect(AgeLimit.read(from: secureStore) == .from6, "The limit dropped")

        // **And it is in the report.** Silently discarding would be the next silent failure:
        // whoever sets a limit on the phone would otherwise believe it applies here.
        #expect(report.parentalControlsRejected)
        #expect(report.parentalControls == false)
    }

    /// **Without its own PIN it is applied** — the normal case the handoff exists for.
    ///
    /// The latch must not hit first setup: a fresh TV has nothing to protect, and that is
    /// exactly when a handoff runs.
    @Test("A fresh TV accepts the parental controls")
    func withoutOwnPINItIsApplied() {
        let name = "probe.\(UUID().uuidString)"
        let secureStore = SecureStore(service: name)
        let store = UserDefaults(suiteName: name) ?? .standard
        let takeover = Takeover(
            keychain: secureStore,
            listen: PlaylistStore(store: InMemoryStore(), secrets: InMemoryStore(), ledger: InMemoryStore()),
            trust: CertificateTrustStore(store: InMemoryStore()), store: store)

        let phonePin = Pin(store: InMemoryStore())
        #expect(phonePin.set("4711"))

        let report = takeover.matches(
            code: SetupBundle(
                parentalControls: .init(active: true, pin: phonePin.extract, ageLimit: 12)))

        #expect(report.parentalControls)
        #expect(report.parentalControlsRejected == false)
        #expect(AgeLimit.read(from: secureStore) == .from12)
    }

    @Test("What has no field is not applied either")
    func withoutFieldsNothingHappens() {
        let (takeover, _, listen, store) = setup()

        let report = takeover.matches(code: SetupBundle())

        // An empty bundle is no failure — it is a TV that was missing nothing.
        #expect(report == Takeover.Report())
        #expect(listen.playlists.isEmpty)
        #expect(store.string(forKey: Takeover.languageKey) == nil)
        #expect(!store.bool(forKey: Takeover.kidsModeKey))
    }

    // MARK: - The shelf order (AP40, 21.09.2026)

    /// **It was on the sheet as a commitment and arrived nowhere.**
    ///
    /// Two places were missing, and each looked harmless on its own: the phone read the order
    /// from `UserDefaults` when packing while it lay in the Keychain — so the bundle **never**
    /// carried one. And here nobody read it from the bundle. A field that arrives empty and is
    /// read nowhere goes unnoticed.
    @Test("The shelf order from the bundle orders the Home screen")
    func shelfOrderArrives() {
        let shelves = InMemoryStore()
        let (takeover, _, _, _) = setup(shelves: shelves)

        let report = takeover.matches(
            code: SetupBundle(shelfOrder: ["live", "resume", "portale"]))

        #expect(ShelfPreferences.load(from: shelves).order == ["live", "resume", "portale"])
        #expect(report.shelves == 3)
    }

    /// **Nothing is deleted** — the rule of this whole method, applied here. Whoever reordered
    /// their first device while setting up a second would lose something nobody had announced.
    @Test("An own order is not overwritten by a bundle")
    func ownOrderStays() {
        let shelves = InMemoryStore()
        ShelfPreferences(order: ["portale", "resume"]).save(to: shelves)
        let (takeover, _, _, _) = setup(shelves: shelves)

        let report = takeover.matches(
            code: SetupBundle(shelfOrder: ["live", "resume"]))

        #expect(ShelfPreferences.load(from: shelves).order == ["portale", "resume"])
        #expect(report.shelves == 0)
    }

    @Test("The report counts what has arrived")
    func reportCounts() {
        let (takeover, _, _, _) = setup()

        let report = takeover.matches(
            code: SetupBundle(
                channelLists: [
                    .init(identifier: "a", name: "A", address: URL(string: "http://a.example")!),
                    .init(identifier: "b", name: "B", address: URL(string: "http://b.example")!),
                ],
                omdbKey: "o", tmdbKey: "t", language: "de"))

        // "Transferred" does not answer the question of someone with two devices.
        #expect(report.channelLists == 2)
        #expect(report.key == 2)
        #expect(report.language == "de")
        #expect(report.jellyfin == nil)
    }

    /// The MyAnimeList client ID travels along like OMDb and TMDb (AP68) — otherwise, after
    /// setup via QR, the TV shows no rating for anime.
    @Test("The MAL client ID lands in the Keychain and counts as a key")
    func malArrives() {
        let (takeover, secureStore, _, _) = setup()
        let report = takeover.matches(code: SetupBundle(malKey: "mal-id"))
        #expect(secureStore.malClientID() == "mal-id")
        #expect(report.key == 1)
    }

    /// **The color scheme never arrived until 2026-09-26** (AP58), although the "What travels
    /// along" sheet promised it: the field traveled along, and nobody read it.
    @Test("The color pattern lands where the TV looks for it")
    func colorSchemeArrives() {
        let colors = InMemoryStore()
        let (takeover, _, _, _) = setup(shelves: colors)

        let report = takeover.matches(code: SetupBundle(colorPattern: Theme.midnight.id))

        #expect(ColorPattern.chosen(in: colors) == Theme.midnight.id)
        #expect(report.colorPattern == Theme.midnight.id)
    }

    /// An ID from a newer phone is no reason to reset a chosen design to the default.
    @Test("An unknown color pattern leaves the own one alone")
    func unknownColorSchemeIsLeftAlone() {
        let colors = InMemoryStore()
        let (takeover, _, _, _) = setup(shelves: colors)
        ColorPattern.select(Theme.contrast.id, in: colors)

        let report = takeover.matches(code: SetupBundle(colorPattern: "neon"))

        #expect(ColorPattern.chosen(in: colors) == Theme.contrast.id)
        #expect(report.colorPattern == nil)
    }
}
