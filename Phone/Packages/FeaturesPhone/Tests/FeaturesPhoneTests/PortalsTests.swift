import Core
import Flows
import Foundation
import SwiftUI
import Testing

@testable import FeaturesPhone

/// Portals: the state is a property, not an error message.
@Suite("Portals")
struct PortalsTests {

    private static func portal(
        _ id: String, name: String? = nil, state: PortalState = .ready,
        capabilities: Set<String> = ["blaettern", "suche"]
    ) -> PortalInfo {
        PortalInfo(
            id: id, name: name ?? id, state: state, capabilities: capabilities)
    }

    // MARK: - Zustand

    /// **The string belongs to the bridge.** An unknown state must not be reported as
    /// an outage — the bridge should be allowed to gain one.
    @Test("An unknown state with a reason is passed through, not swallowed")
    func unknownState() {
        let state = PortalState("wartungsmodus", reason: "Wartung bis 6 Uhr")
        #expect(state.wording == "Wartung bis 6 Uhr")
        #expect(!state.isReady)
    }

    @Test("An unknown state without a reason is silent")
    func unknownWithoutReason() {
        #expect(PortalState("wartungsmodus") == .muted)
    }

    /// Sign-in and a missing setting **can** be opened — the task is then
    /// there. Only a silent portal leads nowhere.
    @Test("Only a silent portal is unselectable")
    func selectability() {
        #expect(PortalState.ready.isSelectable)
        #expect(PortalState.login.isSelectable)
        #expect(PortalState.needsSetting.isSelectable)
        #expect(!PortalState.muted.isSelectable)
    }

    /// Never color alone: every state carries a symbol.
    @Test("Every state has an icon")
    func everyStateHasASymbol() {
        let all: [PortalState] = [
            .ready, .login, .needsSetting, .muted, .other("x"),
        ]
        for state in all { #expect(!state.icon.isEmpty) }
    }

    // MARK: - Capabilities

    /// **The difference that counts while waiting.** A portal with a resolver looks for the
    /// video source only when you press.
    @Test("Without a resolver a portal plays immediately")
    func playsImmediately() {
        #expect(Self.portal("ahorn").playsImmediately)
        #expect(!Self.portal("animehub", capabilities: ["aufloeser"]).playsImmediately)
    }

    /// From the name and not from a table: Whoever forgets the table at the next portal
    /// gets an empty badge.
    @Test("The badge is derived from the name")
    func abbreviation() {
        #expect(Self.portal("ahorn", name: "Ahorn Mediathek").abbreviation == "AM")
        #expect(Self.portal("animehub", name: "Animehub").abbreviation == "AN")
    }

    // MARK: - Choice and memory

    /// The same rule as for the library catalog: Whoever watches anime watches anime.
    @Test("The most recently used portal is opened again")
    @MainActor
    func rememberedPortal() async {
        let memory = PortalMemory(store: Self.freshStore())
        memory.memorize("animehub")
        let model = PortalsModel(
            source: SamplePortals(portals: [Self.portal("ahorn"), Self.portal("animehub")]),
            memory: memory)

        await model.load()
        #expect(model.chosen?.id == "animehub")
    }

    /// If the remembered portal has gone silent, the choice takes the first usable one —
    /// instead of landing on a screen that can do nothing.
    @Test("A portal that has gone silent is skipped")
    @MainActor
    func muteIsSkipped() async {
        let memory = PortalMemory(store: Self.freshStore())
        memory.memorize("tot")
        let model = PortalsModel(
            source: SamplePortals(portals: [
                Self.portal("tot", state: .muted), Self.portal("ahorn"),
            ]),
            memory: memory)

        await model.load()
        #expect(model.chosen?.id == "ahorn")
    }

    /// **The fallback is not a choice** — added on 2026-09-09 when re-checking
    /// task 3. Until then every call of ``PortalsModel/select(_:)`` remembered the
    /// portal, also the one that ``PortalsModel/load()`` itself triggered when the remembered
    /// one was silent. Anyone who uses Animehub and finds it silent for one evening got
    /// the Ahorn assigned **permanently**. The same rule has stood at
    /// ``LibraryViewModel/select(_:)`` since the morning.
    @Test("A fallback to another portal does not overwrite the choice")
    @MainActor
    func fallbackDoesNotOverwriteChoice() async {
        let store = Self.freshStore()
        let memory = PortalMemory(store: store)
        memory.memorize("aw")

        let model = PortalsModel(
            source: SamplePortals(
                portals: [Self.portal("aw", state: .muted), Self.portal("ahorn")],
                tree: ["ahorn::": [Self.folder("a", "A")]]),
            memory: memory)
        await model.load()
        #expect(model.chosen?.id == "ahorn", "a silent portal does not work today")
        #expect(
            memory.last == "aw",
            "but tomorrow it does again — the fallback must not overwrite the choice")
    }

