import Core
import DesignSystem
import Flows
import SwiftUI

/// The sections of the settings.
///
/// **Why a structure at all.** Until here all settings stood
/// one below the other on one page: cache, access for ratings,
/// language, libraries for the header area, sign out. That just about held —
/// with the channel lists a section is added that itself
/// manages several entries, and then the page is longer than the screen.
///
/// On a TV a long page is especially bad: you scroll through everything with the
/// remote to reach the last item, and lose track of what there is at all.
///
/// Hence the sections on the left, the content on the right. What there is becomes visible at a
/// glance, and every section begins at the top.
/// **Since 2026-09-11 the order follows the four questions of the phone** (AP26).
/// It used to be different, and the reason for the change is not taste: the two apps
/// side by side looked organised differently, and in a focus trail **the
/// order is half the operation** — anyone looking for "the thing with the channels" is not looking for
/// "section seven".
///
/// **Four groups, each a different question:** *Sources* — where does something come from; *Viewing* — what
/// does it look like; *Device* — what is stored here and who is allowed; *About* — who are we.
///
/// **Since 2026-09-25 with visible group headers, and the list scrolls**
/// (product decision 1, AP46, following the mock-up `EB`). Until then this said: four
/// headings cost around 160 pt and made the column scroll, so just a gap.
/// With fourteen sections the sums no longer work out anyway (14 × 62 + 13 × 6 +
/// four headers ≈ 1200 pt of 960 usable), and the decision is: **better a
/// list that scrolls and says where you are than one that fits and stays silent.** The headers
/// take no focus; ``SettingsView`` scrolls them into view together with the first section of their
/// group.
nonisolated enum SettingsSection: String, CaseIterable, Identifiable {

    // ── Quellen · woher kommt etwas ──────────────────────────────────────────

    /// **"Media server" and no longer "Account", and under Sources instead of under About**
    /// (product decision 5, 2026-09-24, following the mock-up `EB`).
    ///
    /// The section holds certificates and "Sign out" — it answers the question *where
    /// does something come from*, exactly like the channel lists below it. **The profile list stood here until
    /// 2026-09-25** and has moved to ``profiles``: a person is not a source.
    ///
    /// **The raw value stays `account`.** It is stored in ``storageKey`` as the last selected
    /// section; a new raw value would mean that everyone who was last here lands somewhere else
    /// the next time they open it.
    case account
    /// Carries a status marker when no channel list is set up (``isMissingSomething``).
    ///
    /// **This used to say "the only section in which something can be missing"**, and that was right
    /// when there was the one marker — until early 2026-09-24. Since ``SetupState``
    /// **five** sections carry one.
    case playlists
    /// Third-party sources via the bridge in the home network (AP20).
    ///
    /// **Behind the channel lists:** it is the second section in which something is set
    /// up — and at the same time the one in which the least needs setting up. What a portal
    /// reads and how fast is configured on the bridge, not on the TV.
    case portals
    /// Also a source: where the ratings that appear on a title come from.
    case ratings

    // ── Viewing · what it looks like ──────────────────────────────────────────

    case appearance
    /// What applies during playback: the preferred audio track and the anime rule.
    ///
    /// **Without subtitles since 2026-09-25** (product decision 1): the row
    /// "Subtitles" stood here **and** as its own section in the mock-up — two entry points
    /// for one thing. Now there is one, ``subtitles``.
    case playback
    /// **Under Viewing and no longer under Sources** (product decision 1, 2026-09-25).
    ///
    /// The section does not set up anything that comes in — the channel lists do that. It
    /// sets **how much of it is shown**: which groups, in which order,
    /// which sports. That is the same question as "Display" next to it.
    case live
    /// **The app language as its own section** (product decision 1, 2026-09-25) — it
    /// used to be the first block in "Display".
    ///
    /// **Under Playback** (AP59 N7, 2026-09-30): the groups are now called Sources,
    /// Playback and Device; the language belongs with how something is shown.
    case language

    // ── Device · what is stored here and who is allowed ───────────────────────

    /// **Who watches on this TV** — the existing profile management
    /// (``ProfileView``), at the top of "Account" until 2026-09-25.
    ///
    /// **Under Device and not under Sources:** profiles are the people on *this*
    /// device; that they can travel via iCloud does not change where they are managed.
    case profiles
    /// The parental controls (G3).
    ///
    /// **Until 2026-09-11 they stood directly in front of "Account"**, and the reason was: both
    /// behind the same door. **That reason no longer holds since AP23.** In front of every locked
    /// section there is now a ``Curtain`` that explains itself and shows the way to the PIN;
    /// for that the two no longer need to sit next to each other. What remains is
    /// the question the section answers — **who is allowed** — and that belongs to the device.
    case childLock
    /// **Other devices** (AP59 N7, 2026-09-30) — give or fetch a profile, the handoff from the
    /// phone, the iPhone as a remote. Until then the three buttons were in the
    /// profile management; they belong to the device and not to a person.
    case devices
    case storage
    /// What the app tried last — the only information that is reachable
    /// on the TV.
    case diagnostics

    // ── About · who are we ────────────────────────────────────────────────────

    /// **Version, device identifier, privacy, licences, reporting channel** (AP26, 2026-09-11).
    ///
    /// **Guideline 5.1.1(i) applies to tvOS just the same**, and it requires the
    /// privacy policy explicitly *"within the app in an easily accessible
    /// manner"* — not only as a link in App Store Connect. Before this day, not a word of it
    /// appeared in the whole tree.
    ///
    /// **As text in the app and not as a QR code**, unlike what the roadmap
    /// proposed. The proposal assumed that the policy lives elsewhere and has to be
    /// linked from here; the phone project built it as its own screen on 2026-09-07, and the same
    /// text works here just as well. **A QR code would be a detour via a second device for
    /// something this one can show.**
    case about = "ueber"

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .playlists: "settings.section.playlists"
        case .portals: "tab.portals"
        case .live: "tab.live"
        case .playback: "settings.section.playback"
        // **The service and not the thing** (product decision, 2026-09-28): "Ratings" did not say
        // what is to be entered here; the names of the two services do.
        case .ratings: "settings.section.ratings"
        case .appearance: "settings.section.appearance"
        case .storage: "settings.section.storage"
        case .diagnostics: "settings.section.diagnostics"
        case .childLock: "childLock.title"
        case .devices: "settings.section.devices"
        case .account: "settings.section.mediaServer"
        case .profiles: "settings.section.profiles"
        case .language: "settings.language"
        case .about: "settings.section.about"
        }
    }

    /// Which group carries this section — **the shared one** (``Flows/SettingsGroup``,
    /// AP58 R7): the same four as on the phone, with the same names, and since R7 also with
    /// the same assignment (``Flows/SettingsArea/group``).
    typealias Group = SettingsGroup

    /// Which of the shared sections this one is — the group follows from it.
    var area: SettingsArea {
        switch self {
        case .account: .jellyfin
        case .playlists: .channelLists
        case .portals: .portals
        case .ratings: .ratings
        case .appearance: .appearance
        case .playback: .playback
        case .live: .live
        case .profiles: .profile
        case .language: .language
        case .childLock: .parentalControls
        case .devices: .devices
        case .storage: .storage
        case .diagnostics: .diagnose
        case .about: .about
        }
    }

    var group: Group { area.group }

    /// The explanatory sentence above the content — `nil` where the name suffices.
    ///
    /// **Until 2026-09-24 it stood at six section headers and was missing at five** (AP46).
    /// Six sections named their own name at the top together with a sentence, five nothing at all — and
    /// headers that looked the same below carried group names. Anyone going through the sections
    /// saw the same shape for two different roles.
    ///
    /// **Here instead of at the call sites**, so that ``AreaBreadcrumb`` can take it along: the
    /// crumb appears once in ``SettingsView`` above every content, and so no section
    /// can forget it and none can set it twice.
    var hintKey: String? {
        switch self {
        case .playlists: "settings.playlistsHint"
        case .live: "settings.liveVisibleHint"
        case .ratings: "settings.ratingsKeyHint"
        case .storage: "settings.storageHint"
        case .about: "settings.about.hint"
        case .language: "settings.languageHint"
        case .devices: "settings.devicesHint"
        // **The others without one, and that stays so.** Portals, Playback, Display,
        // Parental controls and Diagnostics begin with a group header or a row
        // that already says what it is about. The profiles carry their sentence themselves
        // (``ProfileView``). A sentence above would be a heading above a heading.
        case .portals, .playback, .appearance, .childLock, .diagnostics, .account,
            .profiles:
            nil
        }
    }

    /// Whether a group header stands **before** this entry.
    ///
    /// **A calculation and not a second list.** Anyone who enumerated the headers would have to
    /// count them in at the next section — and would forget. This way the header follows the
    /// group membership, and that stands one paragraph further up. **Unlike until
    /// 2026-09-25, also before the first entry:** there was no gap there, but a header was.
    var startsGroup: Bool {
        guard let location = Self.allCases.firstIndex(of: self) else { return false }
        return location == 0 || Self.allCases[location - 1].group != group
    }

    var symbol: String {
        switch self {
        case .playlists: Glyph.channelList.name
        // The same symbol as in the sidebar. Unlike with "Live", this
        // is right here: it does not stand next to an identical symbol,
        // but is meant to make the section recognisable.
        case .portals: Glyph.portal.name
        // Not the same symbol as the channel lists, even though the sidebar uses it
        // for "Live": two entries with the same symbol directly one below the other
        // cannot be told apart from three metres away.
        case .live: Glyph.live.name
        case .playback: Glyph.playback.name
        case .ratings: Glyph.rating.name
        case .appearance: Glyph.appearance.name
        case .storage: Glyph.storage.name
        case .diagnostics: Glyph.diagnose.name
        // A lock and not a family: the section sets a restriction, it
        // does not manage people — that is what "Account" next to it does.
        case .childLock: Glyph.parentalControls.name
        // The symbol of the handoff — two devices, one hands the other something.
        case .devices: Glyph.handoff.name
        // **The device and not the person** — the same symbol that a server fault
        // carries. Both talk about the same subject, and anyone who sees the fault
        // recognises the section by it.
        case .account: Glyph.serverMute.name
        // **An "i" and not a question mark.** A question mark promises help; here
        // are details about the app, not answers to the viewer's questions.
        case .about: Glyph.info.name
        // **Two people with a gear** — exactly what the section does: managing
        // people. The single circle (``Styling/Glyph/account``) means one person.
        case .profiles: Glyph.manageAccounts.name
        case .language: Glyph.language.name
        }
    }

    // MARK: - What is missing

    /// Whether something **remains to be filled in** in this section.
    ///
    /// **Gold and not red** (AP26, 2026-09-11). In this app red means "broken" —
    /// `ColorRole.live` appears at every fault. Nothing is broken here: something can be
    /// **filled in**, and painting that red turns an invitation into an
    /// error message.
    ///
    /// **Only the symbol and no second word.** "Set up" does not fit in the row:
    /// 264 pt remain for the label, the widest entry measures 229, and the
    /// entries are set with `lineLimit(1)`. The symbol therefore sits in the existing
    /// 26-pt symbol column. **The second carrier next to the colour is the sentence in the
    /// section's `SettingsHeader`** — colour alone never carries meaning.
    ///
    /// **Five sections instead of one** (AP46, 2026-09-23).
    ///
    /// This used to say "only the channel lists", with the reasoning that ``playlists`` calls
    /// itself "the only one in which something can be missing". **That was true when there was the one
    /// marker**, and it is no longer true: a household without a ratings key
    /// gets less precise ratings and placeholders instead of pictures of people, one without
    /// portals sees an empty list there, and one without media server access has a
    /// library that shows nothing. The phone has calculated these cases since 2026-09-07.
    ///
    /// **"Missing" means can be filled in and not broken.** That is why the marker carries the
    /// progress colour and not the warning colour: it is a calculation, not a fault —
    /// anyone who sees it knows they can enter something, not that something is broken.
    ///
    /// **Only sources carry the marker** (product decision, 2026-09-28): without an IPTV list, Live
    /// stood there with the same ⊕ as the sources above it and thereby looked as if it belonged to
    /// them. What is missing is the list — and the marker stands at it.
    func isMissingSomething(at state: SetupState) -> Bool {
        switch self {
        case .playlists: state.lacksChannelLists
        case .portals: state.lacksPortals
        case .ratings: state.lacksRatingsKey
        case .account: state.withoutAccess
        default: false
        }
    }

    // MARK: - Store

    /// **The settings open where you were last** (roadmap AP3):
    /// "Anyone who goes from Diagnostics to the library and comes back lands at the
    /// top again. Diagnostics in particular is rarely needed once and usually ten times
    /// in a row."
    ///
    /// **The view itself cannot remember this:** ``MainView`` builds it on switching
    /// sections and tears it down on leaving; its `@State` disappears with
    /// it. So the selected item lives outside the view.
    static let storageKey = "settings.lastSection"

    /// The section with which the settings open.
    ///
    /// Without a memory, ``playlists`` — the same answer as the very first time.
    /// **And an item that no longer exists counts as never remembered:** what was
    /// stored survives refactorings, and a section that the enumeration no longer
    /// knows would be a state that the interface cannot
    /// display.
    static func load(from store: any KeyValueStore) -> SettingsSection {
        guard let raw = try? store.value(for: storageKey), let value = SettingsSection(rawValue: raw)
        else { return .playlists }
        return value
    }

    /// **Without a special case for the default**, unlike with ``StreamQuality``:
    /// there the default means "no limit" and thereby "nothing set".
    /// Here "Channel lists" is a choice like any other — anyone who deliberately goes back
    /// there should also open there again.
    func save(to store: any KeyValueStore) {
        try? store.set(rawValue, for: Self.storageKey)
    }
}

/// What is not yet set up on this device.
///
/// **Four statements and no view** (AP46, 2026-09-23): the question "is something missing here?"
/// is a calculation, and a calculation can be tested. It comes as a bundle because
/// four separate truth values get swapped at the call site sooner or later — they
/// all look the same.
struct SetupState: Sendable, Equatable {

    /// No channel list entered.
    var lacksChannelLists = false

    /// No portal set up.
    var lacksPortals = false

    /// Neither OMDb nor TMDb key — or only one of the two.
    ///
    /// **Even a single missing one counts**, and that is the phone's calculation:
    /// the two deliver different things, and what the other can do is then missing.
    var lacksRatingsKey = false

    /// No media server access signed in.
    var withoutAccess = false
}

extension SettingsGroup {

    /// The name in the language catalog — the same one that the ``AreaBreadcrumb`` carries.
    var catalogTitleKey: String { titleKey }

    /// The sections of this group in their order — **read from
    /// ``SettingsSection/allCases``** and not enumerated, so that the list and the headers
    /// cannot drift apart.
    var sections: [SettingsSection] { SettingsSection.allCases.filter { $0.group == self } }
}
