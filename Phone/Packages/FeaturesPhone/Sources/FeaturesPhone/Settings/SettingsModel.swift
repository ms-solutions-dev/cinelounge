import Core
import DesignSystemPhone
import Diagnose
import Flows
import Foundation
import Observation
import ParentalControls
import ProfileKit

/// The nine areas — **and what their value column says.**
///
/// **This is the done condition of this package and not decoration.** A list of nine names
/// with nine chevrons forces nine taps to answer a single question: is something missing
/// anywhere? The value column answers it at a glance.
///
/// **The values are computed and not maintained.** A "value" field per area that someone
/// would have to update on every change drifts apart on the first day — and unnoticed, because
/// a wrong value column looks like a right one.
@MainActor
@Observable
public final class SettingsModel {

    /// The eleven areas, in four groups.
    ///
    /// **Until 2026-09-07 there were nine in a flat list**, in the TV's order, with the reasoning:
    /// someone who uses both devices looks on the second where they found it on the first. That
    /// sentence still holds for the **order within** a group and no longer for the list as a
    /// whole — nine identical-looking rows are nine equally important rows, and that was the
    /// statement the area did not want to make.
    ///
    /// **Two were added, and neither was a matter of taste:**
    ///
    /// * ``storage`` sat one level deeper under the account, and the path there ended in the
    ///   developer placeholder. On a phone it matters more than on the TV — there nobody asks
    ///   how full the device is.
    /// * ``about`` did not exist at all. Privacy policy, licenses and version occurred zero
    ///   times in the whole source; **guideline 5.1.1(i) explicitly requires the policy inside
    ///   the app.** That was the only finding of four passes that hard-blocks a submission.
    ///
    /// **Order and groups since AP58 R7 as on the TV** (``Flows/SettingsArea``,
    /// decision 1): the account (the media servers) is the first entry under *Sources* and no
    /// longer under *About*, Live is under *Watching* and no longer under *Sources*.
    public enum Area: String, Sendable, CaseIterable, Identifiable {
        case account = "konto"
        case channelLists = "senderlisten"
        case portals = "portale"
        case ratings = "bewertungen"
        case appearance = "darstellung"
        case playback = "wiedergabe"
        case live
        case parentalControls = "kindersicherung"
        /// **Other devices** (AP59 N7) — Devices & Sharing, Set up TV, Remote.
        case devices = "geraete"
        case storage = "speicher"
        case diagnose
        case about = "ueber"

        public var id: String { rawValue }

        /// The areas that exist in **this build variant.**
        ///
        /// **`allCases` is the enumeration, this is the catalog** (2026-09-07, ROADMAP A1). A store
        /// version without portals must not carry a "Portals" row — and because
        /// ``SettingsCatalog`` derives its area entries from this list, the search hit
        /// disappears together with the row. A hit that leads to a screen that does not exist would
        /// be the same error as "linked but not built", only produced at build time.
        public static var available: [Area] {
            allCases.filter { $0 != .portals || SourceSwitch.portals }
        }

        /// Which group the row belongs to — **the shared one** (``Flows/SettingsGroup``).
        public typealias Group = SettingsGroup

        public var group: Group { area.group }

        public var titleKey: String { "settings.\(rawValue)" }

        public var icon: String {
            switch self {
            case .channelLists: Glyph.Tab.live.outlined
            case .portals: Glyph.portal.name
            case .live: Glyph.live.name
            case .playback: Glyph.playback.name
            case .ratings: Glyph.rating.name
            case .appearance: Glyph.appearance.name
            case .parentalControls: Glyph.parentalControls.name
            case .devices: Glyph.handoff.name
            case .storage: Glyph.storage.name
            case .diagnose: Glyph.diagnose.name
            case .account: Glyph.account.name
            case .about: Glyph.info.name
            }
        }

        /// Where the row leads.
        public var view: ViewID {
            switch self {
            case .channelLists: .channelLists
            case .portals: .portalSettings
            case .live: .liveSettings
            case .playback: .playback
            case .ratings: .ratingsSettings
            case .appearance: .appearance
            case .parentalControls: .parentalControls
            case .devices: .otherDevices
            case .storage: .storage
            case .diagnose: .diagnose
            case .account: .accountSettings
            case .about: .about
            }
        }
    }

    public private(set) var values: [Area: Value] = [:]

    /// How many errors are in the ledger today — `nil` until someone has counted.
    private var errorsToday: Int?

    /// The name in the header — **a question mark while nobody is signed in**, and not an
    /// invented name. The same rule as in ``ShellModel/accountName``.
    public var accountName: String { accounts.signedInAccount?.name ?? "?" }

    /// The line below: what this account is tied to.
    ///
    /// **The server and not the number of accounts.** "2 accounts" answers no question anyone
    /// has before opening; `media.lan` answers the only one that matters — am I on the right
    /// server.
    public var accountLine: String {
        let server = state.jellyfin?.serverURL.host() ?? Self.text("settings.value.none")
        guard let account = accounts.signedInAccount else { return server }
        guard account.kind else { return server }
        return server + DelimiterChars.point + Self.text("accounts.child")
    }

