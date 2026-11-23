import Core
import Diagnose
import Foundation
import ParentalControls
import PlaylistKit
import ProfileKit

/// Applies an arrived bundle — **the counterpart of ``HandoffModel``.**
///
/// **Here and not in the TV program**, for the same reason as the wire next to it: what
/// arrives has to go where the other device took it from. Two lists in two places drift
/// apart, and the failure then looks like this: "everything transferred" is on one screen
/// and a password is missing on the other. As a separate type it can also be tested with
/// in-memory stores, without two devices.
///
/// **What does not travel explicitly does not travel.** ``SetupBundle`` has no
/// field for the downloads, for "Wi-Fi only" and for the diagnostics ID — those three stay
/// where they are, and this file therefore cannot apply them in the first place.
/// **`@MainActor` and not `Sendable`.** It writes to `UserDefaults` and to the Keychain,
/// and both belong on one thread: the takeover runs exactly once, immediately after a
/// bundle has arrived, and the screen next to it shows its ``Report`` right afterwards.
@MainActor
public struct Takeover {

    /// What was applied — for the lines on the screen afterwards.
    ///
    /// **A list and not a success message.** "Transferred" does not answer the question of
    /// someone who has two devices in front of them: they want to know **what** is over there
    /// now. The same reasoning as with ``DoneView`` on the phone.
    /// **`Codable`, because since 2026-09-20 it travels back over the wire** (AP39). Until
    /// then it stayed on the TV: the phone received a single byte
    /// (``HandoffWire/Receipt``) and had to infer from it what had arrived. It could
    /// therefore never learn "parental controls rejected" — even though that is exactly the
    /// line the viewer has to be told.
    public struct Report: Sendable, Equatable, Codable {
        /// Stored keys keep their original (German) names — renaming them would
        /// make data written by earlier versions unreadable (AP85 B4).
        private enum CodingKeys: String, CodingKey {
            case jellyfin = "medienserver"
            case channelLists = "senderlisten"
            case bridge = "bruecke"
            case key = "schluessel"
            case parentalControls = "kindersicherung"
            case parentalControlsRejected = "kindersicherungAbgelehnt"
            case language = "sprache"
            case colorPattern = "farbmuster"
            case shelves = "regale"
            case profile
        }

        public var jellyfin: String?
        public var channelLists: Int = 0
        public var bridge: Bool = false
        public var key: Int = 0
        public var parentalControls: Bool = false
        /// **The parental controls in the bundle were rejected** because this device already has
        /// its own — see ``Takeover/matches(code:)-8xk1c``.
        ///
        /// As a field of its own and not as an absent ``parentalControls``: "not applied" and
        /// "rejected" are two different things, and only the second has to be told to the viewer.
        /// The screen afterwards lists what has arrived; what has **not** arrived and why is the
        /// more important line.
        public var parentalControlsRejected: Bool = false
        public var language: String?
        /// The ID of the applied color scheme — `nil` if none was included or this device does
        /// not know the ID.
        ///
        /// **In the report because the UI has to apply it itself.** The store is written here, but
        /// the running app keeps its scheme in `ThemeStore`, and that learns nothing about a store
        /// that someone else writes to.
        public var colorPattern: String?
        /// How many shelves the bundle ordered. **Zero means: no order included.**
        public var shelves: Int = 0

        /// How many **new** people were added (AP44).
        ///
        /// Only the new ones, and that is the honest number: a bundle with four profiles, three of
        /// which are already here, has brought one. "Four profiles transferred" would not be wrong
        /// on a screen that then shows four, and yet it would be misleading.
        public var profile: Int = 0

        public init() {}
    }

    /// **A ``SecureStore`` and not a ``KeyValueStore``**, although most of this only needs
    /// keys and values: the access to the media server and the two database keys go through
    /// their own methods that exist only there. For testing, a separate service name is
    /// enough — it then reaches into a Keychain of its own and not the one of the running
    /// device.
    private let keychain: SecureStore
    private let listen: PlaylistStore
    private let trust: CertificateTrustStore
    private let store: UserDefaults
    /// Where the shelf order lives — since AP40 a file and not the Keychain. **Since AP58 R7
    /// also the color scheme** (``Core/ColorPattern``): the same file store of the device.
    private let shelfStore: any KeyValueStore

    /// Where ``ProfileKit/ProfileBook`` lives — the same ``Core/FileStore`` as everywhere.
    private let ledgerStore: any KeyValueStore

