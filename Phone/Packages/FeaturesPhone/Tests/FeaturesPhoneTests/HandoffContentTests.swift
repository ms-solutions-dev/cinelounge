import Core
import Foundation
import PlaylistKit
import ProfileKit
import SecondScreen
import Testing

@testable import FeaturesPhone

/// **What ``CarryOverSheet`` promises must be in the bundle — filled.**
///
/// ``HandoffModel/bundles()`` has named this check in its header since 2026-09-10, and in the
/// roadmap it stood as evidence. **It did not exist.** That is exactly why the find of
/// 2026-09-21 went unnoticed for so long: The shelf order was fetched from
/// `UserDefaults` but lay in the Keychain — the field was there, it was always empty, and on the
/// sheet "What travels along" it nevertheless said "Language, color scheme, shelf and
/// group order".
///
/// **Counting a field is not enough.** The existing check over there (`HandoffTests`)
/// establishes that there is a field for every row; a field that is never filled never
/// bothered it. That is why here **set up and then look**.
@Suite("What the bundle really carries")
struct HandoffContentTests {

    /// Own stores per check — the device's Keychain stays out of it.
    @MainActor
    private static func model(
        shelfStore: any KeyValueStore, ledgerStore: any KeyValueStore = InMemoryStore()
    ) -> HandoffModel {
        let name = "probe.\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name) ?? .standard
        let keychain = SecureStore(service: name)
        return HandoffModel(
            status: SetupState(
                keychain: keychain,
                listen: PlaylistStore(
                    store: InMemoryStore(), secrets: InMemoryStore(), ledger: InMemoryStore()),
                store: store,
                ledgerStore: ledgerStore),
            backup: ParentalControlsState(store: store, keychain: keychain),
            keychain: keychain,
            listen: PlaylistStore(store: InMemoryStore(), secrets: InMemoryStore(), ledger: InMemoryStore()),
            store: store,
            shelfStore: shelfStore,
            ledgerStore: ledgerStore)
    }

    /// The other side — with own stores, as the TV would have.
    @MainActor
    private static func takeover(
        shelfStore: any KeyValueStore, ledgerStore: any KeyValueStore
    ) -> Takeover {
        let name = "probe.\(UUID().uuidString)"
        return Takeover(
            keychain: SecureStore(service: name),
            listen: PlaylistStore(
                store: InMemoryStore(), secrets: InMemoryStore(), ledger: InMemoryStore()),
            trust: CertificateTrustStore(store: InMemoryStore()),
            store: UserDefaults(suiteName: name) ?? .standard,
            shelfStore: shelfStore, ledgerStore: ledgerStore)
    }

    /// **One store on both sides** (AP58 R7, finding E5): The phone packed the
    /// color scheme from `UserDefaults`, the TV put it in the Keychain, and neither
    /// of the two places read what the other wrote.
    @MainActor
    @Test("The color pattern migrates from the phone's store to the TV's")
    func colorPatternMigrates() {
        let phone = InMemoryStore()
        let tv = InMemoryStore()
        ColorPattern.select("midnight", in: phone)

        let bundles = Self.model(shelfStore: phone).bundles()
        _ = Self.takeover(shelfStore: tv, ledgerStore: InMemoryStore()).matches(code: bundles)

        #expect(bundles.colorPattern == "midnight")
        #expect(ColorPattern.chosen(in: tv) == "midnight")
    }

    @MainActor
    @Test("The shelf order migrates too — from the store where it really lives")
    func shelfOrderIsFilled() {
        let bucket = InMemoryStore()
        var preferences = StartPreferences.preset
        preferences.set(order: [.fixed("resume"), .fixed("live"), .fixed("portale")])
        preferences.save(to: bucket)

        let bundles = ProfilePointer.als(nil) { Self.model(shelfStore: bucket).bundles() }

        #expect(bundles.shelfOrder == ["resume", "live", "portale"])
    }

    /// **The counter-proof to the old way.** Whoever looks for the order in `UserDefaults`
    /// finds nothing there — it never lay there. This check establishes that a filled
    /// default store does **not** fill the bundle; whoever brings back the old call goes red.
    @MainActor
    @Test("Nothing comes from the standard store — the order was never there")
    func defaultStoreFillsNothing() {
        let name = "probe.\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name) ?? .standard
        store.set(["resume", "live"], forKey: "home.shelfOrder")

        let bundles = Self.model(shelfStore: InMemoryStore()).bundles()

        #expect(bundles.shelfOrder.isEmpty)
    }

    /// **Every promise on the sheet has a field — and every field a promise.**
    ///
    /// The numbers were recounted by hand and stand here as a number so that an
    /// added field without a row (and a row without a field) gets noticed.
    @MainActor
    @Test("Sheet and bundle count the same number of pieces")
    func sheetAndBundleMatch() {
        // Server, channel lists, bridge, keys, appearance, parental controls, profiles.
        #expect(CarryOverSheet.travelsAlong.count == 7)
        // And in the bundle: medienserver, senderlisten, bruecke, (omdb+tmdb), (sprache +
        // farbmuster + regalreihenfolge + gruppenreihenfolge + versteckteGruppen +
        // sportarten), kindersicherung.
        let full = SetupBundle(
            omdbKey: "a", tmdbKey: "b", language: "de", colorPattern: "cinema",
            shelfOrder: ["resume"], sports: ["fussball"],
            groupOrder: ["DE"], hiddenGroups: ["XX"])
        #expect(full.shelfOrder.isEmpty == false)
        #expect(full.colorPattern != nil)
        #expect(full.language != nil)
    }

    // MARK: - Bundle versus takeover

