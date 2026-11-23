import Core
import Flows
import Foundation
import Testing

@testable import FeaturesPhone

/// One shelf per portal — **the choice, its limits and the path through the store.**
///
/// **The requirement of 2026-09-07:** one shelf from each portal, provided that something is
/// selected for the others. Three sentences that stand against each other and are therefore each
/// checked: several choices, but at most three; one per portal, but none without a
/// choice; and all of that without losing the one choice that was already saved before.
@Suite("Portal shelves")
struct PortalShelvesTests {

    /// The ID form of the bridge, rebuilt: `portal|Suchbegriff|EntryPoint`
    /// (`PortalLibraryID`). The root is the same ID with an empty entry point — on that
    /// hangs the whole mapping "which choice belongs to which portal".
    private static func level(_ portal: String, _ entry: String = "") -> String {
        "\(portal)||\(entry)"
    }

    // MARK: - The store

    /// **The test suite on which the saved choice of the product owner hangs.**
    ///
    /// Before 2026-09-07 there was **one** ID under `home.portalFolder` as a string.
    /// If it had become unreadable with the rebuild, the automatic shelf would be there at
    /// the first start — and nobody would guess that the app had thrown away a setting.
    @Test("The old single value becomes a list with one entry")
    func oldSingleValue() throws {
        let keychain = InMemoryStore()
        let legacy = Self.level("serieshub", "beliebte-serien")
        try keychain.set(legacy, for: "home.portalFolder")
        let bucket = InMemoryStore()
        StartPreferences.adopt(from: keychain, in: bucket)

        let preferences = StartPreferences.load(from: bucket)
        #expect(preferences.portalFolders.count == 1)
        #expect(preferences.portalFolders.first?.identifier == legacy)
        // **The name is missing, and that is no error.** It only came with the choice per portal;
        // the shelf is then named after the portal alone.
        #expect(preferences.portalFolders.first?.name == "")
        #expect(preferences.selects(portalFolders: legacy))
    }

    /// And the old value also survives saving — otherwise it would be lost at the first
    /// toggle of any other switch.
    @Test("An entry without a name survives the trip through the store")
    func singleValueSurvivesBackup() throws {
        let keychain = InMemoryStore()
        let legacy = Self.level("animehub", "neue-folgen")
        try keychain.set(legacy, for: "home.portalFolder")
        let bucket = InMemoryStore()
        StartPreferences.adopt(from: keychain, in: bucket)

        var preferences = StartPreferences.load(from: bucket)
        preferences.set(liveChannel: ["Das Nordlicht HD"])
        preferences.save(to: bucket)

        #expect(StartPreferences.load(from: bucket).portalFolders == [.init(identifier: legacy)])
    }

    @Test("Identifier and name both come back")
    func storeWithNames() {
        let bucket = InMemoryStore()
        var preferences = StartPreferences.preset
        preferences.set(
            portalFolders: .init(
                identifier: Self.level("serieshub", "beliebt"), name: "Beliebte Serien"),
            under: Self.level("serieshub"), atMost: FromPortals.atMost)
        preferences.set(
            portalFolders: .init(identifier: Self.level("ahorn", "dokus"), name: "Dokus"),
            under: Self.level("ahorn"), atMost: FromPortals.atMost)
        preferences.save(to: bucket)

        let back = StartPreferences.load(from: bucket).portalFolders
        #expect(back.map(\.name) == ["Beliebte Serien", "Dokus"])
        #expect(back.first?.identifier == Self.level("serieshub", "beliebt"))
        // Nothing chosen means nothing remembered — no list with an empty entry.
        #expect(StartPreferences.load(from: InMemoryStore()).portalFolders.isEmpty)
    }

    // MARK: - One per portal

    /// **The core of the change.** Before, the choice was exclusive across all portals:
    /// Whoever took Animehub lost Serieshub.
    @Test("Two portals carry two choices side by side")
    func onePerPortal() {
        var preferences = StartPreferences.preset
        select(&preferences, "serieshub", "beliebt", "Beliebte Serien")
        select(&preferences, "animehub", "neu", "Neue Folgen")

        #expect(preferences.portalFolders.count == 2)
        #expect(preferences.selects(portalFolders: Self.level("serieshub", "beliebt")))
        #expect(preferences.selects(portalFolders: Self.level("animehub", "neu")))
    }