    public init(
        keychain: SecureStore = SecureStore(),
        listen: PlaylistStore = .onDevice(),
        trust: CertificateTrustStore = CertificateTrustStore(),
        store: UserDefaults = .standard,
        shelfStore: (any KeyValueStore)? = nil,
        ledgerStore: (any KeyValueStore)? = nil
    ) {
        self.keychain = keychain
        self.listen = listen
        self.trust = trust
        self.store = store
        self.shelfStore = shelfStore ?? FileStore()
        self.ledgerStore = ledgerStore ?? FileStore()
    }

    /// Applies the bundle.
    ///
    /// **Certificate trust first, then the access.** The other way round, an access to
    /// `https://…home` that this device does not trust would exist for a moment — and whoever
    /// loads in that moment gets the security prompt that the bundle was just supposed to
    /// answer.
    ///
    /// **Nothing is deleted.** A TV that already has a channel list keeps it; the bundle adds
    /// to it. Whoever emptied their first device while setting up a second would lose
    /// something nobody had announced — and ``CarryOverSheet`` does not announce it.
    @discardableResult
    public func matches(code bundles: SetupBundle) -> Report {
        var report = Report()

        if let server = bundles.jellyfin {
            // **Only hosts this device does not yet trust** (setup check, E6, 2026-09-27). A
            // confirmed digest is an answer to the TOFU question; silently replacing it with the
            // bundle's would mean skipping the "certificate changed" question — exactly the one the
            // procedure was built for. If the digest differs, the device's own stays, and on the next
            // connection the device asks, as it does for every changed certificate.
            for (calculator, digest) in server.trusted where trust.fingerprint(for: calculator) == nil {
                try? trust.trust(CertificateFingerprint(value: digest), for: calculator)
            }
            let credential = ServerCredentials(
                serverURL: server.address, userID: server.userID,
                username: server.username, accessToken: server.accessToken)
            // **Both, because ``SecureStore`` keeps the two separately:** ``memorize(_:)`` fills the
            // account list, ``saveCredentials(_:)`` the signed-in session. Calling only the second
            // was the bug that a third of all findings on the phone hung on — the account list
            // stayed empty.
            try? keychain.memorize(credential)
            // **The session only if there is none yet** (E8, child protection). "Fetch profile" runs
            // through this path on a TV that is already set up; the session there belongs to the
            // active profile, and a bundle from the phone would switch it to the phone's account —
            // the child profile showed a parent's library until somebody switched. The fetched
            // account is now in the list; the session changes only via the latch of the profile
            // switch.
            if (try? keychain.loadCredentials()) == nil {
                try? keychain.saveCredentials(credential)
            }
            report.jellyfin = server.username
        }

        for list in bundles.channelLists {
            matches(code: list)
            report.channelLists += 1
        }

        if let bridge = bundles.bridge {
            report.bridge = BridgeAddress.save(bridge.absoluteString, to: keychain)
        }

        if let omdb = bundles.omdbKey {
            try? keychain.setOMDbAPIKey(omdb)
            report.key += 1
        }
        if let tmdb = bundles.tmdbKey {
            try? keychain.setTMDbAPIKey(tmdb)
            report.key += 1
        }
        if let mal = bundles.malKey {
            try? keychain.setMALClientID(mal)
            report.key += 1
        }

        if let language = bundles.language {
            AppLanguageSetting.write(
                language, profile: ProfilePointer.active, keychain: keychain, device: store)
            report.language = language
        }

        if let patterns = Self.colorPattern(bundles.colorPattern) {
            ColorPattern.select(patterns.id, in: shelfStore)
            report.colorPattern = patterns.id
        }

        // **The shelf order arrived nowhere until 2026-09-21** (AP40) — and ``CarryOverSheet``
        // has always promised it ("language, color scheme, shelf and group order"). Two places
        // were missing: the phone read it from `UserDefaults` when packing while it lay in the
        // Keychain, and here nobody read it from the bundle. The field existed, it was never
        // filled, and the promise was on the screen anyway. The same trap as with the age limit
        // (AP22) and the bridge address — the same name, two stores.
        //
        // **Only the order, and it does not overwrite one of its own.** A TV on which things have
        // already been ordered keeps its order: "Nothing is deleted" applies here as everywhere
        // in this method.
        //
        // **Into the order of the active profile** (check finding A-S5, 2026-09-27) — that is
        // where Home reads it (`HomeModel.load`). Until then it landed in the device order, and
        // the report announced shelves nobody saw.
        if !bundles.shelfOrder.isEmpty {
            let profile = ProfilePointer.active
            var preferences = ShelfPreferences.load(from: shelfStore, forItem: profile)
            if preferences.order.isEmpty {
                preferences.adopt(order: bundles.shelfOrder)
                preferences.save(to: shelfStore, forItem: profile)
                report.shelves = bundles.shelfOrder.count
            }
        }

        applyLive(bundles)

        report.profile = matches(code: bundles.profile)

        if let backup = bundles.parentalControls {
            // **A bundle does not lift an existing lock** (AP23, 2026-09-11). Until then the takeover
            // wrote PIN, limit and child mode **unasked** — and a bundle with `active: false` and
            // without a PIN switched off the child mode of this TV without anyone having seen a PIN.
            //
            // **A set PIN is the statement "this device has a responsible person".** What comes from
            // outside must not overwrite it — not even to tighten: whoever may set the lock of a
            // foreign device may also loosen it, and the difference could not be checked here
            // because the sender supplies the values.
            //
            // **The latch is the second layer and not the first.** The first is the door in front of
            // the receiving screen (``Features/ParentalControlsDoor``); this one takes effect when
            // someone opens a second way there. On first setup it costs nothing — without a set PIN
            // there is nothing to protect, and that is exactly when the handoff runs.
            if Pin(store: keychain).isSet {
                report.parentalControlsRejected = true
                Diagnose.hint(
                    .parentalControls, "Takeover: parental controls rejected, a PIN already applies here")
            } else {
                matches(code: backup)
                report.parentalControls = true
            }
        }

        Diagnose.step(
            .login,
            "Takeover: server \(report.jellyfin != nil ? "yes" : "no"), "
                + "\(report.channelLists) lists, \(report.key) keys, "
                + "\(report.shelves) shelves, \(report.profile) new profiles")
        return report
    }

