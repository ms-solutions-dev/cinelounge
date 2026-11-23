import Core
import Foundation
import ParentalControls
import PlaylistKit
import Testing

@testable import FeaturesPhone

/// The value column — **the done condition of this package.**
///
/// "Every area shows what is in it: so that one need not open it to see whether
/// something is missing." A list of nine names with nine chevrons forces nine taps to
/// answer a single question.
///
/// **What is checked is keys and not German words.** Under `swift test` there is
/// no app bundle, and `String(localized:)` returns the key instead of the
/// text there — a check for "TMDb missing" would thus test the presence of the catalog and
/// not the value. The finding from 2026-09-06 improved the type: the value now carries
/// a ``CaptionLabel``.
@Suite("Settings")
struct SettingsTests {

    private static func makeStore() -> SecureStore {
        SecureStore(service: "probe.\(UUID().uuidString)")
    }

    @MainActor
    private static func model(_ secureStore: SecureStore) -> SettingsModel {
        SettingsModel(
            state: SetupState(
                keychain: secureStore,
                listen: PlaylistStore(
                    store: InMemoryStore(), secrets: InMemoryStore(), ledger: InMemoryStore()),
                store: UserDefaults(suiteName: "probe.\(UUID().uuidString)") ?? .standard,
                ledgerStore: InMemoryStore()),
            accounts: AccountsModel(
                keychain: secureStore,
                childAccounts: ChildAccountList(store: InMemoryStore())),
            keychain: secureStore)
    }

    /// **No area without a value.** An empty column is exactly what this view is meant to
    /// avoid: it looks as if there were nothing to say, and forces opening.
    @Test("Every area has a value")
    @MainActor
    func everySectionHasAValue() {
        let secureStore = Self.makeStore()
        let model = Self.model(secureStore)

        // **Eleven since 2026-09-07**, before that nine: Storage lay one level deeper under the
        // account and ended in the developer placeholder, "About" did not exist at all — and the
        // privacy policy in it is required within the app by guideline 5.1.1(i).
        // **Twelve since AP59 N7** — "Other devices" bundles sharing, handoff, remote.
        #expect(SettingsModel.Area.allCases.count == 12)
        for area in SettingsModel.Area.allCases {
            let value = model.values[area]
            #expect(value != nil, "\(area.rawValue) has no value")
            #expect(
                value?.label.raw.isEmpty == false,
                "\(area.rawValue) has an empty value")
        }
    }

    /// **Every area leads somewhere else.** Two rows with the same target would be one too
    /// many — and one would notice only when pressing.
    @Test("No two areas lead into the same view")
    func everyOneLeadsElsewhere() {
        let targets = SettingsModel.Area.allCases.map(\.view)
        #expect(Set(targets).count == targets.count)
    }

    /// **The case for which the value column exists.** If a key is missing, it says so here
    /// and not two levels deeper.
    @Test("A missing key shows in the value column and is marked as missing")
    func missingKeyIsShown() throws {
        let emptyStore = Self.makeStore()
        #expect(SettingsModel.ratingsValue(emptyStore).isMissing)

        try emptyStore.setOMDbAPIKey("abc")
        let half = SettingsModel.ratingsValue(emptyStore)
        #expect(half.isMissing, "one is still missing")
        #expect(half.key == "settings.value.tmdbMissing")

        try emptyStore.setTMDbAPIKey("def")
        #expect(!SettingsModel.ratingsValue(emptyStore).isMissing)

        try? emptyStore.remove("omdb.apikey")
        try? emptyStore.remove("tmdb.apikey")
    }

    /// **Gold and not red.** "TMDb missing" is no failure but a bill: something
    /// that can be supplied later is missing, and until then nothing is broken.
    @Test("Only real gaps are marked as missing")
    @MainActor
    func onlyGapsAreMarked() {
        let model = Self.model(Self.makeStore())

        // "off" is information and not a deficiency — an adult account needs no
        // parental controls, and a gold hint about it would be an admonition.
        #expect(model.values[.parentalControls]?.isMissing == false)
        #expect(model.values[.portals]?.isMissing == false)
        #expect(model.values[.playback]?.isMissing == false)
    }

    /// Whoever comes back from an area may have changed something there. A
    /// value column that shows the state from before is worse than none: it looks
    /// right.
    @Test("The values are computed and not maintained")
    @MainActor
    func valuesAreComputed() throws {
        let secureStore = Self.makeStore()
        let model = Self.model(secureStore)
        #expect(model.values[.ratings]?.isMissing == true)

        try secureStore.setOMDbAPIKey("abc")
        try secureStore.setTMDbAPIKey("def")
        model.calculate()

        #expect(model.values[.ratings]?.isMissing == false)
        try? secureStore.remove("omdb.apikey")
        try? secureStore.remove("tmdb.apikey")
    }
}