    /// **A portal that requires a sign-in does not disappear.** Otherwise the
    /// viewer does not see that it is there and cannot sign in.
    @Test("A locked portal is selectable and shows its state")
    @MainActor
    func lockedStays() async {
        let model = PortalsModel(
            source: SamplePortals(portals: [Self.portal("ss", state: .login)]),
            memory: PortalMemory(store: Self.freshStore()))

        await model.load()
        #expect(model.chosen?.id == "ss")
        #expect(model.state == .locked(.login))
    }

    @Test("Without a bridge the portals state is shown, not an empty list")
    @MainActor
    func withoutBridge() async {
        let model = PortalsModel(source: nil)
        await model.load()
        #expect(model.state == .disrupted(.networkPortals))
    }

    // MARK: - Kennungen

    /// Decided by the ID and not by trial and error.
    @Test("A portal identifier is recognized as such")
    func identifierIsRecognized() {
        let identifier = "animehub|elvaran|https://animehub.example/anime/elvaran"
        #expect(AggregateDetailSource.fromPortal(identifier))
        #expect(!AggregateDetailSource.fromPortal("f00dfeedf00dfeedf00dfeedf00dfeed"))
    }

    // MARK: - Sprachfassungen

    /// Only what is unambiguous is shortened — everything else stands as it came.
    @Test("The language tag abbreviates only what is unambiguous")
    func languageTags() {
        #expect(LanguageVersions.tag("Deutsch") == "DE")
        #expect(LanguageVersions.tag("Japanisch mit Untertiteln") == "OmU")
        #expect(LanguageVersions.tag("German Sub") == "OmU")
        #expect(LanguageVersions.tag("Untertitel Deutsch") == "OmU")
        #expect(LanguageVersions.tag("Kantonesisch") == "Kantonesisch")
    }

    // MARK: - Der Ebenenstapel

    private static func folder(_ id: String, _ title: String) -> PortalEntry {
        PortalEntry(id: id, title: title, leadsDeeper: "ebene:\(id)")
    }

    private static func titleEntry(_ id: String, _ title: String) -> PortalEntry {
        PortalEntry(
            id: id, title: title, image: URL(string: "http://p" + ".beispiel/\(id).jpg"))
    }

    /// **The shape decides the level, not the tile.**
    ///
    /// And it decides in this direction: A grid is shown **as soon as there is anything
    /// to show** — rows remain only where a level consists exclusively of folders and
    /// separators. The reverse rule was already wrong once in the TV version:
    /// One folder among twenty-five posters turned the grid into a list.
    @Test("A level is rows or posters — and mixed means posters")
    func shapePerLevel() {
        let foldersOnly = PortalLayer(
            identifier: "a", title: "Beliebte Serien",
            entries: [Self.folder("1", "Action"), Self.folder("2", "Drama")])
        #expect(foldersOnly.areFolders)

        // **The case that neither rule solves:** four separators and twenty series.
        let mixed = PortalLayer(
            identifier: "b", title: "Entdecken",
            entries: [
                PortalEntry(id: "t", title: "— Geheimtipps —", isSeparator: true),
                Self.titleEntry("s1", "Elvaran"),
            ])
        #expect(!mixed.areFolders, "as soon as there is something to show, a grid")
        #expect(mixed.tiles.count == 1, "the separator is not a tile")

        // A level of folders **and** separators stays a list.
        let folderWithSeparator = PortalLayer(
            identifier: "c", title: "Genres",
            entries: [
                PortalEntry(id: "t", title: "— A bis M —", isSeparator: true),
                Self.folder("1", "Action"),
            ])
        #expect(folderWithSeparator.areFolders)

        #expect(!PortalLayer(identifier: "d", title: "leer", entries: []).areFolders)
    }