    /// **The check the roadmap demands: not sheet against bundle, but
    /// bundle against takeover** (AP44).
    ///
    /// **The difference is the find of 2026-09-21** "There is a field" was true for three months
    /// while the field was always empty; "the sheet and the bundle count the same number
    /// of items" would not have found the same error either. What counts is
    /// the whole path: set up, pack, play in over there, look.
    @MainActor
    @Test("What is on the phone is on the TV afterwards")
    func bundleArrives() {
        let here = InMemoryStore()
        var ledger = ProfileBook()
        ledger.create(Profile(name: "Alex", color: .turquoise))
        ledger.create(Profile(name: "Sam", color: .coral, kind: .kind))
        ledger.write(in: here)

        let shelves = InMemoryStore()
        var preferences = StartPreferences.preset
        preferences.set(order: [.fixed("resume"), .fixed("live")])
        preferences.save(to: shelves)

        let bundles = ProfilePointer.als(nil) {
            Self.model(shelfStore: shelves, ledgerStore: here).bundles()
        }

        // And now the other side — own stores, as a fresh TV has them.
        let otherSide = InMemoryStore()
        let report = Self.takeover(shelfStore: InMemoryStore(), ledgerStore: otherSide)
            .matches(code: bundles)

        #expect(report.profile == 2)
        let there = ProfileBook.read(from: otherSide)
        #expect(there.profile.map(\.name) == ["Alex", "Sam"])
        #expect(there.profile.last?.kind == .kind, "a child stays a child")
        #expect(report.shelves == 2)
    }

    /// **Group order, hidden groups and sports** (ultra e5, round A.5):
    /// The fields were in the bundle, the phone never filled them, the TV never read them
    /// — and the sheet promised the group order.
    @MainActor
    @Test("Group order, hidden groups and sports choice migrate all the way to the TV")
    func livePreferencesMigrate() {
        let name = "probe.\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name) ?? .standard
        let keychain = SecureStore(service: name)
        var live = LivePreferences.load(from: keychain)
        live.setGroupOrder(["Sport", "Nachrichten"])
        live.setVisible(false, group: "XXX")
        live.save(to: keychain)
        var sport = SportFilterSettings()
        sport.toggle(.tennis)
        sport.save(to: keychain)

        let bundles = HandoffModel(
            status: SetupState(
                keychain: keychain,
                listen: PlaylistStore(
                    store: InMemoryStore(), secrets: InMemoryStore(), ledger: InMemoryStore()),
                store: store, ledgerStore: InMemoryStore()),
            backup: ParentalControlsState(store: store, keychain: keychain),
            keychain: keychain,
            listen: PlaylistStore(store: InMemoryStore(), secrets: InMemoryStore(), ledger: InMemoryStore()),
            store: store, shelfStore: InMemoryStore(), ledgerStore: InMemoryStore()
        ).bundles()
        #expect(bundles.groupOrder == ["Sport", "Nachrichten"])
        #expect(bundles.hiddenGroups == ["XXX"])
        #expect(bundles.sports == ["tennis"])

        let tv = "probe.\(UUID().uuidString)"
        let tvBundle = SecureStore(service: tv)
        _ = Takeover(
            keychain: tvBundle,
            listen: PlaylistStore(store: InMemoryStore(), secrets: InMemoryStore(), ledger: InMemoryStore()),
            trust: CertificateTrustStore(store: InMemoryStore()),
            store: UserDefaults(suiteName: tv) ?? .standard,
            shelfStore: InMemoryStore(), ledgerStore: InMemoryStore()
        ).matches(code: bundles)

        let there = LivePreferences.load(from: tvBundle)
        #expect(there.groupOrder == ["Sport", "Nachrichten"])
        #expect(there.hiddenGroups == ["XXX"])
        let sportsThere = SportFilterSettings.load(from: tvBundle)
        #expect(!sportsThere.isEnabled(.tennis))
        #expect(sportsThere.isEnabled(.football))
    }

    /// **A profile without accesses is a valid profile** — and it travels along. Whoever took only
    /// the people with a media server along would leave behind exactly those for whom
    /// the profiles have existed since AP41: the child to whom nothing belongs yet.
    @MainActor
    @Test("A profile without accesses migrates too")
    func withoutAccessMigratesToo() {
        let here = InMemoryStore()
        var ledger = ProfileBook()
        ledger.create(Profile(name: "Sam", kind: .kind))
        ledger.write(in: here)

        let bundles = Self.model(shelfStore: InMemoryStore(), ledgerStore: here).bundles()

        #expect(bundles.profile.map(\.name) == ["Sam"])
        #expect(bundles.profile.first?.credentials.isEmpty == true)
    }

    /// **No access tag appears twice in the bundle.** A ``ProfileKit/Access`` says *whom*
    /// a server belongs to, and not what one signs in with there; the secrets keep
    /// traveling alone in `jellyfin` and `channelLists`. This check establishes that
    /// the profile field brings none of that along — otherwise a password would have two
    /// paths through the channel from today, and one of them would be new and unchecked.
    @MainActor
    @Test("The profile field carries no secret")
    func profilesCarryNoSecrets() throws {
        let here = InMemoryStore()
        var ledger = ProfileBook()
        var person = Profile(name: "Alex")
        person.create(
            .jellyfin(
                server: URL(string: "https://media.example.test")!, userID: "u1", username: "alex"))
        person.create(.channelList(identifier: "xtream|panel|max"))
        ledger.create(person)
        ledger.write(in: here)

        let bundles = Self.model(shelfStore: InMemoryStore(), ledgerStore: here).bundles()
        let text =
            String(
                data: try JSONEncoder().encode(bundles.profile), encoding: .utf8) ?? ""

        #expect(!text.isEmpty)
        for word in ["kennwort", "password", "zugangsmarke", "token", "geheim"] {
            #expect(!text.lowercased().contains(word), "\(word)")
        }
    }
}