/// The Live area: **what it writes and where it lands.**
///
/// `LivePreferences` was read until 2026-09-06 and set nowhere — the screen for it
/// was missing entirely. A chip field that saves nothing is a screen that forgets
/// on leaving, and that is noticed only when one comes back.
@MainActor
@Suite("Live settings")
struct LiveSettingsStoreTests {

    static func model() -> LiveSettingsModel {
        LiveSettingsModel(
            keychain: InMemoryStore(),
            tabStore: InMemoryStore())
    }

    /// **On toggling and not on "Done".** Every other setting of this app takes effect
    /// immediately; a screen with a save button would be the only one.
    ///
    /// Checked on a sports chip and no longer on "Show preview": the switch was dropped on
    /// 2026-09-07 because it had no reader outside the settings view.
    @Test("A toggle lands in the store immediately")
    func grabSaves() {
        let bucket = InMemoryStore()
        let model = LiveSettingsModel(keychain: bucket)
        #expect(model.showsSports(.football), "default: everything visible")

        model.setEnabled(sport: .football)

        #expect(!model.showsSports(.football))
        #expect(
            !SportFilterSettings.load(from: bucket).isEnabled(.football),
            "and in the store, under the TV's key (AP58 R5)")
    }

    /// **Read fresh, change, write back.** `LivePreferences` stores all fields in
    /// one go; a held copy would overwrite what has meanwhile been changed elsewhere
    /// — such as the adult switch from the parental controls.
    @Test("A toggle does not overwrite what has meanwhile been changed elsewhere")
    func noOverwrite() {
        let bucket = InMemoryStore()
        let model = LiveSettingsModel(keychain: bucket)

        // Changed elsewhere after the model has read.
        var foreign = LivePreferences.load(from: bucket)
        foreign.setShowsAdultChannels(true)
        foreign.setVisible(false, group: "XXX")
        foreign.save(to: bucket)

        model.setEnabled(sport: .football)

        let following = LivePreferences.load(from: bucket)
        #expect(!SportFilterSettings.load(from: bucket).isEnabled(.football))
        #expect(following.showsAdultChannels, "the other switch is still set")
        #expect(following.hiddenGroups.contains("XXX"), "and the other group too")
    }

    /// **The bulk commands save twenty-one taps.** Without them one lives with a
    /// bar that one did not want.
    @Test("All and None affect every sport")
    func bulkCommands() {
        let model = Self.model()
        #expect(model.visibleSports == SportKind.allCases.count, "default: all")

        model.setAllSports(false)
        #expect(model.visibleSports == 0)

        model.setEnabled(sport: .football)
        #expect(model.visibleSports == 1)
        #expect(model.showsSports(.football))

        model.setAllSports(true)
        #expect(model.visibleSports == SportKind.allCases.count)
    }

    /// **Excluded and not allowed.** If a sport is added — on 2026-08-29 it was
    /// four at once —, it is included without any action. With an allow list it would be
    /// silently invisible, and one would look for the error in the app.
    @Test("What is saved is what is hidden")
    func hiddenItemIsSaved() {
        let bucket = InMemoryStore()
        let model = LiveSettingsModel(keychain: bucket)
        model.setEnabled(sport: .darts)

        let stored = SportFilterSettings.load(from: bucket)
        #expect(stored.disabled == ["darts"])
        #expect(stored.isEnabled(.football), "everything else stays included without further action")
    }

    /// **The third reason why a tab can be missing.** It says something different from the
    /// other two: "Live is missing because there is no list" and "Live is missing because you
    /// switched it off" lead to different next steps.
    @Test("A deselected tab disappears — and the other reasons stay separate")
    func tabDeselected() {
        let state = CatalogState.fromAccesses(jellyfin: true, channelList: true, portals: true)
        #expect(state.tabs.contains(.live))

        #expect(!state.tabs(isInChildMode: false, deselected: ["live"]).contains(.live))
        // Child mode removes Live AND Portals, the deselection only what is there.
        #expect(state.tabs(isInChildMode: false, deselected: ["live"]).contains(.portals))
        #expect(!state.tabs(isInChildMode: true).contains(.portals))
    }

    /// **On disk and sorted.** The same selection should result in the same store,
    /// otherwise a comparison sees changes where there are none.
    @Test("The tab choice survives and is stored sorted")
    func tabChoiceStore() {
        let store = InMemoryStore()
        var choice = TabSelection(store: store)
        choice.set("portale", isVisible: false)
        choice.set("live", isVisible: false)

        #expect(TabSelection.stored(store: store) == ["live", "portale"])
        #expect(
            RecordSheet.read([String].self, under: TabSelection.key, from: store)
                == ["live", "portale"])

        choice.set("live", isVisible: true)
        choice.set("portale", isVisible: true)
        #expect(TabSelection.stored(store: store).isEmpty)
        // **Nothing remembered means: no file.** An empty list would look like a
        // setting that nobody has made.
        #expect((try? store.value(for: TabSelection.key)) == nil)
    }

    /// **The takeover from the standard settings** (AP40, 2026-09-21). Without it,
    /// all tabs that somebody had deselected would be back after the update.
    @Test("A deselected tab list moves into the file")
    func tabChoiceAdoption() {
        let legacy = UserDefaults(suiteName: "probe.\(UUID().uuidString)")!
        legacy.set(["portale", "live"], forKey: TabSelection.key)
        let fresh = InMemoryStore()

        #expect(TabSelection.adopt(from: legacy, in: fresh))

        #expect(TabSelection.stored(store: fresh) == ["live", "portale"])
        #expect(legacy.stringArray(forKey: TabSelection.key) == nil)
        // A second run finds the file and does nothing.
        #expect(TabSelection.adopt(from: legacy, in: fresh) == false)
    }
}

