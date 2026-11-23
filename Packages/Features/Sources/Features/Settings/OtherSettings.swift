import Core
import DesignSystem
import Flows
import JellyfinKit
import PortalKit
import SwiftUI

// The remaining four areas of the settings. They all used to be on one
// page; the reasoning for the split is at `SettingsSection`.

// MARK: - Ratings

/// The accesses for ratings: OMDb (IMDb, Rotten Tomatoes, Metacritic), TMDb and
/// MyAnimeList.
struct RatingsSettings: View {

    let onKeyChanged: (String) -> Void
    /// Like ``onKeyChanged``, only for the movie database: the access takes effect
    /// immediately on saving, without the app having to be restarted.
    let onFilmographyKeyChanged: (String) -> Void

    @State private var key = ""
    @State private var saved = false
    /// Kept separate from the ratings key because they are two services with two
    /// accounts — the full reasoning is at ``SecureStore/tmdbAPIKey()``.
    @State private var filmographyKey = ""
    @State private var filmographySaved = false
    /// The client ID for MyAnimeList (AP68) — the third access, same kind.
    @State private var malID = ""
    @State private var malSaved = false
    @FocusState private var focus: String?
    @Environment(\.settingsEntryRequest) private var entryRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            HStack(spacing: 20) {
                // **Visible, no password field.** A `SecureField` used to be here, and
                // that was the wrong caution: an OMDb key is not a
                // password, but on the TV keyboard a typo is the rule —
                // and behind dots it cannot be found. It is stored
                // unchanged in the Keychain; only the input shows what it does.
                InputRow(
                    title: "settings.ratingsKeyPrompt", text: $key, state: .alone,
                    kind: .identifier, width: 620, identifier: "key", focus: $focus
                )
                // **The note sits at the first target and no longer at the area header** (AP46,
                // 2026-09-24). It hung there because the header was the first element; with
                // the ``AreaBreadcrumb`` it is gone, and at the target itself it is more
                // correct anyway — it says **which** element gets the focus.
                .preference(key: SettingsFirstEntryKey.self, value: "key")
                .onChange(of: entryRequest) { _, _ in focus = "key" }

                FormButton(
                    title: "settings.saveKey",
                    statusTitle: "settings.keySaved",
                    state: saved ? .done : .ready,
                    rank: .main,
                    identifier: "save",
                    focus: $focus
                ) {
                    try? SecureStore().setOMDbAPIKey(key)
                    onKeyChanged(key)
                    saved = true
                }
            }

            // What is missing without a key and what is not — otherwise you consider it
            // necessary and sign up for a service you do not need.
            Text(app: "settings.ratingsWithoutKey")
                .font(TypeLevel.lowercased.font)
                .foregroundStyle(ColorRole.textQuiet.color)
                .padding(.top, 26)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 900, alignment: .leading)

            filmographyBlock
            malBlock
        }
        .task {
            key = SecureStore().omdbAPIKey() ?? ""
            saved = !key.isEmpty
            filmographyKey = SecureStore().tmdbAPIKey() ?? ""
            filmographySaved = !filmographyKey.isEmpty
            malID = SecureStore().malClientID() ?? ""
            malSaved = !malID.isEmpty
        }
        .onChange(of: key) { _, _ in saved = false }
        .onChange(of: filmographyKey) { _, _ in filmographySaved = false }
        .onChange(of: malID) { _, _ in malSaved = false }
    }

    /// The third access: MyAnimeList for the anime rating (AP68). No callback needed —
    /// ``RatingsKit/AnimeRating`` reads the client ID itself on every query.
    private var malBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsHeader("settings.section.mal", hint: "settings.malKeyHint")

            HStack(spacing: 20) {
                InputRow(
                    title: "settings.malKeyPrompt", text: $malID,
                    state: .alone, kind: .identifier, width: 620, identifier: "mal-key",
                    focus: $focus)

                FormButton(
                    title: "settings.saveKey",
                    statusTitle: "settings.keySaved",
                    state: malSaved ? .done : .ready,
                    rank: .main,
                    identifier: "mal-save",
                    focus: $focus
                ) {
                    try? SecureStore().setMALClientID(malID)
                    malSaved = true
                }
            }
        }
        .padding(.top, 60)
    }

    /// The second access: the movie database behind a person's career.
    ///
    /// **On the same page and not in an area of its own**, because it is
    /// the same kind of entry: a personal access to a third-party
    /// service that you enter once and then forget. Two pages for it
    /// would mean searching twice.
    private var filmographyBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsHeader("settings.section.filmography", hint: "settings.filmographyKeyHint")

            HStack(spacing: 20) {
                // Visible as above, and for the same reason: on the
                // TV keyboard a typo is the rule.
                InputRow(
                    title: "settings.filmographyKeyPrompt", text: $filmographyKey,
                    state: .alone, kind: .identifier, width: 620, identifier: "tmdb-key",
                    focus: $focus)

                FormButton(
                    title: "settings.saveKey",
                    statusTitle: "settings.keySaved",
                    state: filmographySaved ? .done : .ready,
                    rank: .main,
                    identifier: "tmdb-save",
                    focus: $focus
                ) {
                    try? SecureStore().setTMDbAPIKey(filmographyKey)
                    onFilmographyKeyChanged(filmographyKey)
                    filmographySaved = true
                }
            }

            Text(app: "settings.filmographyWithoutKey")
                .font(TypeLevel.lowercased.font)
                .foregroundStyle(ColorRole.textQuiet.color)
                .padding(.top, 26)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 900, alignment: .leading)
        }
        .padding(.top, 60)
    }
}

// MARK: - Appearance