    /// **The root is a level like any other** — and there is no way back from it.
    @Test("The stack grows on open and shrinks on back")
    @MainActor
    func levelStack() async {
        let model = PortalsModel(
            source: SamplePortals(
                portals: [Self.portal("ss", name: "Serieshub")],
                tree: [
                    "ss::": [Self.folder("beliebt", "Beliebte Serien")],
                    "ebene:beliebt": [Self.titleEntry("elvaran", "Elvaran")],
                ]),
            memory: PortalMemory(store: Self.freshStore()))

        await model.load()
        #expect(model.stack.count == 1)
        #expect(model.pending?.title == "Serieshub")
        #expect(!model.hasWayBack, "on the root an arrow leads nowhere")
        #expect(model.pending?.areFolders == true)

        let door = try? #require(model.pending?.entries.first)
        await model.open(try! #require(door))
        #expect(model.stack.count == 2)
        #expect(model.hasWayBack)
        #expect(model.path == "Serieshub › Beliebte Serien")
        #expect(model.pending?.areFolders == false, "titles with a picture are a grid")

        model.back()
        #expect(model.stack.count == 1)
        #expect(!model.hasWayBack)

        // **On the root Back does nothing** — otherwise one would face an empty stack.
        model.back()
        #expect(model.stack.count == 1)
    }

    /// A title does not lead deeper — it leads to its detail page.
    @Test("An entry without a door opens no level")
    @MainActor
    func titleOpensNoLevel() async {
        let model = PortalsModel(
            source: SamplePortals(
                portals: [Self.portal("ss")],
                tree: ["ss::": [Self.titleEntry("elvaran", "Elvaran")]]),
            memory: PortalMemory(store: Self.freshStore()))

        await model.load()
        await model.open(Self.titleEntry("elvaran", "Elvaran"))
        #expect(model.stack.count == 1)
    }

    // MARK: - The stack survives a second load

    /// **The finding of 2026-09-09, nailed down:** when an item is selected in flatone,
    /// a detail view opens; going back from there jumps out completely
    /// instead of going back just 1.
    ///
    /// The back arrow was innocent. `PortalsView` attaches ``PortalsModel/load()`` to
    /// `.task`, and `.task` runs **again** in the `NavigationStack` on coming back —
    /// `load()` chose the same portal a second time, and `select` threw away the whole
    /// level stack in doing so. The same line hit the tab switch.
    @Test("A second load leaves the level stack in place")
    @MainActor
    func secondLoadLeavesStackInPlace() async {
        let model = PortalsModel(
            source: SamplePortals(
                portals: [Self.portal("ss", name: "Serieshub")],
                tree: [
                    "ss::": [Self.folder("beliebt", "Beliebte Serien")],
                    "ebene:beliebt": [Self.folder("action", "Action")],
                    "ebene:action": [Self.titleEntry("elvaran", "Elvaran")],
                ]),
            memory: PortalMemory(store: Self.freshStore()))

        await model.load()
        await model.open(try! #require(model.pending?.entries.first))
        await model.open(try! #require(model.pending?.entries.first))
        #expect(model.stack.count == 3)

        // That is the re-entry from the detail page — and the tab switch as well.
        await model.load()
        #expect(
            model.stack.count == 3,
            "a second lade() must not clear the path one is standing on")
        #expect(model.path == "Serieshub › Beliebte Serien › Action")
    }

    /// **Choosing the same portal again is not a switch.** The sheet too must not clear the
    /// path when someone taps the portal they are already in.
    @Test("Selecting the same portal again clears nothing")
    @MainActor
    func samePortalDoesNotCleanUp() async {
        let model = PortalsModel(
            source: SamplePortals(
                portals: [Self.portal("ss", name: "Serieshub")],
                tree: [
                    "ss::": [Self.folder("beliebt", "Beliebte Serien")],
                    "ebene:beliebt": [Self.titleEntry("elvaran", "Elvaran")],
                ]),
            memory: PortalMemory(store: Self.freshStore()))

        await model.load()
        await model.open(try! #require(model.pending?.entries.first))
        #expect(model.stack.count == 2)

        await model.select(Self.portal("ss", name: "Serieshub"))
        #expect(model.stack.count == 2)
    }

    /// **A real switch does clear** — one portal's tree does not lead into
    /// another's.
    @Test("Another portal resets the path to its root")
    @MainActor
    func realSwitchCleansUp() async {
        let model = PortalsModel(
            source: SamplePortals(
                portals: [Self.portal("ss", name: "Serieshub"), Self.portal("aw")],
                tree: [
                    "ss::": [Self.folder("beliebt", "Beliebte Serien")],
                    "ebene:beliebt": [Self.titleEntry("elvaran", "Elvaran")],
                    "aw::": [Self.folder("neu", "Neue Folgen")],
                ]),
            memory: PortalMemory(store: Self.freshStore()))

        await model.load()
        await model.open(try! #require(model.pending?.entries.first))
        #expect(model.stack.count == 2)

        await model.select(Self.portal("aw"))
        #expect(model.stack.count == 1)
        #expect(model.pending?.title == "aw")
    }

    /// **And the fallback rule stays.** If the open portal goes silent, the choice still falls in the
    /// **second** run to another one — otherwise the new rule "a choice
    /// that holds is not replaced" would hold the viewer on a screen that can do nothing
    /// any more.
    @Test("A portal that has gone silent is replaced on reload")
    @MainActor
    func turnedMuteIsReplaced() async {
        let model = PortalsModel(
            source: SwitchingPortals(
                runs: [
                    [Self.portal("ss"), Self.portal("aw")],
                    [Self.portal("ss", state: .muted), Self.portal("aw")],
                ],
                tree: ["ss::": [Self.folder("beliebt", "Beliebt")], "aw::": []]),
            memory: PortalMemory(store: Self.freshStore()))

        await model.load()
        #expect(model.chosen?.id == "ss")

        await model.load()
        #expect(model.chosen?.id == "aw", "a silent portal no longer holds the choice")
    }

    /// A portal that disappears from the list does not hold on to the choice.
    @Test("A choice that no longer exists falls back to another portal")
    @MainActor
    func vanishedPortal() async {
        let model = PortalsModel(
            source: SwitchingPortals(
                runs: [[Self.portal("weg")], [Self.portal("da")]],
                tree: ["weg::": [], "da::": []]),
            memory: PortalMemory(store: Self.freshStore()))

        await model.load()
        #expect(model.chosen?.id == "weg")

        await model.load()
        #expect(model.chosen?.id == "da")
    }

    // MARK: - Die gemerkte Rollstelle

    /// **Finding of 2026-09-09:** going into clips and then going back
    /// always jumps to the top. The position is remembered per level, not per
    /// view — the view is torn down on descending, after all.
    ///
    /// **This check was already green in the morning and still showed nothing.** It
    /// put a `ScrollPosition(id:)` in the compartment — that is, the one case the
    /// view **never** produced: For an unknown level it passed in a bare
    /// `ScrollPosition()`, and that, per the SDK (`init(idType: Never.self)`),
    /// never carries an ID. Since the position is a string, the check can only
    /// store what the view also stores.
    @Test("A level's scroll position survives the way down and back")
    @MainActor
    func scrollPositionSurvives() async {
        let model = PortalsModel(
            source: SamplePortals(
                portals: [Self.portal("ah", name: "flatone")],
                tree: [
                    "ah::": [Self.folder("fp", "Clips")],
                    "ebene:fp": [Self.titleEntry("v1", "Ein Titel")],
                ]),
            memory: PortalMemory(store: Self.freshStore()))
        await model.load()
        let root = try! #require(model.pending?.identifier)

        model.memorize(scrollAnchor: "fp", forItem: root)
        await model.open(try! #require(model.pending?.entries.first))
        model.back()

        #expect(
            model.scrollAnchor(forItem: root) == "fp",
            "the root's position must survive the trip down")
    }

    /// **A level that nobody has left yet has no position.** `nil` means "start
    /// at the top" — an invented ID would be a jump that nobody requested.
    @Test("An unknown level reports no scroll position")
    @MainActor
    func scrollPositionUnknown() async {
        let model = PortalsModel(
            source: SamplePortals(
                portals: [Self.portal("ah")], tree: ["ah::": [Self.folder("fp", "FP")]]),
            memory: PortalMemory(store: Self.freshStore()))
        await model.load()
        #expect(model.scrollAnchor(forItem: "gibtEsNicht") == nil)
    }

    /// **The level that was left gives up its position.** Anyone who reopens a folder
    /// starts at the top and not where they left off last time.
    @Test("The position of the abandoned level is forgotten")
    @MainActor
    func scrollPositionOfAbandonedLevel() async {
        let model = PortalsModel(
            source: SamplePortals(
                portals: [Self.portal("ah")],
                tree: [
                    "ah::": [Self.folder("fp", "Clips")],
                    "ebene:fp": [Self.folder("tief", "Tiefer")],
                ]),
            memory: PortalMemory(store: Self.freshStore()))
        await model.load()
        await model.open(try! #require(model.pending?.entries.first))
        let bottom = try! #require(model.pending?.identifier)
        model.memorize(scrollAnchor: "tief", forItem: bottom)

        model.back()
        #expect(model.scrollAnchor(forItem: bottom) == nil)
    }

    /// A portal switch also throws away the remembered positions — they belong to the tree
    /// it leaves.
    @Test("A portal switch forgets the scroll positions")
    @MainActor
    func scrollPositionsOnSwitch() async {
        let model = PortalsModel(
            source: SamplePortals(
                portals: [Self.portal("ss"), Self.portal("aw")],
                tree: ["ss::": [Self.folder("a", "A")], "aw::": []]),
            memory: PortalMemory(store: Self.freshStore()))
        await model.load()
        let root = try! #require(model.pending?.identifier)
        model.memorize(scrollAnchor: "a", forItem: root)

        await model.select(Self.portal("aw"))
        #expect(model.scrollAnchor(forItem: root) == nil)
    }

    // MARK: - Der gemerkte Weg im Portal

    /// **Finding of 2026-09-09:** the fix in the library regarding the last opened view
    /// works … can the same be done in portals? The portal itself was
    /// already remembered; what was missing was the counterpart to the remembered section — the level **within** it.
    @Test("The most recently open folder is reopened on cold start")
    @MainActor
    func pathSurvivesColdStart() async {
        let store = Self.freshStore()
        let tree = [
            "ah::": [Self.folder("fp", "Clips")],
            "ebene:fp": [Self.titleEntry("v1", "Ein Titel")],
        ]

        let first = PortalsModel(
            source: SamplePortals(portals: [Self.portal("ah", name: "flatone")], tree: tree),
            memory: PortalMemory(store: store))
        await first.load()
        await first.open(try! #require(first.pending?.entries.first))
        #expect(first.path == "flatone › Clips")

        // The cold start: a new model on the same disk.
        let second = PortalsModel(
            source: SamplePortals(portals: [Self.portal("ah", name: "flatone")], tree: tree),
            memory: PortalMemory(store: store))
        await second.load()
        #expect(second.chosen?.id == "ah", "the portal was already selected before")
        #expect(
            second.path == "flatone › Clips",
            "and the level inside must return just like the library's category")
        #expect(second.hasWayBack, "the way back to the root must be there")
    }

    /// **Anyone who goes back to the root has no bookmark any more.** Otherwise the
    /// next start would lead again into the folder one has just explicitly left.
    @Test("The way back to the root deletes the remembered path")
    @MainActor
    func wayBackDeletesPath() async {
        let store = Self.freshStore()
        let tree = [
            "ah::": [Self.folder("fp", "Clips")],
            "ebene:fp": [Self.titleEntry("v1", "Ein Titel")],
        ]

        let first = PortalsModel(
            source: SamplePortals(portals: [Self.portal("ah")], tree: tree),
            memory: PortalMemory(store: store))
        await first.load()
        await first.open(try! #require(first.pending?.entries.first))
        first.back()

        let second = PortalsModel(
            source: SamplePortals(portals: [Self.portal("ah")], tree: tree),
            memory: PortalMemory(store: store))
        await second.load()
        #expect(second.stack.count == 1)
    }

    /// **A bookmark that no longer opens ends on the root** — and not on
    /// an empty screen. A portal rearranges its entry points; that is no defect.
    @Test("A vanished level falls back to the root")
    @MainActor
    func vanishedLevelFallsBack() async {
        let store = Self.freshStore()

        let first = PortalsModel(
            source: SamplePortals(
                portals: [Self.portal("ah")],
                tree: [
                    "ah::": [Self.folder("fp", "Clips")],
                    "ebene:fp": [Self.titleEntry("v1", "Ein Titel")],
                ]),
            memory: PortalMemory(store: store))
        await first.load()
        await first.open(try! #require(first.pending?.entries.first))

        // At the next start nothing lies behind "Clips" any more.
        let second = PortalsModel(
            source: SamplePortals(
                portals: [Self.portal("ah")], tree: ["ah::": [Self.folder("fp", "FP")]]),
            memory: PortalMemory(store: store))
        await second.load()
        #expect(second.stack.count == 1, "the empty slot is not entered")
        #expect(second.state == .settled, "and the root is shown instead of reporting empty")
    }

    /// **At most two places deep.** Each place is a fetch; measured at the bridge,
    /// one takes 0.93 s with flatone. Three would be three seconds of loading indicator before the
    /// first image.
    @Test("A deep path is restored only down to the second level")
    @MainActor
    func pathIsLimited() async {
        let store = Self.freshStore()
        let tree = [
            "ah::": [Self.folder("a", "A")],
            "ebene:a": [Self.folder("b", "B")],
            "ebene:b": [Self.folder("c", "C")],
            "ebene:c": [Self.titleEntry("v1", "Ein Titel")],
        ]

        let first = PortalsModel(
            source: SamplePortals(portals: [Self.portal("ah")], tree: tree),
            memory: PortalMemory(store: store))
        await first.load()
        for _ in 0..<3 {
            await first.open(try! #require(first.pending?.entries.first))
        }
        #expect(first.stack.count == 4)

        let second = PortalsModel(
            source: SamplePortals(portals: [Self.portal("ah")], tree: tree),
            memory: PortalMemory(store: store))
        await second.load()
        #expect(second.stack.count == 3, "root and two slots, no more")
    }

    /// **The path belongs to the portal in which it was walked.** Anyone who switches
    /// portals in between should find their own state there — and in the first one
    /// still their own.
    @Test("Every portal keeps its own path")
    @MainActor
    func pathPerPortal() async {
        let store = Self.freshStore()
        let tree = [
            "ss::": [Self.folder("a", "Beliebt")],
            "ebene:a": [Self.titleEntry("v1", "Ein Titel")],
            "aw::": [Self.folder("n", "Neu")],
            "ebene:n": [Self.titleEntry("v2", "Noch einer")],
        ]

        let first = PortalsModel(
            source: SamplePortals(
                portals: [Self.portal("ss"), Self.portal("aw")], tree: tree),
            memory: PortalMemory(store: store))
        await first.load()
        await first.open(try! #require(first.pending?.entries.first))
        await first.select(Self.portal("aw"))
        #expect(first.path == "aw", "a switch resets to the root of the new portal")

        // Back to the first portal: its path is still there.
        await first.select(Self.portal("ss"))
        #expect(first.path == "ss › Beliebt")
    }

    /// **An unanswered follow-up question is not a place.** "Clear Search History" asks "Are
    /// you sure…" — waking up before this question would be the most unfriendly start view
    /// the tab has to offer, especially since nobody can answer it here yet.
    @Test("A level with a follow-up question is not remembered")
    @MainActor
    func followUpQuestionIsNotRemembered() async {
        let store = Self.freshStore()
        let tree = ["ah::": [Self.folder("clear", "Clear Search History")], "ebene:clear": []]

        let first = PortalsModel(
            source: SamplePortals(
                portals: [Self.portal("ah")], tree: tree,
                followUpQuestion: "Confirm: Are you sure you want to clear the search history?"),
            memory: PortalMemory(store: store))
        await first.load()
        await first.open(try! #require(first.pending?.entries.first))
        #expect(first.stack.count == 2)

        let second = PortalsModel(
            source: SamplePortals(
                portals: [Self.portal("ah")], tree: tree,
                followUpQuestion: "Confirm: Are you sure you want to clear the search history?"),
            memory: PortalMemory(store: store))
        await second.load()
        #expect(second.stack.count == 1, "the question stays where it was asked")
    }

    /// **Finding of 2026-09-09:** tapping new search should open a search window,
    /// but what opens is the following — a grid of foreign hits.
    ///
    /// **Measured twice at the bridge:** `flatone › Clips › Search › New
    /// Search` returns `braucht_eingabe` **and** thirteen entries; the suggestion was
    /// "redhead" on the first fetch, "sunset" on the second — and on the second every one of the
    /// thirteen titles carried the word "Sunset". The hits belong to the last search in the reader.
    ///
    /// This check pins down the **shape**: Question and entries come together. That the
    /// view therefore does not draw the list is documented at ``PortalsView/unanswered``.
    @Test("A questioning level brings results nobody searched for here")
    @MainActor
    func queryAndForeignHits() async {
        let model = PortalsModel(
            source: SamplePortals(
                portals: [Self.portal("ah")],
                tree: ["ah::": [Self.titleEntry("v1", "Midnight Velvet Visit")]],
                query: "Enter search text for clips", suggestion: "sunset"),
            memory: PortalMemory(store: Self.freshStore()))
        await model.load()
        #expect(model.pending?.query != nil)
        #expect(!model.order.entries.isEmpty, "the bridge sends both at once")
    }

    /// **A question is not a place where one has been.** Waking up on an empty
    /// search field at cold start — for a fetch that costs a second — is not a
    /// start view. The **answered** search is certainly remembered; it is a
    /// level of its own without a question.
    @Test("A questioning level is not remembered as a place")
    @MainActor
    func queryingLevelIsNotRemembered() async {
        let store = Self.freshStore()
        let source = SamplePortals(
            portals: [Self.portal("ah")],
            tree: [
                "ah::": [Self.folder("s", "New Search")],
                "ebene:s": [Self.titleEntry("v1", "Midnight Velvet Visit")],
            ],
            query: "Enter search text for clips", suggestion: "sunset")

        let first = PortalsModel(
            source: source, memory: PortalMemory(store: store))
        await first.load()
        await first.open(try! #require(first.pending?.entries.first))
        #expect(first.stack.count == 2)

        let second = PortalsModel(
            source: source, memory: PortalMemory(store: store))
        await second.load()
        #expect(second.stack.count == 1, "the question stays where it was asked")
    }

    // MARK: - Die Frage und ihr Vorschlag

    /// **Finding of 2026-09-09:** search in flatone in the individual sections
    /// does not work. The bridge stayed silent because the reader's keyboard was prefilled with the
    /// last term of its search history. Now the question comes — and the
    /// suggestion next to it, so that the field does not stand there empty.
    @Test("The suggestion for the question reaches the level")
    @MainActor
    func suggestionGetsThrough() async {
        let model = PortalsModel(
            source: SamplePortals(
                portals: [Self.portal("ah")],
                tree: ["ah::": []], query: "Enter search text", suggestion: "glasses"),
            memory: PortalMemory(store: Self.freshStore()))
        await model.load()
        #expect(model.pending?.query == "Enter search text")
        #expect(model.pending?.suggestion == "glasses")
    }

    /// **The suggestion stays that of the first page** — the same rule as for title and
    /// ID: The path keeps pointing to where one entered.
    @Test("A follow-up page does not change the suggestion")
    func suggestionAcrossPageBoundary() {
        let first = PortalLayer(
            identifier: "a", title: "Suche", entries: [], query: "Search",
            suggestion: "glasses")
        let second = PortalLayer(identifier: "a", title: "Suche", entries: [])
        #expect(first.using(page: second).suggestion == "glasses")
    }

    /// **A follow-up question is not an empty report.** "Clear Search History" returns an empty
    /// level with the sentence "Confirm: Are you sure…" — until 2026-09-09 above it stood "Nothing
    /// here", that is, the wrong information about the wrong situation.
    @Test("A follow-up question sits next to the hint, not in its place")
    func followUpQuestionBesideHint() {
        let level = PortalLayer(
            identifier: "ah:clear:", title: "Clear Search History", entries: [],
            hint: "Confirm: Are you sure you want to clear the search history?",
            followUpQuestion: "Confirm: Are you sure you want to clear the search history?")
        #expect(level.followUpQuestion != nil, "the question must remain recognizable as a question")
        #expect(level.entries.isEmpty)
    }

    private static func freshStore() -> UserDefaults {
        UserDefaults(suiteName: "probe.\(UUID().uuidString)") ?? .standard
    }
}

/// Portals without a bridge — **a tree from a table.**
private struct SamplePortals: PortalContentSource {
    let portals: [PortalInfo]
    /// Per ID the entries that lie there.
    var tree: [String: [PortalEntry]] = [:]
    var hint: String?
    var query: String?
    var suggestion: String?
    var followUpQuestion: String?
    /// Per ID the follow-up pages, in the order in which they are to come.
    ///
    /// The marker is the position in this list — just like at the Ahorn a number whose
    /// meaning only the portal knows.
    var pages: [String: [[PortalEntry]]] = [:]
    var host: [PortalHost] = []

    func portals() async throws -> [PortalInfo] { portals }

    func root(zu portal: String) -> String { "\(portal)::" }

    func level(zu identifier: String, title: String, next nextValue: String?) async throws -> PortalLayer {
        let episodes = pages[identifier] ?? []
        let slot = nextValue.flatMap(Int.init)
        let entries =
            slot.map { episodes.indices.contains($0) ? episodes[$0] : [] }
            ?? (tree[identifier] ?? [])
        let nextItem = slot.map { $0 + 1 } ?? 0
        return PortalLayer(
            identifier: identifier, title: title, entries: entries,
            hint: hint, query: query,
            total: episodes.isEmpty
                ? nil : (tree[identifier] ?? []).count + episodes.map(\.count).reduce(0, +),
            next: episodes.indices.contains(nextItem) ? String(nextItem) : nil,
            suggestion: suggestion, followUpQuestion: followUpQuestion)
    }

    func languages(zu identifier: String) async throws -> [String] { [] }
    func select(language: String, forItem identifier: String) async throws {}
    func host(zu identifier: String) async throws -> [PortalHost] { host }
}

/// Portals that **change between two fetches** — for the second `load()` run.
///
/// `SamplePortals` is a value and answers every fetch the same; exactly that cannot be
/// checked when the point is what happens on **repeated** loading. The last
/// run stays standing so that a third fetch does not reach into the void.
private final class SwitchingPortals: PortalContentSource, @unchecked Sendable {

    private var runs: [[PortalInfo]]
    private let tree: [String: [PortalEntry]]

    init(runs: [[PortalInfo]], tree: [String: [PortalEntry]]) {
        self.runs = runs
        self.tree = tree
    }

    func portals() async throws -> [PortalInfo] {
        runs.count > 1 ? runs.removeFirst() : (runs.first ?? [])
    }

    func root(zu portal: String) -> String { "\(portal)::" }

    func level(zu identifier: String, title: String, next: String?) async throws -> PortalLayer {
        PortalLayer(identifier: identifier, title: title, entries: tree[identifier] ?? [])
    }

    func languages(zu identifier: String) async throws -> [String] { [] }
    func select(language: String, forItem identifier: String) async throws {}
    func host(zu identifier: String) async throws -> [PortalHost] { [] }
}

/// The remembered portal source and the changed address — 2026-09-08.
///
/// **Seen on the device, and both at the same time:** In Settings it said "The bridge
/// answers · 4 portals found", in the tab next to it "The portals bridge does not answer"
/// — for the same bridge.
///
/// **Two paths, and only one was fresh.** The check in Settings builds a new connection for every
/// press; the tab took the remembered one, and that was built with the **old**
/// address. Anyone who changed the address thus got the result of the check and not
/// its effect.
@Suite("Portal source after an address change", .serialized)
@MainActor
struct PortalSourceAddressTests {

    private func withAddress(_ address: String?) -> FeaturesPhone.SetupState {
        let store = UserDefaults(suiteName: "probe.\(UUID().uuidString)") ?? .standard
        let setup = FeaturesPhone.SetupState(store: store)
        setup.set(bridge: address.flatMap(URL.init(string:)))
        return setup
    }

    /// **The source is rebuilt as soon as the address is a different one.** Without this rule
    /// the tab pointed to a bridge that the viewer had long since replaced — and the
    /// Settings next to it claimed the opposite.
    @Test("A changed bridge address rebuilds the portal source")
    func rebuilt() throws {
        SourceAssembly.forget()
        defer { SourceAssembly.forget() }

        let setup = FeaturesPhone.SetupState()
        let previous = setup.bridgeURL
        defer { setup.set(bridge: previous) }

        setup.set(bridge: URL(string: "http://alt.invalid:8099")!)
        let first = SourceAssembly.portalSource()
        #expect(first != nil)
        #expect(SourceAssembly.rememberedBridgeForCheck?.absoluteString == "http://alt.invalid:8099")

        setup.set(bridge: URL(string: "http://neu.invalid:8099")!)
        _ = SourceAssembly.portalSource()
        #expect(
            SourceAssembly.rememberedBridgeForCheck?.absoluteString == "http://neu.invalid:8099",
            "The source must follow the new address and not the remembered one")
    }

    /// **And it stays remembered as long as nothing changes.** Otherwise the healing would have
    /// become a rebuild on every access — and the portal source holds a
    /// cache that a rebuild throws away.
    @Test("With the same address the source stays the same")
    func staysRemembered() throws {
        SourceAssembly.forget()
        defer { SourceAssembly.forget() }

        let setup = FeaturesPhone.SetupState()
        let previous = setup.bridgeURL
        defer { setup.set(bridge: previous) }

        setup.set(bridge: URL(string: "http://gleich.invalid:8099")!)
        let first = try #require(SourceAssembly.portalSource())
        let second = try #require(SourceAssembly.portalSource())
        #expect(first === second)
    }
}