    /// Group order, hidden groups and disabled sports — **until 2026-09-27 they never
    /// arrived** (ultra e5, round A.5).
    ///
    /// The fields had been in the bundle since version 1, the phone never filled them, and
    /// here nobody read them; ``CarryOverSheet`` promised the group order anyway.
    ///
    /// **Like the shelf order: only into an empty choice.** A TV on which groups are already
    /// ordered or hidden or sports disabled keeps what is there — "nothing is deleted" applies
    /// here too. Both live on both devices in the Keychain under the same keys
    /// (``Core/LivePreferences``, ``Core/SportFilterSettings``). **An unknown sport is
    /// discarded** — it comes from a newer phone.
    private func applyLive(_ bundles: SetupBundle) {
        var live = LivePreferences.load(from: keychain)
        var changed = false
        if live.groupOrder.isEmpty, !bundles.groupOrder.isEmpty {
            live.setGroupOrder(bundles.groupOrder)
            changed = true
        }
        if live.hiddenGroups.isEmpty, !bundles.hiddenGroups.isEmpty {
            for group in bundles.hiddenGroups { live.setVisible(false, group: group) }
            changed = true
        }
        if changed { live.save(to: keychain) }

        var sport = SportFilterSettings.load(from: keychain)
        let disabled = bundles.sports.compactMap(SportKind.init(rawValue:))
        if sport.disabled.isEmpty, !disabled.isEmpty {
            for kind in disabled { sport.toggle(kind) }
            sport.save(to: keychain)
        }
    }

    /// A channel list — **added, and an existing one keeps what it has** (setup check, E2,
    /// 2026-09-27).
    ///
    /// **The same ID means: this device already knows the account** — it is computed from host
    /// and user (``Core/ListKey``). Until then the bundle replaced the entry
    /// completely: the EPG address was gone, a disabled list was on again, the name was the
    /// phone's. Now the entry stays as it is; only what is missing is filled in — the
    /// password, if the bundle brings one (it is the one the phone is currently watching
    /// with), and the program source, if there is none here.
    private func matches(code list: SetupBundle.ListAccess) {
        if let available = listen.playlist(withID: list.identifier) {
            let password = list.password.flatMap { $0.isEmpty ? nil : $0 }
            let epg: URL?? = available.epgURL == nil && list.epg != nil ? .some(list.epg) : nil
            guard password != nil || epg != nil else { return }
            listen.update(available.id, epgURL: epg, password: password)
            return
        }
        // **Xtream is recognised by the user name and not by the name of the list.** The latter
        // is freely chosen; whoever distinguishes by it files an M3U file as a provider access
        // as soon as someone calls their list "Xtream".
        let kind: Playlist.Kind =
            list.user.map { .xtream(server: list.address, username: $0) }
            ?? .m3u(list.address)
        listen.add(
            Playlist(id: list.identifier, name: list.name, kind: kind, isEnabled: true, epgURL: list.epg),
            password: list.password)
    }