/// How the app looks and what is on Home.
///
/// **Language has been an area of its own since 2026-09-25** (``LanguageSettings``,
/// owner decision 1).
///
/// **The first level has ten focus targets and not over forty** (AP46, 2026-09-25). Here
/// used to be colour schemes as three pills, five icon tiles, three buttons per Home row,
/// one pill per library and five levels — the done condition of the package
/// demands fewer than fifteen. Long lists now sit behind a row with a count
/// (the same pattern as the channel groups in "Live"), three values cycle through, five
/// are chosen in the card (decision 6). ``FocusPlan`` pins the number down.
struct AppearanceSettings: View {

    let source: JellyfinSource?

    /// The groups of the enabled channel lists — **only to know whether they
    /// exist.**
    ///
    /// **Because `source.libraries()` was the wrong question** (2026-09-12): the Live shelf
    /// on Home comes from the downloads of the channel lists (``LiveShelf``), not from
    /// a library of the media server. Whoever asked for `.liveTV` among the libraries
    /// got "no channel list" even when two thousand channels
    /// were stored — and "What's on now" was missing from the list.
    var liveGroups: [String] = []

    /// The portal levels a shelf can be made from — **from outside.**
    ///
    /// **Not from ``source``**, because that is the media server. Reported on 2026-09-12:
    /// *"although portals are set up I cannot choose anything here."* The section
    /// stood there with "No portal set up" while ten portals were answering.
    var portalLevels: [Core.Library] = []

    /// Where the subfolders of a portal level come from — **the portal source, not
    /// ``source``.** The same mix-up already left the section empty once on 2026-09-12.
    var portalDataSource: PortalSource?

    /// The categories of the provider catalog a shelf can be made from — **from
    /// outside, the same mistake for the third time.**
    ///
    /// **The finding of 2026-09-13:** *"but I cannot choose anywhere which 2 I
    /// want to show here in Home."* The picker was built, the row before it too — and
    /// it checked `alleBibliotheken` for provider sections, where `alleBibliotheken` came from
    /// `source.libraries()` and `source` is the **media server**. Provider sections
    /// arrive there as little as portal levels and channel lists before them; the row
    /// was never shown. The shell holds the sections for the sidebar (`vodLibraries`),
    /// and the same catalog comes in here.
    var providerCategories: [Core.Library] = []

    /// Where the channels to choose from come from. An empty answer means "no channel list".
    var channelCatalog: @Sendable () async -> [Channel] = { [] }

    /// What the right-hand area currently shows.
    ///
    /// **Not an area of its own in the list on the left, and that is measured** (2026-09-12):
    /// the first attempt gave the two pickers a ``SettingsSection`` each. The check
    /// "All areas fit on the screen without scrolling" reported it — thirteen
    /// entries are 1190 points tall, the screen 1080. **The list on the left is full**,
    /// and the house rule "one more area costs nothing" has a ceiling there.
    ///
    /// **So a mode instead of an area.** "Appearance" shows two short rows with a
    /// count; a press replaces the right-hand area with the picker, the Menu button
    /// leads back. The same way as on the phone, where "Arrange shelves" is a screen
    /// of its own behind a row.
    private enum Mode: Equatable {
        case overview, portals, channels, categories
        /// The five icon tiles — **pictures**, and a picture says what a name does not say.
        case symbol
        /// Order and visibility of the Home rows — three buttons per row.
        case rows
        /// Which libraries may go into the header area.
        case headerArea
    }

    @State private var mode: Mode = .overview

    /// From the environment and not passed through: the path from the root to here
    /// leads across four views that have nothing to do with colour schemes. Each of
    /// them would otherwise get a parameter it only passes on.
    @EnvironmentObject private var themes: ThemeStore

    /// Asks the system at startup which icon currently applies — hence here and
    /// not in the environment: nobody except this view needs it.
    @StateObject private var icons = AppIconStore(system: SystemAppIcons())

    @State private var libraries: [Core.Library] = []
    @State private var heroPreferences = HeroPreferences()
    @State private var shelfPreferences = ShelfPreferences()
    @State private var trailerPreferences = TrailerPreferences()
    @State private var topShelfMode: TopShelfMode = .resume
    /// The rows of Home in their natural order — the basis for
    /// moving, because the setting is empty at first.
    @State private var shelfIDs: [(id: String, name: String)] = []
    @FocusState private var focus: String?
    @Environment(\.settingsEntryRequest) private var entryRequest
    @Environment(\.enterCard) private var enterCard

    var body: some View {
        switch mode {
        case .overview: overview
        case .portals:
            PortalShelfChoice(layers: portalLevels, source: portalDataSource)
                .backWithMenu { mode = .overview }
        case .channels:
            // **The same groups as the sidebar** — they come from
            // ``LivePreferences/ordered(_:)`` and list only the enabled ones.
            ChannelShelfChoice(catalog: channelCatalog, groups: liveGroups)
                .backWithMenu { mode = .overview }
        case .categories:
            ProviderShelfChoice(categories: providerCategories)
                .backWithMenu { mode = .overview }
        case .symbol:
            iconPicker
                .onAppear { focus = "icon-" + icons.current.id }
                .backWithMenu { back(to: "zu-symbol") }
        case .rows:
            shelfOrder
                .onAppear { focus = shelfIDs.first.map { "vis-" + $0.id } }
                .backWithMenu { back(to: "zu-zeilen") }
        case .headerArea:
            heroLibraries
                .onAppear { focus = libraries.first.map { "hero-" + $0.id } }
                .backWithMenu { back(to: "zu-kopfbereich") }
        }
    }

    /// Back to the overview — **and to the row you came from.** Without that,
    /// tvOS would assign the focus by geometry, and the row you just used
    /// would be the one you are sure not to land on.
    private func back(to row: String) {
        mode = .overview
        focus = row
    }

