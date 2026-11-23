/// Every view of the app — and the tab that lights up for it.
///
/// Without this table the highlight wanders away when you go in: A detail page belongs to
/// the library, a portal detail page to the portals, and downloads as well as storage also
/// belong to the library, although you reach them by three different ways.
///
/// Views with ``tabs`` == `nil` lie **above** the tab bar: setup, accounts, parental
/// controls and settings. There "Done" leads back, not a tab.
public enum ViewID: String, CaseIterable, Sendable {

    // The five tabs themselves
    case start, library = "bibliothek", live, portals = "portale", favorites = "favoriten", search = "suche"

    // What lies inside a tab
    case detail, detailFilm, detailPortal
    case downloads = "vorrat", storage = "speicher"

    // The two playback targets
    case player = "spieler", remote = "fernbedienung"

    // Laid on top — above the tab bar
    case setup = "einrichtung", accounts = "konten", newAccount = "kontoNeu", migration = "umzug",
        certificates = "zertifikate"
    /// Set up the TV from the phone — the QR route from AP5.
    case handoff = "uebergabe"
    case parentalControls = "kindersicherung", forgotPin = "pinVergessen", approvals = "freigaben"
    case settings = "einstellungen", channelLists = "senderlisten", newChannelList = "senderlisteNeu",
        portalSettings = "portaleEinstellungen"
    /// Version, privacy, licences, reporting route — **required by guideline 5.1.1(i).**
    case about = "ueber", privacy = "datenschutz", licenses = "lizenzen", report = "melden"
    /// Change an access instead of deleting and recreating it.
    case editChannelList = "senderlisteAendern"
    case liveSettings = "liveEinstellungen", groups = "gruppen", playback = "wiedergabe", ratingsSettings =
        "bewertungenEinstellungen"
    case appearance = "darstellung", arrangeShelves = "regaleOrdnen", diagnose, log = "protokoll",
        accountSettings = "kontoEinstellungen"
    /// "Devices & Sharing" — bring a profile to a foreign device (AP44).
    case cloud = "wolke"
    /// **Other devices** (AP59 N7) — the three ways to a second device in one place.
    case otherDevices = "andereGeraete"
    /// The way out "Forgot PIN" from the other device (AP43).
    case pinReset = "pinRuecksetzung"
    // **The profiles** (G3, 2026-09-26) — manage and create, as on the TV.
    case profile, profileChanged = "profilNeu"

    /// Which tab lights up while this view is visible.
    public var tabs: Tab? {
        switch self {
        case .start: .start
        case .library, .detail, .detailFilm, .downloads, .storage: .library
        case .live: .live
        case .portals, .detailPortal: .portals
        case .favorites: .favorites
        case .search: .search
        case .player, .remote: nil
        case .setup, .accounts, .newAccount, .migration, .certificates, .handoff,
            .parentalControls, .forgotPin, .approvals,
            .settings, .channelLists, .newChannelList, .portalSettings,
            .liveSettings, .groups, .playback, .ratingsSettings,
            .appearance, .arrangeShelves, .diagnose, .log, .accountSettings, .cloud, .otherDevices,
            .pinReset,
            .profile, .profileChanged,
            .about, .privacy, .licenses, .report, .editChannelList:
            nil
        }
    }

    /// What the view is called — **the board that did not exist until 2026-09-07**
    ///
    /// `navigationTitle` occurred **zero times** in the whole project. Not out of
    /// carelessness: ``OverlaidView`` was a `NavigationStack` without `path:` and had no
    /// view at all on which a title could hang. Anyone three levels deep (Account → Accounts →
    /// Certificates) read nowhere where they were — and that was the most frequently named
    /// reason why the area felt "old-fashioned".
    ///
    /// **The board stands here and not in twenty-one views.** The same consideration as with
    /// ``tabs``: Whoever wrote the title into every view would have it in twenty places and
    /// missing in one at the next screen. `nil` means "this view carries none" — the five tab
    /// roots carry their title in the content themselves, and the player carries none at all.
    public var titleKey: String? {
        switch self {
        case .start, .library, .live, .portals, .favorites, .search: nil
        case .detail, .detailFilm, .detailPortal: nil
        case .player, .remote: nil
        case .downloads: "settings.speicher"
        case .storage: "settings.speicher"
        case .setup: "nav.setup"
        // **No bar title: The root carries its large title in the content.** Both at once stood
        // doubled one below the other in the simulator on 2026-09-07 — "Settings" in the bar and
        // "Settings" below it at 34 points.
        case .settings: nil
        case .accounts: "settings.account.accounts"
        case .newAccount: "nav.accountNew"
        case .accountSettings: "settings.konto"
        case .cloud: "pairing.title"
        case .otherDevices: "settings.geraete"
        case .pinReset: "childLock.reset.title"
        case .profile: "profiles.manage"
        case .profileChanged: "profiles.newTitle"
        case .migration: "nav.handover"
        case .certificates: "accounts.certificates"
        case .handoff: "settings.handover.title"
        case .parentalControls: "settings.kindersicherung"
        case .forgotPin: "pin.forgot"
        case .approvals: "nav.releases"
        case .channelLists: "settings.senderlisten"
        case .newChannelList: "settings.addPlaylist"
        case .portalSettings: "settings.portale"
        case .liveSettings: "settings.live"
        case .groups: "live.groups"
        case .playback: "settings.wiedergabe"
        case .ratingsSettings: "settings.bewertungen"
        case .appearance: "settings.darstellung"
        case .arrangeShelves: "nav.shelfOrder"
        case .diagnose: "settings.diagnose"
        case .log: "nav.protocol"
        case .about: "settings.ueber"
        case .privacy: "nav.privacy"
        case .licenses: "about.licences.title"
        case .report: "nav.report"
        case .editChannelList: "nav.listEdit"
        }
    }

    /// Whether the view lies above the tab bar.
    ///
    /// The player and the remote also have no tab, but are not an overlay: They lie over
    /// **everything** and are not left with "Done".
    public var isOverlay: Bool {
        switch self {
        case .player, .remote: false
        default: tabs == nil
        }
    }
}
