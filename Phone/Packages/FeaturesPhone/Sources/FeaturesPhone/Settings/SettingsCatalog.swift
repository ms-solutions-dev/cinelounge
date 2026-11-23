import Flows
import Foundation

/// Every setting as an **entry**, so that it can be searched.
///
/// **The market finding of 2026-09-07, and it is the only one of its kind:** Of all examined
/// apps — Swiftfin, Streamyfin, Infuse, Plex, OTT Navigator, TiviMate — **none** has a search
/// across its settings. In iOS itself it has for years been the first thing at the top;
/// whoever looks for "Subtitles" types it and is there.
///
/// **Why this matters more here than elsewhere:** The area has eleven topics on three
/// levels, and the most common case is not "I know where it is" but "I know what it is
/// called". Whoever looks for the subtitle size currently has to know that it sits under
/// *Playback* and not under *Appearance* — both would be a defensible filing, and that is
/// exactly why one guesses wrong.
///
/// ## The search runs over the text and not over the key
///
/// Nobody finds `settings.playback.subtitles`. The search runs over what **stands** on the
/// screen, in the language it stands in — that is why every entry goes through
/// ``SettingsModel/text(_:)`` and not through a comparison of key names.
///
/// ## Three sources per entry, and none of them needs translating anew
///
/// * **The title** — what stands in the row.
/// * **The ``keywords``** — further keys whose text is searched as well: the explanatory
///   sentence under a row, the heading of its section. The sentence under "Show portals"
///   mentions "tab", "shelf" and "hits"; whoever searches for those is looking for exactly
///   this setting. **That is why this catalog gets by with almost no new language keys:**
///   the synonyms have long been there, they were simply never read.
/// * **The ``terms``** — literal and untranslated. "M3U", "Xtream", "EPG", "PIN",
///   "TMDb" are called that in all three languages; keeping them as a catalog entry would mean
///   translating the same word three times. **Only** such words go here, and the rule is
///   strict: what could be translated does not belong here.
///
/// ## What the catalog expressly does NOT do
///
/// **It jumps to the screen and not to the row.** Highlighting a setting after jumping to it
/// requires an anchor on every row; there is none, and claiming one would be worse than its
/// absence. Instead the hit row says in the value column **where** the setting lies — the
/// same information the root carries everywhere.
///
/// ## And it cannot silently go stale
///
/// A hand-maintained catalog drifts apart on the first day someone adds a setting — just like
/// the ``SwipeMark`` on 2026-09-07. `scripts/catalog.py` therefore checks on every `check.sh`:
/// **Every ``SwitchRow`` and every ``DisclosureRow`` in the settings area is listed here —
/// or, with a reason, in the script's exception list.**
public struct CatalogEntry: Identifiable, Sendable, Equatable {

    /// The key of the title — at the same time the identifier.
    public let title: String

    /// Which area the entry is in. Shown in the value column of the hit.
    public let area: SettingsModel.Area

    /// Where the jump goes. **Not always the area's screen:** Privacy and Licenses sit under
    /// "About" but have views of their own.
    public let view: ViewID

    /// Further keys whose **text** is searched as well — footers and section headers.
    public var keywords: [String] = []

    /// Words that are called the same in every language.
    public var terms: [String] = []

    public var id: String { title }
}

/// The catalog and the search over it.
public enum SettingsCatalog {

    /// **Ordered by area and not alphabetically.** Whoever reads the file looks for the entries
    /// of one screen together; whoever searches gets them sorted anyway.
    /// **Filtered in one place and not in both lists** (2026-09-07, ROADMAP A1).
    ///
    /// The first attempt filtered only the derived ``sections`` — and the check found the hole
    /// right away: ``rows`` contains three **hand-written** portal entries that still pointed
    /// to ``ViewID/portalSettings``. A store version without portals would thus
    /// have had a search that leads to a screen that does not exist.
    ///
    /// The rule therefore sits **behind** the union: what holds for one list holds for the other
    /// — and for the third that someone adds later.
    public static var all: [CatalogEntry] {
        let possible = Set(SettingsModel.Area.available)
        return (sections + rows).filter { possible.contains($0.area) }
    }

    /// The eleven areas themselves — **they are hits too.** Typing "Diagnostics" and finding
    /// nothing, because only the rows *in* Diagnostics are in the catalog, would be the wrong
    /// half.
    /// **Computed and not held** (2026-09-07, ROADMAP A1). A `let` would be frozen at first access;
    /// but the build variant decides whether the portals exist, and a check flips it. A frozen
    /// catalog would then carry an area that the root no longer shows — and the search would lead
    /// to a screen that does not exist in this version.
    private static var sections: [CatalogEntry] {
        SettingsModel.Area.available.map {
            CatalogEntry(
                title: $0.titleKey, area: $0, view: $0.view,
                keywords: [$0.group.titleKey])
        }
    }