    @ViewBuilder
    private var overview: some View {
        VStack(alignment: .leading, spacing: 40) {
            themePicker
                .preference(key: SettingsFirstEntryKey.self, value: "theme")
                .onChange(of: entryRequest) { _, _ in focus = "theme" }

            VStack(alignment: .leading, spacing: SettingsView.entrySpacing) {
                if icons.isSupported {
                    DisclosureRow(
                        title: "settings.icon",
                        value: Self.word(icons.current.titleKey),
                        card: CardSpec(
                            header: "settings.icon",
                            statement: icons.current.titleKey,
                            explanation: "settings.iconHint",
                            validity: .device),
                        identifier: "zu-symbol",
                        focus: $focus
                    ) {
                        mode = .symbol
                    }
                }
                if !shelfIDs.isEmpty {
                    let state = Self.portion(
                        shelfIDs.count { shelfPreferences.isVisible($0.id) }, from: shelfIDs.count)
                    DisclosureRow(
                        title: "settings.shelfOrder",
                        value: state,
                        card: CardSpec(
                            header: "settings.shelfOrder",
                            statementWording: state,
                            explanation: "settings.shelfOrderHint",
                            validity: .profile),
                        identifier: "zu-zeilen",
                        focus: $focus
                    ) {
                        mode = .rows
                    }
                }
                if libraries.count > 1 {
                    let state = Self.portion(
                        libraries.count { fillsHeroes($0.id) }, from: libraries.count)
                    DisclosureRow(
                        title: "settings.heroLibraries",
                        value: state,
                        card: CardSpec(
                            header: "settings.heroLibraries",
                            statementWording: state,
                            explanation: "settings.heroLibrariesHint",
                            validity: .profile),
                        identifier: "zu-kopfbereich",
                        focus: $focus
                    ) {
                        mode = .headerArea
                    }
                }
            }

            providerShelves

            shelfSourceRows

            trailerAutostart

            topShelfPicker
        }
        // **Recompute when the channel groups arrive** (2026-09-12).
        //
        // Here used to be `.task { await reload() }` — once on appearing. The groups
        // are fetched by ``MainView`` on the side (`loadLiveGroups()`), and they are rarely already there
        // when this screen draws. The shelf list was thus built without them, and
        // "What's on now" was missing from it — while the shelf on Home
        // was there just fine.
        //
        // **The same error as in ``PortalSettings`` the same evening:** a screen
        // that queries a piece of information once and never looks at it again. There
        // it was the address, here it is the groups.
        // **And when the portal levels arrive, too.** The shell fetches both lists
        // on the side; which one is there first is down to chance.
        .task(id: liveGroups + portalLevels.map(\.id)) { await reload() }
    }

    /// What the upper area of the Apple TV Home Screen shows.
    ///
    /// The choice reaches the shared entry via ``TopShelfBridge``; the
    /// extension reads it on the next visit to the Home Screen. Since AP52
    /// ``HomeShelf/reportChange()`` nudges tvOS to fetch the shelf again.
    private var topShelfPicker: some View {
        // **One row instead of four pills, and the choice is on the right** (AP46,
        // owner decision 6): from four values on the card becomes enterable. Pressing
        // the row enters it on the chosen value; there you choose without the
        // screen changing. The header above is gone — it said "Top Shelf" above
        // a row called "Top Shelf"; its sentence is now in the card.
        DisclosureRow(
            title: "settings.topShelf",
            value: Self.wording(topShelfMode),
            card: CardSpec(
                header: "settings.topShelf",
                statement: topShelfMode.titleKey,
                explanation: "settings.topShelfHint",
                pills: TopShelfMode.allCases.map {
                    CardPill(Self.wording($0), chosen: $0 == topShelfMode, identifier: $0.id)
                },
                optionCount: TopShelfMode.allCases.count,
                validity: .profile,
                selection: CardSelection(row: "topshelf") { identifier in
                    guard let mode = TopShelfMode.allCases.first(where: { $0.id == identifier })
                    else { return }
                    topShelfMode = mode
                    TopShelfBridge.updateMode(mode)
                    // **Recomputed, not just relabelled** (2026-09-29): the state
                    // kept the entries of the previous presentation — under "Favourites"
                    // stood what had been started. The shell fetches the CL-Server again
                    // when leaving the app for the new presentation.
                    HomeShelf.writeFromSession()
                }),
            identifier: "topshelf",
            focus: $focus
        ) {
            enterCard(topShelfMode.id)
        }
    }

    /// The name of a Top Shelf choice as finished wording — for the value column and pills.
    private static func wording(_ mode: TopShelfMode) -> String {
        AppLanguageSetting.text(String.LocalizationValue(mode.titleKey))
    }

    // The engine switch used to be here and has been deliberately removed again. It was a
    // debugging tool — the question of which path runs more smoothly in the living room
    // is answered and the answer is in ``PlaybackEngineSelector``.
    // A switch that stays after its question is answered becomes a
    // trap: whoever flips it switches back to the path whose errors are documented.

    /// The app icon of the Home Screen.
    ///
    /// **The tile shows the icon and not its name.** "Arc" says nothing from
    /// three metres away; the picture says everything. It is therefore also considerably
    /// larger than the buttons above it — 240 × 144 is the same 5 : 3 ratio
    /// in which tvOS later draws the icon.
    ///
    /// A change takes time because tvOS asks in between. The pressed button therefore
    /// visibly stays busy instead of switching at once — and does not switch
    /// at all if the prompt is declined.
    private var iconPicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsHeader("settings.icon", hint: "settings.iconHint")