/// **The provider's response is interpreted, not displayed** (2026-09-07): three causes,
/// three sentences — and for "valid" the numbers that decide something.
@Suite("Check access")
struct CheckAccessTests {

    private func reply(_ json: String) throws -> XtreamPayload.AccountInfo {
        try JSONDecoder().decode(XtreamPayload.AccountInfo.self, from: Data(json.utf8))
    }

    @Test("A valid access names the deadline, connections and the formats")
    func isValid() throws {
        let info = try reply(
            #"{"auth":1,"status":"Active","exp_date":"1818436172","max_connections":"1","active_cons":"0","allowed_output_formats":["ts"]}"#
        )
        let outcome = ChannelListsView.interpret(ChannelListCheck.interpret(info))
        #expect(outcome.isGood)
        #expect(outcome.title == "settings.lists.check.ok")
        let wording = try #require(outcome.wording)
        #expect(wording.contains("0"), "the occupied connections are included")
        #expect(wording.contains("·"), "deadline, connections and formats are three parts")
    }

    @Test("A rejected access is not an expired one")
    func rejected() throws {
        let outcome = ChannelListsView.interpret(ChannelListCheck.interpret(try reply(#"{"auth":0}"#)))
        #expect(!outcome.isGood)
        #expect(outcome.title == "settings.lists.check.rejected")
    }

    @Test("An expired access says so")
    func expired() throws {
        let outcome = ChannelListsView.interpret(
            ChannelListCheck.interpret(try reply(#"{"auth":1,"status":"Expired","exp_date":"1000"}"#)))
        #expect(!outcome.isGood)
        #expect(outcome.title == "settings.lists.check.expired")
    }
}