    private static let rows: [CatalogEntry] = [
        // MARK: Senderlisten
        .init(
            title: "settings.addPlaylist", area: .channelLists, view: .channelLists,
            keywords: ["settings.lists.empty"], terms: ["M3U", "Xtream", "IPTV"]),
        // **Both lead to the list of lists and not into the edit form**
        // (2026-09-07, reported on the device: an empty screen). ``ViewID/editChannelList``
        // only draws something if **a particular list** was chosen beforehand
        // (`model.toEdit`); none is chosen via search, and the screen stayed
        // empty. A jump target that needs a payload is none — `scripts/catalog.py`
        // has rejected such targets since the same day.
        .init(
            title: "settings.lists.access", area: .channelLists,
            view: .channelLists, keywords: ["settings.lists.passKeepText"],
            terms: ["Xtream"]),
        .init(
            title: "settings.lists.guide", area: .channelLists,
            view: .channelLists, keywords: ["settings.lists.guideText"],
            terms: ["EPG", "XMLTV"]),

        // MARK: Portale
        .init(
            title: "settings.portals.enabled", area: .portals,
            view: .portalSettings,
            keywords: ["settings.portals.enabled.footnote"]),
        .init(
            title: "settings.portals.bridge", area: .portals, view: .portalSettings,
            keywords: ["settings.portals.bridge.footnote"]),
        .init(
            title: "settings.portals.shared", area: .portals, view: .portalSettings,
            keywords: ["settings.portals.shared.footnote"]),

        // MARK: Live
        .init(
            title: "settings.liveVisible", area: .live, view: .liveSettings,
            keywords: ["settings.live.area.footnote"]),
        .init(
            title: "settings.liveBrowseToggle", area: .live, view: .liveSettings,
            keywords: ["live.settings.browseFootnote"]),
        .init(
            title: "settings.sportFilters", area: .live, view: .liveSettings,
            keywords: ["settings.live.sports.footnote"]),
        .init(
            title: "settings.sportSync", area: .live, view: .liveSettings,
            keywords: ["live.settings.syncFootnote"]),
        .init(
            title: "settings.live.groups.manage", area: .live, view: .groups,
            keywords: ["settings.liveGroupsHint"]),

        // MARK: Wiedergabe
        .init(
            title: "settings.section.subtitles", area: .playback, view: .playback,
            keywords: ["settings.subtitleSize", "settings.playback.when"]),
        .init(
            title: "settings.animeOriginal", area: .playback,
            view: .playback, keywords: ["settings.playback.animeOriginalText"]),
        .init(
            title: "settings.plainSubtitlesToggle", area: .playback,
            view: .playback, keywords: ["settings.playback.plainSubtitlesText"],
            terms: ["ASS", "SSA"]),
        // **The binge package** (AP85, 2026-11-09).
        .init(
            title: "settings.skipIntroToggle", area: .playback,
            view: .playback, keywords: ["settings.skipIntroHint", "settings.binge"]),
        .init(
            title: "settings.spoilerToggle", area: .playback,
            view: .playback, keywords: ["settings.spoilerHint", "settings.binge"]),
        .init(
            title: "settings.stillWatchingToggle", area: .playback,
            view: .playback, keywords: ["settings.stillWatchingHint", "settings.binge"]),

        // MARK: Bewertungen
        .init(
            title: "settings.ratings.tmdb", area: .ratings,
            view: .ratingsSettings, keywords: ["settings.ratings.tmdbText"],
            terms: ["TMDb", "TMDB"]),
        .init(
            title: "settings.ratings.omdb", area: .ratings,
            view: .ratingsSettings, keywords: ["settings.ratings.omdbText"],
            terms: ["OMDb", "OMDB", "IMDb", "Rotten Tomatoes", "Metacritic"]),
        .init(
            title: "settings.ratings.mal", area: .ratings,
            view: .ratingsSettings, keywords: ["settings.ratings.malText"],
            terms: ["MAL", "MyAnimeList", "Anime"]),

        // MARK: Darstellung
        .init(
            title: "settings.language", area: .appearance, view: .appearance,
            keywords: ["settings.look.systemLanguage"]),
        .init(title: "settings.theme", area: .appearance, view: .appearance),
        .init(
            title: "settings.icon", area: .appearance, view: .appearance,
            keywords: ["settings.look.icon.footnote"]),
        .init(
            title: "settings.look.shelves", area: .appearance, view: .arrangeShelves,
            keywords: ["settings.look.footnote"]),

        // MARK: Kindersicherung
        .init(
            title: "childLock.deviceLock", area: .parentalControls, view: .parentalControls,
            keywords: ["settings.kindersicherung"], terms: ["PIN"]),
        .init(
            title: "childLock.ratings.row", area: .parentalControls,
            view: .parentalControls, terms: ["FSK", "USK"]),
        .init(
            title: "childLock.ratings.blockUnknown", area: .parentalControls,
            view: .parentalControls),
        .init(
            title: "childLock.adult.show", area: .parentalControls,
            view: .parentalControls, keywords: ["childLock.adult"]),
        .init(
            title: "childLock.adult.hideUnmarked", area: .parentalControls,
            view: .parentalControls, keywords: ["childLock.adult"]),
        .init(title: "childLock.tabs", area: .parentalControls, view: .parentalControls),

        // MARK: Storage
        // **The row sits in Storage and leads into Downloads** (2026-09-12). As the
        // ``ProbeScreen`` it therefore says `.storage`: that is where it can be found, and the search
        // should lead to where the sought row lies — not to where its press
        // ends up. Whoever searches for "delete" means this row and not the tab.
        .init(
            title: "storage.manage", area: .storage, view: .storage,
            keywords: ["storage.videos", "storage.manageWhy", "stock.title"]),
        .init(
            title: "storage.images", area: .storage, view: .storage,
            keywords: ["storage.clean", "storage.imagesText"]),
        // **Whoever searches for "downloads" lands here** — and that is the reason for the
        // keywords: the sync is called "Sync", but people search for what it
        // concerns.
        .init(
            title: "storage.reconcile", area: .storage, view: .storage,
            keywords: ["storage.stock", "storage.reconcileWhy"]),

        // MARK: Diagnose
        .init(
            title: "settings.diagnostics.id", area: .diagnose, view: .diagnose,
            keywords: ["settings.diagnostics.idLabel"]),
        .init(
            title: "settings.diagnostics.log.open", area: .diagnose, view: .log,
            keywords: ["settings.diagnostics.log"]),
        .init(
            title: "state.review.open", area: .diagnose, view: .diagnose),
        .init(
            title: "settings.diagnostics.verbose", area: .diagnose, view: .diagnose,
            keywords: ["settings.diagnostics.verboseText"]),

        // MARK: Konto
        .init(
            title: "settings.account.accounts", area: .account, view: .accounts,
            keywords: ["settings.account.footnote"]),
        .init(
            title: "accounts.certificates", area: .account, view: .certificates,
            terms: ["HTTPS", "SSL", "TLS"]),
        .init(
            title: "settings.handover.title", area: .account, view: .handoff,
            keywords: ["settings.handover.text", "handover.title"],
            terms: ["QR", "Apple TV", "tvOS"]),
        .init(
            title: "remote.title", area: .account, view: .remote,
            keywords: ["remote.typeOnTV", "remote.foundTVs"],
            terms: ["Apple TV", "tvOS"]),
        .init(title: "settings.account.storage", area: .account, view: .storage),
        .init(
            title: "pairing.title", area: .account, view: .cloud,
            keywords: ["pairing.hint", "pairing.pair", "pairing.participants"],
            terms: ["iCloud", "QR", "CloudKit"]),

        // MARK: About
        .init(
            title: "about.privacy", area: .about, view: .privacy,
            keywords: ["about.legal", "about.privacyText"]),
        .init(
            title: "about.licences", area: .about, view: .licenses,
            keywords: ["about.legal"]),
        .init(
            title: "about.report", area: .about, view: .report,
            keywords: ["about.content", "about.reportText"]),
        .init(title: "about.version", area: .about, view: .about),
    ]