            // **Aligned to the top, not centred** (on-device finding 2026-09-04): "Negative
            // with lettering" needs two lines, and with the centre as axis
            // its tile slipped up out of the row.
            HStack(alignment: .top, spacing: 20) {
                ForEach(AppIconStore.all) { icon in
                    let id = "icon-" + icon.id
                    let isActive = icons.current == icon

                    Button {
                        // **The press is discarded in the body and not at the button**
                        // (AP22, 2026-09-11). Here used to be `.disabled(icons.isSwitching)`,
                        // and because `isSwitching` applies to the whole grid, when switching ALL tiles
                        // dropped out of the focus tree at once: the focus
                        // fell out of the block and ended up somewhere afterwards. A
                        // second press in the same second has no consequence anyway —
                        // ``AppIconStore/choose(_:)`` runs on the main thread.
                        guard !icons.isSwitching else { return }
                        Task { await icons.choose(icon) }
                    } label: {
                        VStack(spacing: 12) {
                            Image(icon.preview)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 240, height: 144)
                                .clipShape(RoundedRectangle(cornerRadius: MetricsBoard.tv.cardRadius))
                                .overlay {
                                    RoundedRectangle(cornerRadius: MetricsBoard.tv.cardRadius)
                                        .strokeBorder(
                                            isActive ? ColorRole.text.color : .clear,
                                            lineWidth: 4
                                        )
                                }
                                // **1.12 and not 1.08** (AP26, 2026-09-11). 1.08 is
                                // exactly the value ``Tokens/Focus`` rejected with "barely visible from
                                // three metres" — and for
                                // the same case: a surface without a border, where the
                                // enlargement carries the highlight **alone**. These
                                // 240 × 144 previews have no parallax and
                                // no line; here 1.08 could not be told apart from
                                // "not focused" from the armchair.
                                .scaleEffect(focus == id ? Tokens.Focus.cardScale : 1)
                                .animation(Tokens.Focus.animation, value: focus)

                            HStack(spacing: 8) {
                                if isActive {
                                    Image(systemName: "checkmark")
                                }
                                Text(appKey: icon.titleKey)
                            }
                            .font(TypeLevel.footer.font)
                            .foregroundStyle(
                                focus == id ? ColorRole.text.color : ColorRole.textMatt.color
                            )
                        }
                        .opacity(icons.isSwitching && !isActive ? 0.5 : 1)
                    }
                    .bareFocusableButton()
                    .focused($focus, equals: id)
                    .info(appKey: icon.titleKey, .chosen(isActive))
                }
            }
            .padding(.top, 24)
        }
    }

    /// The colour scheme of the app — **three values, so cycle through** (decision 6).
    ///
    /// **The preview is the screen itself.** Until 2026-09-25 every pill carried three
    /// colour dots so you could see what a scheme looks like before switching. A press
    /// now recolours the whole surface — including the row you are standing on —, and that
    /// shows more than three dots. Whoever keeps pressing sees the next one.
    private var themePicker: some View {
        ToggleRow(
            title: "settings.theme",
            options: Theme.all.map { .init(identifier: $0.id, wording: Self.word($0.nameKey)) },
            chosen: themes.current.id,
            explanation: "settings.themeHint",
            validity: .profile,
            identifier: "theme",
            focus: $focus
        ) { identifier in
            guard let theme = Theme.all.first(where: { $0.id == identifier }) else { return }
            themes.choose(theme)
        }
    }

    /// A language key as finished wording — for the value column and cycling through.
    private static func word(_ key: String) -> String {
        AppLanguageSetting.text(String.LocalizationValue(key))
    }

    /// "7 of 9" — the count on a row behind which a list sits.
    private static func portion(_ number: Int, from total: Int) -> String {
        AppLanguageSetting.text("settings.homeShownOf \(number) \(total)")
    }

    /// Whether the trailer in the information column starts on its own.
    ///
    /// Sits under "Appearance" and not with playback, because it concerns the behaviour
    /// when browsing a library and not that of a running film.
    private var trailerAutostart: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsHeader("settings.trailerAutostart", hint: "settings.trailerAutostartHint")

            // A checkmark instead of a switch, for the same reason as with the
            // libraries for the header area: from three metres away a
            // switch cannot be recognised as on or off — ``SwitchRow``
            // therefore draws it the same way.
            SwitchRow(
                title: "settings.trailerAutostartToggle",
                on: Binding(
                    get: { trailerPreferences.autostarts },
                    set: { fresh in
                        trailerPreferences.autostarts = fresh
                        trailerPreferences.save(to: ProfileStore.playback)
                    }),
                card: .toggle(
                    header: "settings.trailerAutostartToggle",
                    on: trailerPreferences.autostarts,
                    explanation: "settings.trailerAutostartHint",
                    validity: .profile),
                identifier: "trailer",
                focus: $focus)
        }
    }

    /// Order and visibility of the rows on Home.
    private var shelfOrder: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsHeader("settings.shelfOrder", hint: "settings.shelfOrderHint")

            VStack(spacing: 0) {
                ForEach(Array(shelfIDs.enumerated()), id: \.element.id) { index, shelf in
                    shelfRow(shelf, index: index)
                }
            }
        }
    }

    private func shelfRow(_ shelf: (id: String, name: String), index: Int) -> some View {
        let visible = shelfPreferences.isVisible(shelf.id)

        return HStack(spacing: 18) {
            Text(verbatim: shelf.name)
                .font(TypeLevel.footer.font)
                .foregroundStyle(visible ? ColorRole.text.color : ColorRole.textQuiet.color)
                .frame(maxWidth: 420, alignment: .leading)
                .lineLimit(1)

            Spacer(minLength: 0)

            // By one position rather than to a position: on a TV you move
            // with two buttons. The arrows at the edge are greyed out instead of missing —
            // a row in which a button disappears jumps when paging.
            smallButton(
                Glyph.up.name, id: "up-" + shelf.id, enabled: index > 0,
                label: "settings.live.a11y.moveUp"
            ) {
                shelfPreferences.move(shelf.id, up: true, within: shelfIDs.map(\.id))
                shelfPreferences.save(to: FileStore(), forItem: ProfilePointer.active)
                applyOrder()
            }
            smallButton(
                Glyph.down.name, id: "down-" + shelf.id,
                enabled: index < shelfIDs.count - 1,
                label: "settings.live.a11y.moveDown"
            ) {
                shelfPreferences.move(shelf.id, up: false, within: shelfIDs.map(\.id))
                shelfPreferences.save(to: FileStore(), forItem: ProfilePointer.active)
                applyOrder()
            }

            smallButton(
                visible ? Glyph.isVisible.name : Glyph.hidden.name,
                id: "vis-" + shelf.id, enabled: true,
                label: "settings.live.a11y.visibility",
                state: visible ? "settings.live.a11y.visible" : "settings.live.a11y.hidden"
            ) {
                shelfPreferences.setVisible(!visible, for: shelf.id, within: shelfIDs.map(\.id))
                shelfPreferences.save(to: FileStore(), forItem: ProfilePointer.active)
            }
        }
        .padding(.vertical, 14)
        .frame(maxWidth: 900)
        .overlay(alignment: .bottom) {
            Rectangle().fill(ColorRole.lineQuiet.color).frame(height: 1)
                // As in the channel list: the divider must not catch any focus.
                // Here every row has three buttons — two for moving, one
                // for hiding —, and the order of the rows can only be
                // changed if the focus gets through from row to row.
                .allowsHitTesting(false)
        }
    }

    /// A small button in a shelf row.
    ///
    /// **`enabled` greys the look and the body, not the focus tree** (AP22,
    /// 2026-09-11). Here used to be `.disabled(!enabled)` — and with that the "up" arrow in
    /// the first row and "down" in the last was **not focusable**. The comment
    /// three screens further up expressly promises the opposite: *"The arrows
    /// at the edge are greyed out instead of missing — a row in which a button
    /// disappears jumps when paging."* A button that tvOS removes from the focus tree
    /// **is** gone; the row jumped, just without a visible gap.
    /// - Parameters:
    ///   - beschriftung: What this button **does** — as a language key.
    ///   - zustand: What currently **applies**, if the button carries one.
    ///
    /// See ``LiveSettings/toggleButton(symbol:id:label:state:action:)`` — all
    /// three buttons per Home row come out of here, so one parameter covers them
    /// all (AP26, 2026-09-11).
    private func smallButton(
        _ symbol: String,
        id: String,
        enabled: Bool,
        label caption: String,
        state: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            guard enabled else { return }
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 22))
                .foregroundStyle(
                    focus == id
                        ? ColorRole.reason.color
                        : (enabled ? ColorRole.textMatt.color : ColorRole.textQuiet.color.opacity(0.4))
                )
                .settingsSurface(.character, isFocused: focus == id)
        }
        .bareFocusableButton()
        .focused($focus, equals: id)
        // **Highlight by element kind** (AP26, 2026-09-11): in 4489 lines of
        // `Settings/` there was **not a single** `focusHighlight`, while 15 views
        // under `Features/` carry it — the settings looked different from the rest of
        // the app as the only part. A small button gets the small factor; the large
        // tiles above get the large one.
        .focusHighlight(focus == id, scale: Tokens.Focus.buttonScale)
        .info(appKey: caption, .key(state))
    }

    /// Whether this library fills the header area — **the profile's choice**, without it the
    /// device's old list (check finding A-S8, see ``Core/ShelfPreferences/heroShelves``).
    private func fillsHeroes(_ id: String) -> Bool {
        shelfPreferences.fillsHeroes(id, device: heroPreferences)
    }

    /// Brings the displayed list into the stored order.
    private func applyOrder() {
        let ordered = shelfPreferences.order.filter { id in shelfIDs.contains { $0.id == id } }
        let rest = shelfIDs.filter { entry in !ordered.contains(entry.id) }
        shelfIDs = ordered.compactMap { id in shelfIDs.first { $0.id == id } } + rest
    }

    private func reload() async {
        heroPreferences = HeroPreferences.load(from: ProfileStore.playback)
        shelfPreferences = ShelfPreferences.load(from: FileStore(), forItem: ProfilePointer.active)
        trailerPreferences = TrailerPreferences.load(from: ProfileStore.playback)
        topShelfMode = TopShelfBridge.mode()

        // Without a media server there are no libraries for the header area — and
        // so nothing to choose.
        let all = (try? await source?.libraries()) ?? []
        libraries = all.filter { HomeModel.heroEligible.contains($0.kind) }

        // **The list comes from the ``ShelfPlan`` and not from the libraries**
        // (2026-09-12).
        //
        // Here used to be: "Continue Watching" plus `all` without music and Live. That was correct
        // in itself and drifted apart from what Home really builds — the
        // client's finding on the device:
        //
        // * **"From the portals" and "Collections" were missing.** Two rows on
        //   Home that could be neither moved nor switched off.
        // * **Every portal level was listed individually** — a dozen entry points —, and a
        //   checkmark there did nothing: Home combines them into *one* shelf.
        //
        // The plan is now the single truth for both sides, just like on the phone.
        //
        // **Collections and channel list are asked for and not assumed.** Offering a row
        // that does not exist is the same mistake in the other direction; a
        // query that finds nothing costs nothing here, because this screen waits
        // for the libraries anyway.
        let hasCollections = !((try? await source?.collections()) ?? []).isEmpty
        let hasChannelList = !liveGroups.isEmpty
        // **The portal levels belong in it**, otherwise "From the portals" is missing from the
        // list — the same error as with the folder picker, just one row higher.
        // **And the provider sections** (2026-09-13): without them the shelves of the
        // catalog were missing from this list while Home showed them — two rows there
        // that could be neither moved nor switched off here.
        shelfIDs = ShelfPlan.shelves(
            libraries: all + providerCategories + portalLevels, collections: hasCollections,
            channelList: hasChannelList, portalFolders: shelfPreferences.portalFolders,
            perProvider: shelfPreferences.shelvesPerProvider,
            categories: shelfPreferences.providerCategories
        ).map { ($0.id, $0.name) }
        applyOrder()

    }

    /// **How many provider categories get a shelf** (2026-09-12).
    ///
    /// **The finding:** *"8 categories from VOD are shown there … normally
    /// only 2 items (one from film and one from series) are shown."* ``ShelfRule``
    /// capped at eight per origin — the number dates from the time when only the
    /// media server filled shelves.
    ///
    /// **The media server is not up for choice here**, and the sentence below says so:
    /// its libraries were created and named by the viewer; the categories
    /// of a provider are the provider's own sorting.
    ///
    /// **Zero is allowed.** "None" is a valid answer for someone who uses the
    /// catalog only via search — and it is more honest than a minimum value of
    /// one, which pretends something must be there.
    private var providerShelves: some View {
        let tier = shelfPreferences.shelvesPerProvider
        return DisclosureRow(
            title: "settings.homeVodShelves",
            value: "\(tier)",
            card: CardSpec(
                header: "settings.homeVodShelves",
                statementWording: "\(tier)",
                explanation: "settings.homeVodShelvesHint",
                pills: ShelfPreferences.providerLevels.map {
                    CardPill("\($0)", chosen: $0 == tier, identifier: "\($0)")
                },
                optionCount: ShelfPreferences.providerLevels.count,
                validity: .profile,
                selection: CardSelection(row: "vod") { identifier in
                    guard let fresh = Int(identifier) else { return }
                    shelfPreferences.setShelvesPerProvider(fresh)
                    shelfPreferences.save(to: FileStore(), forItem: ProfilePointer.active)
                }),
            identifier: "vod",
            focus: $focus
        ) {
            enterCard("\(tier)")
        }
    }

    /// The two rows behind which the pickers sit.
    ///
    /// **With a count**, because a row without a number claims nothing about what sits behind
    /// it — the same rule as at the channel flap of the phone.
    @ViewBuilder
    private var shelfSourceRows: some View {
        VStack(alignment: .leading, spacing: SettingsView.entrySpacing) {
            DisclosureRow(
                title: "settings.section.homePortals",
                value:
                    "\(shelfPreferences.portalFolders.count)/\(ShelfPreferences.maximumPortalFolders)",
                card: CardSpec(
                    header: "settings.section.homePortals",
                    statementWording:
                        "\(shelfPreferences.portalFolders.count)/\(ShelfPreferences.maximumPortalFolders)",
                    validity: .profile),
                identifier: "zu-portale",
                focus: $focus
            ) {
                mode = .portals
            }
            DisclosureRow(
                title: "settings.section.homeChannels",
                value: "\(shelfPreferences.liveChannel.count)",
                card: CardSpec(
                    header: "settings.section.homeChannels",
                    statementWording: "\(shelfPreferences.liveChannel.count)",
                    explanation: "settings.homeChannelsHint2",
                    validity: .profile),
                identifier: "zu-sender",
                focus: $focus
            ) {
                mode = .channels
            }
            // **Empty means "no provider set up"**, and then the row does not
            // appear — gone instead of greyed out.
            if !providerCategories.isEmpty {
                let value =
                    shelfPreferences.providerCategories.isEmpty
                    ? "\(shelfPreferences.shelvesPerProvider)"
                    : "\(shelfPreferences.providerCategories.count)"
                DisclosureRow(
                    title: "settings.section.homeCategories",
                    value: value,
                    card: CardSpec(
                        header: "settings.section.homeCategories", statementWording: value,
                        validity: .profile),
                    identifier: "zu-kategorien",
                    focus: $focus
                ) {
                    mode = .categories
                }
            }
        }
    }

    private var heroLibraries: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsHeader("settings.heroLibraries", hint: "settings.heroLibrariesHint")

            HStack(spacing: 14) {
                ForEach(libraries) { entry in
                    let allowed = fillsHeroes(entry.id)
                    let id = "hero-" + entry.id

                    Button {
                        shelfPreferences.fillHeroes(
                            entry.id, !allowed, from: libraries.map(\.id), device: heroPreferences)
                        shelfPreferences.save(to: FileStore(), forItem: ProfilePointer.active)
                    } label: {
                        HStack(spacing: 10) {
                            // A checkmark instead of a switch: from three metres
                            // away a switch cannot be recognised as on or
                            // off.
                            Image(systemName: allowed ? "checkmark.circle.fill" : "circle")
                            Text(verbatim: entry.name)
                        }
                        .font(TypeLevel.footer.font)
                        .settingsFont(isFocused: focus == id, muted: !allowed)
                        .settingsSurface(
                            .pill, isFocused: focus == id,
                            reason: allowed ? ColorRole.surface.color : ColorRole.surfaceHigh.color)
                    }
                    .bareFocusableButton()
                    .focused($focus, equals: id)
                    .info(name: entry.name, .on(allowed))
                }
            }
        }
    }
}