    /// Within one portal it stays at one — otherwise two Serieshub shelves would stand
    /// next to each other and a portal without a choice would get none.
    @Test("A second folder of the same portal replaces the first")
    func secondFolderReplaces() {
        var preferences = StartPreferences.preset
        select(&preferences, "serieshub", "beliebt", "Beliebte Serien")
        select(&preferences, "animehub", "neu", "Neue Folgen")
        select(&preferences, "serieshub", "alle", "Alle Serien")

        #expect(preferences.portalFolders.count == 2)
        #expect(!preferences.selects(portalFolders: Self.level("serieshub", "beliebt")))
        #expect(preferences.selects(portalFolders: Self.level("serieshub", "alle")))
        #expect(preferences.selects(portalFolders: Self.level("animehub", "neu")))
    }

    /// **Without a way back there would be no "automatic" any more** — one could only pin
    /// another folder.
    @Test("A second tap on the same folder undoes the choice")
    func secondPressUndoes() {
        var preferences = StartPreferences.preset
        select(&preferences, "serieshub", "beliebt", "Beliebte Serien")
        select(&preferences, "serieshub", "beliebt", "Beliebte Serien")
        #expect(preferences.portalFolders.isEmpty)
    }

    // MARK: - The cap

    /// **At most three, and the oldest yields** — the same rotation logic as with the
    /// channels. A fourth choice that gets no shelf would be a promise without fulfilment.
    @Test("The fourth choice displaces the first")
    func capAtThree() {
        var preferences = StartPreferences.preset
        for portal in ["serieshub", "animehub", "ahorn", "serieshubtwo"] {
            select(&preferences, portal, "neu", "Neue Folgen")
        }

        #expect(preferences.portalFolders.count == FromPortals.atMost)
        #expect(!preferences.selects(portalFolders: Self.level("serieshub", "neu")))
        #expect(preferences.selects(portalFolders: Self.level("serieshubtwo", "neu")))
    }

    /// The same limit one layer deeper: Even a store filled by hand
    /// with four entries does not yield four shelves.
    @Test("Four stored choices yield three shelves")
    func fourChoicesThreeShelves() {
        let catalogs = (1...4).map { slot in
            Catalog(
                id: .init(.portals, .portalLevel, "p\(slot)"), origin: .portals,
                label: .wording("Portal \(slot)"), kind: .portalLevel,
                sourceIdentifier: Self.level("p\(slot)", "neu"), extent: 5)
        }
        let shelves = ShelvesPerPortalFolder().shelves(forItem: CatalogState(catalogs))
        #expect(shelves.count == FromPortals.atMost)
    }

    /// **The collective catalog for the tab bar is not a chosen folder.** Without this
    /// distinction a second, empty shelf would appear next to "From the portals" —
    /// every time a bridge is entered.
    @Test("Without a source identifier no portal shelf arises")
    func combinedCatalogWithoutShelf() {
        let shelves = ShelvesPerPortalFolder().shelves(
            forItem: .fromAccesses(portals: true))
        #expect(shelves.isEmpty)
    }

    // MARK: - What the Home screen makes of it

    /// **Without a choice it stays at today's behavior** — one shelf, filled automatically.
    /// On a freshly set up device nobody has been able to choose anything yet; without
    /// this branch nothing from the portals would stand there.
    @Test("Without a choice the one automatic shelf arises")
    func withoutChoiceOneShelf() async throws {
        let content = try await Self.home(preferences: .preset)
        #expect(content.tiles.keys.map(\.rawValue) == ["portale"])
        #expect(content.tiles[.fixed("portale")]?.count == 2)
    }