    /// What the value column says.
    ///
    /// **A ``CaptionLabel`` and not a finished string.** Seen in the check on 2026-09-06: under
    /// `swift test` there is no app bundle, and `String(localized:)` returns the **key** instead
    /// of the text there. A check that points at German words therefore does not test the value
    /// but the presence of the catalog — and fails as soon as it runs outside the app.
    ///
    /// With the label the statement is in the type: the key is the information, the translated
    /// text its presentation. The same separation as with shelves and catalogs.
    public struct Value: Sendable, Equatable {
        public let label: CaptionLabel
        /// Whether it points to something missing — **gold and not red.**
        public let isMissing: Bool

        public init(_ label: CaptionLabel, isMissing: Bool = false) {
            self.label = label
            self.isMissing = isMissing
        }

        /// The key, if it is one — for checks.
        public var key: String? {
            if case .key(let name) = label { return name }
            return nil
        }
    }

    private let state: SetupState
    private let accounts: AccountsModel
    private let keychain: SecureStore

    /// The rule as it applies **now** — device state, account type and PIN combined.
    private let parentalControls: ProtectionRule

    public init(
        state: SetupState = SetupState(),
        accounts: AccountsModel? = nil,
        keychain: SecureStore = SecureStore(),
        parentalControls: ProtectionRule? = nil
    ) {
        self.state = state
        let list = accounts ?? AccountsModel(keychain: keychain)
        self.accounts = list
        self.keychain = keychain
        self.parentalControls =
            parentalControls
            ?? {
                // **With the profile ledger** — the kind of the active profile counts too (AP45).
                let device = ParentalControlsState(
                    keychain: keychain, ledgerStore: FileStore())
                device.accountKind = list.signedInAccount?.kind == true ? .kind : .adult
                return device.rule
            }()
        calculate()
    }

    /// Counts the day's errors afterwards — **supplied later, because the ledger is an actor.**
    ///
    /// **Only `error` and `abort`.** A notice is something conspicuous that did no harm;
    /// counting it would turn a quiet app into one that reports "7" every day — and the number
    /// into one nobody reads anymore.
    public func countErrors() async {
        let today = await ErrorLog.shared.entries()
            .filter { $0.severity >= .error && Calendar.current.isDateInToday($0.timestamp) }
        errorsToday = today.count
        calculate()
    }