// MARK: - Storage

/// Usage of the cache, the ability to empty it — and the
/// match with the server.
struct StorageSettings: View {

    let source: JellyfinSource?

    @State private var used = 0
    @State private var limit = 0
    /// Whether the last match is done — the button should say that something
    /// happened, otherwise you press it three times.
    @State private var synced = false
    @FocusState private var focus: String?
    @Environment(\.settingsEntryRequest) private var entryRequest

    /// What else is on the disk — see ``TransientCache``.
    @State private var items: [TransientCache.LineItem] = []
    /// How much the last cleanup freed. `nil` means: not yet
    /// pressed — a zero would be a different statement.
    @State private var freedBytes: Int64?
    @State private var timeOffset: Int64 = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            HStack(spacing: 30) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: used.formatted(.byteCount(style: .file)))
                        .font(TypeLevel.title.font)
                        .foregroundStyle(ColorRole.text.color)
                    if limit > 0 {
                        Text(app: "settings.storageOf \(limit.formatted(.byteCount(style: .file)))")
                            .font(TypeLevel.lowercased.font)
                            .foregroundStyle(ColorRole.textMatt.color)
                    }
                }

                Spacer(minLength: 20)

                // **The button that had long been promised in a comment.**
                // The lists last an hour and even survive a restart as a snapshot
                // — without this path, freshly imported material would stay invisible for up to an hour, and nobody
                // would know why. Reloading the open views triggers the
                // source itself; see `forgetCachedLists`.
                FormButton(
                    title: "settings.syncNow",
                    statusTitle: "settings.syncDone",
                    state: synced ? .done : .ready,
                    rank: .main,
                    identifier: "sync",
                    focus: $focus
                ) {
                    synced = false
                    Task {
                        await source?.forgetCachedLists()
                        synced = true
                    }
                }
                // See "Ratings": the note sits at the first target, not at the header.
                .preference(key: SettingsFirstEntryKey.self, value: "sync")
                .onChange(of: entryRequest) { _, _ in focus = "sync" }

                FormButton(
                    title: "settings.clearCache", rank: .beside, identifier: "clear",
                    focus: $focus
                ) {
                    Task {
                        await ImageCache.shared.clear()
                        used = await ImageCache.shared.diskUsage()
                        timeOffset = TimeShift.taken()
                    }
                }
            }
            .frame(maxWidth: 900, alignment: .leading)

            // The disk ring for time-shifted TV (AP9) — occupied
            // only while a channel is playing; app launch clears it.
            Text(
                app:
                    "player.timeShiftUsage \(timeOffset.formatted(.byteCount(style: .file))) \(TimeShift.capacity(.tv).formatted(.byteCount(style: .file)))"
            )
            .font(TypeLevel.lowercased.font)
            .foregroundStyle(ColorRole.textMatt.color)
            .padding(.top, 14)

            // What the match does — otherwise you cannot tell whether it empties the
            // images (the other button does that) or the lists.
            Text(app: "settings.syncNowHint")
                .font(TypeLevel.lowercased.font)
                .foregroundStyle(ColorRole.textQuiet.color)
                .padding(.top, 22)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 900, alignment: .leading)

            lineup
        }
        // **Row by row, not vertically** (user finding 2026-09-04: "from 'Empty'
        // I cannot get to 'Clean up cache' — it wants to have something exactly
        // underneath"). The buttons sit at the top right, the
        // cleanup button at the bottom left; tvOS finds nothing by geometry.
        // At the root of the view, not at the header: only here does the command arrive.
        .onMoveCommand { direction in
            switch direction {
            case .down where focus == "sync" || focus == "clear":
                focus = "cache-clear"
            case .up where focus == "cache-clear":
                focus = "clear"
            default:
                break
            }
        }
        .task {
            used = await ImageCache.shared.diskUsage()
            limit = await ImageCache.shared.diskLimit()
            items = TransientCache.catalog()
        }
    }

    /// What else is on the disk besides the images.
    ///
    /// **The number above answered only one of several questions** (AP18,
    /// 2026-09-02): it names the images. Next to them sit the channel database (15 MB on
    /// the test provider), the episode index, the list digests and the
    /// diagnostic traces — together easily several times that, and none of it was
    /// visible. On a TV with 32 gigabytes this is not a
    /// side issue.
    @ViewBuilder
    private var lineup: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(items) { entry in
                    HStack(spacing: 16) {
                        Text(appKey: entry.nameKey)
                            .font(TypeLevel.footer.font)
                            .foregroundStyle(ColorRole.textMatt.color)
                        Spacer(minLength: 20)
                        Text(verbatim: TransientCache.readable(entry.bytes))
                            .font(TypeLevel.footer.font)
                            .monospacedDigit()
                            .foregroundStyle(ColorRole.text.color)
                        // **What stays says so here and not only
                        // afterwards.** Whoever cleans up and then sees the same number
                        // considers the button broken.
                        Text(app: entry.isCleared ? "cache.cleared" : "cache.kept")
                            .font(TypeLevel.lowercased.font)
                            .foregroundStyle(ColorRole.textQuiet.color)
                            .frame(width: 190, alignment: .leading)
                    }
                }

                HStack(spacing: 20) {
                    FormButton(
                        title: "cache.clearNow", rank: .main, identifier: "cache-clear",
                        focus: $focus
                    ) {
                        let unrestricted = TransientCache.cleanUp()
                        freedBytes = unrestricted
                        items = TransientCache.catalog()
                    }

                    if let freedBytes {
                        Text(app: "cache.freed \(TransientCache.readable(freedBytes))")
                            .font(TypeLevel.lowercased.font)
                            .foregroundStyle(ColorRole.success.color)
                    }
                }
                .padding(.top, 8)

                // Nothing is lost — and that belongs here, otherwise nobody
                // presses.
                Text(app: "cache.clearHint")
                    .font(TypeLevel.lowercased.font)
                    .foregroundStyle(ColorRole.textQuiet.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 900, alignment: .leading)
            .padding(.top, 30)
        }
    }
}