    /// Two choices, two shelves — **and both are named after portal and folder.** "Popular
    /// Series" exists at two of the three portals; without the name in front, two identically
    /// labeled shelves would stand one below the other.
    @Test("One shelf per chosen folder, named after portal and folder")
    func oneShelfPerChoice() async throws {
        var preferences = StartPreferences.preset
        select(&preferences, "serieshub", "beliebt", "Beliebte Serien")
        select(&preferences, "animehub", "beliebt", "Beliebte Serien")

        let content = try await Self.home(preferences: preferences)
        let shelves = ShelfPlan.shelves(forItem: content.state).filter { content.tiles[$0.id] != nil }
        #expect(
            shelves.map(\.label.raw) == [
                "Serieshub · Beliebte Serien", "Animehub · Beliebte Serien",
            ])
        // **The fixed shelf stays empty and thereby disappears** — it is in the plan, but
        // nobody fills it as long as a choice is made.
        #expect(content.tiles[.fixed("portale")] == nil)
    }

    /// **The product owner's condition**, in one sentence: provided that something is selected
    /// for the others. The Ahorn is ready and still has no shelf.
    @Test("A portal without a choice gets no shelf of its own")
    func withoutChoiceNoShelf() async throws {
        var preferences = StartPreferences.preset
        select(&preferences, "serieshub", "beliebt", "Beliebte Serien")

        let content = try await Self.home(preferences: preferences)
        #expect(content.state.catalogs.count == 1)
        #expect(content.state.catalogs.first?.sourceIdentifier == Self.level("serieshub", "beliebt"))
    }

    /// **A choice that does not answer today does not take the shelf with it.** Anyone who
    /// chose a portal whose sign-in has expired does not get an empty Home screen,
    /// but the automatic shelf — the same rule that applied to the one
    /// choice before 2026-09-07.
    @Test("A choice on a portal that is not ready falls back to the automatic shelf")
    func choiceOnMutePortal() async throws {
        var preferences = StartPreferences.preset
        select(&preferences, "serieshubtwo", "beliebt", "Beliebte Serien")

        let content = try await Self.home(preferences: preferences)
        #expect(content.tiles[.fixed("portale")]?.isEmpty == false)
    }

    /// **If the chosen level leads to categories again, it descends from there.** The
    /// case of Serieshub: Behind "Popular Series" there is a menu, and unchecked,
    /// category names would stand as titles in the shelf.
    @Test("Behind a chosen menu the descent continues down to the titles")
    func selectedMenu() async throws {
        var preferences = StartPreferences.preset
        select(&preferences, "serieshub", "menue", "Entdecken")

        let content = try await Self.home(preferences: preferences)
        let tiles = content.tiles.values.first ?? []
        #expect(tiles.map(\.title) == ["Deep 1", "Deep 2"])
    }

    // MARK: - Ordnen und Ausblenden

    /// **A portal shelf inherits the place of "From the portals".**
    ///
    /// Anyone who has dragged the portal shelf up once has said that about **the portals**. Without the inheritance the chosen folders would, by the rule "what the
    /// order does not know falls to the back", land below all library shelves.
    @Test("Portal shelves sit where \"From the portals\" sits")
    func portalShelvesInheritThePosition() {
        let portalShelves = Self.samplePortalShelves
        let shelves =
            [Shelf(id: .fixed("zuletztHinzugefuegt"), label: .key("x"), sources: [])]
            + portalShelves
            + [Shelf(id: .fixed("resume"), label: .key("y"), sources: [])]
        var preferences = StartPreferences.preset
        preferences.set(order: [
            StartPreferences.immovable, .fixed("portale"), .fixed("zuletztHinzugefuegt"),
        ])

        let ordered = preferences.arrange(shelves).map(\.id)
        #expect(ordered.first == StartPreferences.immovable)
        #expect(Array(ordered.dropFirst(1).prefix(2)) == portalShelves.map(\.id))
        #expect(ordered.last == .fixed("zuletztHinzugefuegt"))
    }

    /// **And among themselves they stay in the order of the choice.** Both inherit the same
    /// rank; without the second key they would stand differently at every start, because
    /// `sorted` is not stable.
    @Test("Two portal shelves of the same rank keep their sequence")
    func portalShelvesStayInSequence() {
        var preferences = StartPreferences.preset
        preferences.set(order: [.fixed("portale")])
        let ordered = preferences.arrange(Self.samplePortalShelves).map(\.label.raw)
        #expect(ordered == ["Serieshub · Beliebte Serien", "Animehub · Neue Folgen"])
    }

    /// **Anyone who has switched off "From the portals" wants no portal shelves.** Otherwise the
    /// switched-off shelf would come back by itself under a new name at the first choice.
    @Test("A hidden portal shelf stays hidden")
    func hidingAppliesToAll() {
        var preferences = StartPreferences.preset
        preferences.show(.fixed("portale"), false)
        #expect(preferences.arrange(Self.samplePortalShelves).isEmpty)

        // And the opposite direction: The switch on a portal shelf toggles the same row.
        preferences.show(Self.samplePortalShelves[0].id, true)
        #expect(preferences.arrange(Self.samplePortalShelves).count == 2)
    }

    private static let samplePortalShelves: [Shelf] = [
        Shelf(
            id: .zu(.init(.portals, .portalLevel, level("serieshub", "beliebt"))),
            label: .wording("Serieshub · Beliebte Serien"), sources: [.portals]),
        Shelf(
            id: .zu(.init(.portals, .portalLevel, level("animehub", "neu"))),
            label: .wording("Animehub · Neue Folgen"), sources: [.portals]),
    ]

    // MARK: - Handreichungen

    private func select(
        _ preferences: inout StartPreferences, _ portal: String, _ entry: String, _ name: String
    ) {
        preferences.set(
            portalFolders: .init(identifier: Self.level(portal, entry), name: name),
            under: Self.level(portal), atMost: FromPortals.atMost)
    }

    private static func home(preferences: StartPreferences) async throws -> StartContent {
        let source = FromPortals(
            source: SampleBridge(), memory: PortalMemory(store: freshStore()),
            preferences: { preferences })
        return try await source.home(perShelf: 20)
    }

    private static func freshStore() -> UserDefaults {
        UserDefaults(suiteName: "probe.\(UUID().uuidString)") ?? .standard
    }
}