    /// Rechnet alle Wertspalten neu.
    public func calculate() {
        var fresh: [Area: Value] = [:]

        // **1 · Channel lists** — count and state, not only the count. "2" alone leaves open
        // whether both are usable.
        // **The environment fallback gets its own value** (2026-09-07, AP4). "nothing" in gold would
        // mean "something is missing here that can be filled in" — but nothing is missing, it is
        // just somewhere else. See ``SourceAssembly/fromEnvironment(_:)``.
        let lists = state.channelLists
        fresh[.channelLists] =
            lists.isEmpty
            ? (SourceAssembly.fromEnvironment(.channelList)
                ? Value(.key("settings.value.environment"))
                : Value(.key("settings.value.none"), isMissing: true))
            : Value(
                .wording(
                    Self.text(
                        "settings.value.lists %lld", lists.count,
                        lists.filter(\.isEnabled).count)))

        // **2 · Portals** — there is nothing to set here, and the value column says so without
        // beating around the bush. An empty value would suggest that one has to go and look.
        fresh[.portals] = Value(
            .key(
                SourceAssembly.wantsPortals(state) ? "common.on" : "common.off"))

        // **3 · Live** — the visible number. What stands here must be the same number as in the
        // segment below; two counters over the same catalog were finding M2.
        // **The tab first, then the groups** (2026-09-07). Until then it said
        // "configured" as soon as **any** list existed — even when the Live tab was switched off.
        // The row thus reported an area as set up that one could not even see.
        let liveOff = TabSelection.stored().contains(Tab.live.rawValue)
        let hidden = LivePreferences.load(from: keychain).hiddenGroups.count
        fresh[.live] =
            lists.isEmpty
            ? Value(.key("settings.value.none"), isMissing: true)
            : liveOff
                ? Value(.key("common.off"))
                : hidden == 0
                    ? Value(.key("common.on"))
                    : Value(.wording(Self.text("settings.value.hidden %lld", hidden)))

        // **4 · Playback** — the one number one would otherwise have to open.
        //
        // **Until 2026-09-07 this was a constant "configured".** Four of the nine rows did that, and so
        // the value column answered nothing for almost half of the area — although it is the stated
        // done condition of this package. "Configured" is no information: it also appears when
        // nobody ever configured anything.
        //
        // **And until 2026-09-25 it read a key that nobody wrote anymore**
        // (`player.subtitleSize` in `UserDefaults`, dead since 2026-09-07): the row always said
        // "100 %". Now from the same store as the player — per profile.
        let size = SubtitleStyle.load(from: ProfileStore.playback).size.percent
        fresh[.playback] = Value(.wording(Self.text("settings.value.subtitles %lld", size)))

        // **5 · Ratings** — the case the value column exists for. Two keys,
        // and if one is missing it says so here and not only two levels deeper.
        fresh[.ratings] = Self.ratingsValue(keychain)

        // **6 · Appearance** — color scheme and language, the two things that are there.
        let board = ColorPattern.chosen()
        let chosen = ColorBoard.all(forItem: .phone).first { $0.id == board } ?? .phoneCinema
        fresh[.appearance] = Value(.key(chosen.nameKey))

        // **7 · Parental controls** — "off" is information and not a deficiency; an
        // adult account does not need it.
        //
        // **The device state and not the account list (decision of 2026-09-06).** Here
        // it used to say `accounts.contains(where: \.kind)` — so the row reported "on" as soon as
        // *any* account was a child account, even when an adult was sitting in front of it and
        // nothing was locked. And it reported "off" while a child with the parent's phone in
        // hand stood in front of an effective lock. What is locked **now** depends on the device;
        // whom the progress belongs to, on the account.
        //
        // **And without a PIN it says "off" there, whatever the switch says.** A lock without a
        // stored PIN does not take effect (``ProtectionRule/applies``); reporting "on" would be
        // the claim this whole package is meant to eliminate.
        fresh[.parentalControls] = Value(
            .key(parentalControls.applies ? "common.on" : "common.off"))

        // **8 · Diagnostics** — what went wrong today, and nothing else.
        //
        // **Zero errors is good news and not an empty row.** That is why it says
        // "nothing reported" and not a dash: a dash would mean "not checked".
        // **The ledger is an actor, this computation is not.** The counter therefore
        // arrives later (``countErrors()``) and not here — ``calculate()`` runs on
        // every appearance of the view, and an `await` in it would hold up all eleven rows
        // until a file is read.
        fresh[.diagnose] =
            errorsToday.map { count in
                count == 0
                    ? Value(.key("settings.value.noErrors"))
                    : Value(.wording(Self.text("settings.value.errors %lld", count)))
            } ?? Value(.key("settings.value.set"))

        // **10 · Storage** — until 2026-09-07 it sat under the account, and the path there
        // ended in the developer placeholder. On a phone it matters more than on the
        // TV: there nobody asks how full the device is.
        fresh[.storage] = Value(.wording(StorageUsage.short()))

        // **Other devices** (AP59 N7) — which ways a second device can be reached.
        fresh[.devices] = Value(
            .key(
                ProfileCloud.attached == nil
                    ? "settings.value.devicesHome" : "settings.value.devicesCloud"))

        // **11 · About** — the version, so one does not have to search for it for a follow-up question.
        fresh[.about] = Value(.wording(DeviceDetails.thisDevice().version))

        // **9 · Account** — how many, and who is signed in.
        let signedIn = accounts.accounts.first { $0.id == accounts.signedIn }
        fresh[.account] =
            signedIn.map { Value(.wording($0.name)) }
            ?? Value(.key("settings.value.none"), isMissing: true)

        values = fresh
    }

    /// Two keys, and the value column names the one that is missing.
    ///
    /// `nonisolated`, because it is a query on the Keychain and touches no state — a check should
    /// be able to ask it without the main queue.
    ///
    /// **Without them nothing is broken, but something is different** — the ratings are less
    /// precise and the people circles show placeholders. That is exactly what belongs in the
    /// value column: not "error", but "something that can be filled in is missing here".
    nonisolated static func ratingsValue(_ load: SecureStore) -> Value {
        let omdb = load.omdbAPIKey() != nil
        let tmdb = load.tmdbAPIKey() != nil
        switch (omdb, tmdb) {
        case (true, true): return Value(.key("settings.value.bothKeys"))
        case (true, false): return Value(.key("settings.value.tmdbMissing"), isMissing: true)
        case (false, true): return Value(.key("settings.value.omdbMissing"), isMissing: true)
        case (false, false): return Value(.key("settings.value.noKeys"), isMissing: true)
        }
    }

    nonisolated static func text(_ key: String) -> String {
        AppLanguageSetting.text(String.LocalizationValue(key))
    }

    /// The same path for an inserted **wording** instead of a number — "17.9 GB
    /// free". Kept separate and not carried along via `CVarArg`: `%@` and `%lld` require
    /// different types, and a mix-up is only noticed at runtime.
    nonisolated static func text(_ key: String, _ wording: String) -> String {
        String(
            format: AppLanguageSetting.text(String.LocalizationValue(key)),
            wording)
    }

    nonisolated static func text(_ key: String, _ numbers: Int...) -> String {
        String(
            format: AppLanguageSetting.text(String.LocalizationValue(key)),
            arguments: numbers.map { $0 as CVarArg })
    }
}