// MARK: - Media server

/// Which servers are trusted — and the way out.
///
/// **The profile list was up here until 2026-09-25** and moved into an area of its own
/// (``ProfileSettings``, owner decision 1): a person is not a source.
/// With it went the profile model and the PIN sheet, which only its actions needed.
struct AccountSettings: View {

    /// Whether a media server access exists.
    ///
    /// **Without it there is nothing to sign out of** (on-device test 2026-09-27): after signing out the area
    /// kept showing "Sign out" and no way back — the media server could
    /// only be reached via the profiles. Now it shows what is missing, and the button
    /// for it.
    var signedIn = true
    let onSignOut: () -> Void
    /// Create a media server access — the same path as "Add access" for the
    /// profiles.
    var onAddServer: () -> Void = {}

    @FocusState private var focus: String?
    @Environment(\.settingsEntryRequest) private var entryRequest
    /// Whether the confirmation prompt before signing out is open.
    @State private var asksToSignOut = false

    /// The store of the trusted certificates. As state and not re-read at every
    /// body: it lives in the Keychain.
    private let trust = CertificateTrustStore()
    /// What is stored there, for display — sorted by server so the list
    /// does not jump when revoking.
    @State private var certificateHosts: [(host: String, fingerprint: CertificateFingerprint)] = []