/// Three portals as measured at the bridge (2026-09-07) — **two ready, one not.**
///
/// The names and the structure are the real ones: Serieshub and Animehub both carry
/// "Popular Series", and behind "Discover" there is again a menu at Serieshub. The
/// IDs are invented, but carry the bridge's form — on it hangs the mapping
/// "which choice belongs to which portal".
private struct SampleBridge: PortalContentSource {

    func portals() async throws -> [PortalInfo] {
        [
            PortalInfo(
                id: "serieshub", name: "Serieshub", state: .ready, capabilities: []),
            PortalInfo(id: "animehub", name: "Animehub", state: .ready, capabilities: []),
            PortalInfo(id: "ahorn", name: "Ahorn Mediathek", state: .ready, capabilities: []),
            PortalInfo(
                id: "serieshubtwo", name: "Serieshubtwo",
                state: PortalState("Anmeldung nötig", reason: "anmeldung"), capabilities: []),
        ]
    }

    func root(zu portal: String) -> String { "\(portal)||" }

    func level(zu identifier: String, title: String, next: String?) async throws -> PortalLayer {
        PortalLayer(identifier: identifier, title: title, entries: Self.tree[identifier] ?? [])
    }

    func languages(zu identifier: String) async throws -> [String] { [] }
    func select(language: String, forItem identifier: String) async throws {}
    func host(zu identifier: String) async throws -> [PortalHost] { [] }

    private static func door(_ identifier: String, _ title: String) -> PortalEntry {
        PortalEntry(id: identifier, title: title, leadsDeeper: identifier)
    }

    private static func title(_ name: String) -> PortalEntry {
        PortalEntry(id: name, title: name)
    }

    private static let tree: [String: [PortalEntry]] = [
        "serieshub||": [
            door("serieshub||beliebt", "Beliebte Serien"),
            door("serieshub||menue", "Entdecken"),
        ],
        "serieshub||beliebt": [title("Fernnebel"), title("Haus der Zinnfiguren")],
        "serieshub||menue": [door("serieshub||tief", "Meistgesehen gerade")],
        "serieshub||tief": [title("Deep 1"), title("Deep 2")],
        "animehub||": [door("animehub||beliebt", "Beliebte Serien")],
        "animehub||beliebt": [title("Elvaran"), title("Salt Compass")],
        "ahorn||": [door("ahorn||dokus", "Dokus")],
        "ahorn||dokus": [title("Doku 1")],
    ]
}