    /// The people from the bundle — **added and nothing overwritten** (AP44).
    ///
    /// **A profile this device already knows stays as it is here.** The wire is a setup path
    /// and not a sync: it runs once, in one direction, and knows nothing about which of the
    /// two versions is the newer. Whoever let it overwrite anyway would turn "my phone sets up
    /// the TV" into "my phone wins" — and against a TV at which someone has sat since. **For
    /// syncing there is iCloud** (``ProfileKit/ProfileCloud``); there is a modification time per
    /// record, and exactly for that reason the sync may do what this path may not.
    ///
    /// **Whoever is watching right now is likewise untouched** — the bundle does not even
    /// bring that information along, see ``SetupBundle/profile``.
    ///
    /// - Returns: how many **new** ones were added.
    private func matches(code profileEntry: [Profile]) -> Int {
        guard !profileEntry.isEmpty else { return 0 }
        var ledger = ProfileBook.read(from: ledgerStore)
        var counted = 0
        for profileName in profileEntry
        where !ledger.profile.contains(where: { $0.identifier == profileName.identifier }) {
            ledger.create(profileName)
            counted += 1
        }
        guard counted > 0 else { return 0 }
        ledger.write(in: ledgerStore)
        return counted
    }

    /// The parental controls — **PIN first, switch last.**
    ///
    /// **The order is the security.** Whoever turns on child mode before the PIN is set has a
    /// lock without a key for a moment — and that is exactly the state that
    /// ``ParentalControls/Pin`` catches with "without a set PIN the answer is `false`": the
    /// lock would be on and nobody could get out.
    ///
    /// **Each of the three pieces goes where the TV side looks for it** — and that is not the
    /// same store for all three. The PIN lives in the Keychain because it is a secret. Child
    /// mode lives in `UserDefaults` because it is not one (``ParentalControls/ChildMode``
    /// states that explicitly). **The limit was wrong until 2026-09-11:** written here as an
    /// `Int` into `UserDefaults`, read over there as a string from the Keychain. It never
    /// arrived, and nobody reported it — on the TV child mode was on, PIN set, no limit, and
    /// the filter let everything through (AP22).
    ///
    /// Since then ``ParentalControls/AgeLimit/write(_:in:)`` writes it and
    /// ``ParentalControls/AgeLimit/read(from:)`` reads it — **one method per direction,
    /// and the key now appears in only one place in the tree.**
    private func matches(code backup: SetupBundle.ParentalControlsState) {
        if let extract = backup.pin {
            Pin(store: keychain).adopt(extract)
        }
        // **Only write, do not delete** — as everywhere here ("Nothing is deleted", see above).
        // Whether a bundle without a limit should *lift* an existing limit is a decision of its
        // own and is recorded in AP23 next to the receiving door; making it now in passing would
        // mean silently loosening a set lock.
        //
        // **An unknown number is discarded and not rounded.** The bundle carries a raw `Int`
        // because it may be older than this device; what matches no level is not a limit one
        // should guess.
        if let limit = backup.ageLimit.flatMap(AgeLimit.init(rawValue:)) {
            AgeLimit.write(limit, in: keychain)
        }
        store.set(backup.active, forKey: Self.kidsModeKey)
    }

    /// The color scheme for an ID from the bundle — **until 2026-09-26 it never arrived**
    /// (AP58): the field was packed on the phone, ``CarryOverSheet`` promised it, and here
    /// nobody read it.
    ///
    /// **Overwritten like the language and not spared like the shelf order.** Both are a
    /// question of appearance that someone on the phone has just answered; the shelf order, by
    /// contrast, is work that was done on the TV. And unlike there, an own choice cannot be
    /// told apart from the default: ``Grundstock/Theme/load(from:)`` returns a scheme in both
    /// cases.
    ///
    /// **An unknown ID is discarded and not bent to the default.** It comes from a newer
    /// phone; ``Grundstock/Theme/named(_:)`` would fall back to Kino and overwrite a chosen
    /// Midnight with something nobody sent.
    public static func colorPattern(_ identifier: String?) -> Theme? {
        guard let identifier else { return nil }
        return Theme.all.first { $0.id == identifier }
    }

    /// **The same keys as on the phone**, verbatim. Whoever invented their own here would
    /// write to a place nobody reads — and the takeover would silently have no effect. The age
    /// limit is deliberately **not** here: its key has lived at
    /// ``ParentalControls/AgeLimit/storeKey`` since AP22, precisely because it
    /// stood there twice and the two places meant different stores.
    ///
    /// **Written via ``Core/AppLanguageSetting`` since 2026-09-25** (AP46): whoever is watching right
    /// now gets the language in their slot, and before the first setup the device does — as
    /// before. And the shell hears it immediately instead of only after a restart.
    static let languageKey = AppLanguageSetting.key
    /// Verbatim the key from ``ParentalControls/ChildMode`` — `private` there, looked up
    /// here and not invented.
    static let kidsModeKey = "childMode.on"
}