    var body: some View {
        if signedIn { signedInContent } else { withoutAccess }
    }

    /// No access: the sentence and the way there.
    private var withoutAccess: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(app: "settings.account.none")
                .font(TypeLevel.footer.font)
                .foregroundStyle(ColorRole.textMatt.color)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 900, alignment: .leading)
            FormButton(
                title: "profiles.addAccess", rank: .main, identifier: "addServer", focus: $focus,
                action: onAddServer)
        }
        .preference(key: SettingsFirstEntryKey.self, value: "addServer")
        .onChange(of: entryRequest) { _, _ in focus = "addServer" }
    }

    private var signedInContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            certificates

            // **Ask first, then sign out.** A single press used to throw the
            // access token away immediately — and on the remote a
            // mis-press is frequent, the selection surface is the entire touchpad. The way
            // back is the most expensive on the platform: server address, name and
            // password on the TV keyboard. The red text warns, the confirmation prompt
            // prevents; with it the mis-press costs nothing any more.
            FormButton(
                title: "common.signOut",
                rank: .main,
                warning: true,
                identifier: "signout",
                focus: $focus
            ) {
                asksToSignOut = true
            }
            // See "Ratings": the note sits at the first target, not at the header.
            //
            // **And "Sign out" is the first target here although it is a warning one** — the
            // confirmation prompt before it is the reason (``ActionRow``: warning never means first target,
            // but this button opens a dialog and removes nothing).
            .preference(key: SettingsFirstEntryKey.self, value: "signout")
            .onChange(of: entryRequest) { _, _ in focus = "signout" }
            .confirmationDialog(
                Text(app: "settings.signOutConfirm"),
                isPresented: $asksToSignOut,
                // The title carries the actual information — what a sign-out
                // costs. Without it, two buttons would stand there without a question.
                titleVisibility: .visible
            ) {
                // The same label as the button before it: the confirmation prompt should
                // confirm, not rename.
                Button(role: .destructive, action: onSignOut) {
                    Text(app: "common.signOut")
                }
                Button(role: .cancel) {
                } label: {
                    Text(app: "common.cancel")
                }
            }

            // What signing out means: the access token is discarded, the
            // stored channel lists remain. Without this sentence you do not know
            // whether you have to enter everything again.
            Text(app: "settings.signOutHint")
                .font(TypeLevel.lowercased.font)
                .foregroundStyle(ColorRole.textQuiet.color)
                .padding(.top, 22)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 900, alignment: .leading)
        }
    }

    /// **Trusted certificates — view and revoke** (roadmap AP11).
    ///
    /// **Why this gets a row of its own in the account:** whoever has once agreed to a self-
    /// issued certificate has made a
    /// security decision that afterwards keeps applying invisibly —
    /// the same procedure as with SSH (see ``CertificateTrustStore``). Without
    /// this list it can no longer be inspected and certainly not
    /// taken back; you would have to delete the app.
    ///
    /// What is shown is the server and the **start** of the fingerprint: it is enough
    /// for recognising it, and the full line could not be compared from three metres
    /// anyway.
    @ViewBuilder
    private var certificates: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(app: "settings.certificates")
                .font(TypeLevel.footer.font)
                .foregroundStyle(ColorRole.textMatt.color)

            if certificateHosts.isEmpty {
                Text(app: "settings.certificatesNone")
                    .font(TypeLevel.lowercased.font)
                    .foregroundStyle(ColorRole.textQuiet.color)
            } else {
                ForEach(certificateHosts, id: \.host) { entry in
                    HStack(spacing: 18) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: entry.host)
                                .font(TypeLevel.footer.font)
                                .foregroundStyle(ColorRole.text.color)
                            Text(verbatim: entry.fingerprint.short)
                                .font(TypeLevel.lowercased.font)
                                .foregroundStyle(ColorRole.textQuiet.color)
                        }
                        .frame(width: 420, alignment: .leading)

                        Button {
                            try? trust.forget(entry.host)
                            loadCertificates()
                        } label: {
                            Text(app: "settings.certificateForget")
                                .font(TypeLevel.lowercased.font)
                                .settingsFont(
                                    isFocused: focus == "cert-" + entry.host, warning: true
                                )
                                .settingsSurface(
                                    .pill, isFocused: focus == "cert-" + entry.host)
                        }
                        .bareFocusableButton()
                        .focused($focus, equals: "cert-" + entry.host)
                    }
                }
            }

            Text(app: "settings.certificatesHint")
                .font(TypeLevel.lowercased.font)
                .foregroundStyle(ColorRole.textQuiet.color)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 900, alignment: .leading)
        }
        .padding(.bottom, 34)
        .task { loadCertificates() }
    }

    /// Sorted by server so the list does not jump when revoking.
    private func loadCertificates() {
        certificateHosts =
            trust.trusted()
            .map { (host: $0.key, fingerprint: $0.value) }
            .sorted { $0.host < $1.host }
    }

}