    /// What matches a term — **ordered by quality.**
    ///
    /// **Three ranks and no similarity computation.** A title that **starts** with the term is
    /// almost always the one sought; a title that contains it somewhere, often; a keyword that
    /// contains it, sometimes. A weighted similarity over thirty-seven entries would be
    /// computation without yield — and it does not explain itself when it is once off.
    ///
    /// **An empty term means an empty list and not "everything".** The root then shows its
    /// cards; a catalog that spills out thirty-seven rows for an empty field would be a second,
    /// worse root.
    /// **Since AP58 R7 the rule lives in ``Flows/SettingsSearch``** — three ranks, empty
    /// below two characters; what stays here is which texts an entry brings along.
    public static func match(zu word: String) -> [CatalogEntry] {
        SettingsSearch.match(
            zu: word, in: all, title: { SettingsModel.text($0.title) }, secondaryText: secondaryText)
    }

    /// Everything that is searched besides the title — keywords, terms, area name.
    ///
    /// **The area name belongs to it**, for the case one really has: whoever types "Diagnostics"
    /// wants to see the three rows of Diagnostics and not only the area.
    private static func secondaryText(_ entry: CatalogEntry) -> String {
        var split = entry.keywords.map { SettingsModel.text($0) }
        split += entry.terms
        split.append(SettingsModel.text(entry.area.titleKey))
        return split.joined(separator: " ")
    }

    /// Lowercase, without accents, without border — ``Flows/SettingsSearch/fold(_:)``.
    static func fold(_ text: String) -> String {
        SettingsSearch.fold(text)
    }
}
