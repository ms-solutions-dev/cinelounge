import Core
import Foundation

/// Every door of the app and whether it is locked in child mode — **as a table.**
///
/// **The most serious finding of the usability pass was exactly here:** from the child
/// account, **four taps** led to the "Adult channels" switch, without a PIN. A gap like
/// that is found with a rule table and a test suite, not with the eye — which is why this
/// is an enumeration and not a scattered `if` query.
///
/// **The "sixteen doors" of the roadmap no longer exist, and that is a finding.** The
/// number comes from the design; since then views have been added — `arrangeShelves`,
/// `groups`, `newChannelList`. A fixed number in a growing app is a promise that gets
/// silently broken at the next screen. **That is why it is not this file that counts, but
/// the test suite:** it walks every ID that exists and demands a decision for each. A new
/// view without an entry breaks the check — and that is the point.
///
/// **What explicitly stays open** stands there with the same weight as what is locked: the
/// downloads, the storage from the downloads, every detail page and the "forgot PIN" path.
/// The first three because a child may see what it may see; the last because a lock without
/// a way out is not a lock but a defect.
public enum LockedDoors {

    /// What lies behind a door: whether it is shut.
    ///
    /// **The reason is in the catalog and not here** (AP58 final step, report B finding 3).
    /// Until 26.09.2026 every door carried its sentence as a German raw text, and both devices
    /// showed it via `Text(verbatim:)` — in English and Turkish, in German. Now it stands per
    /// door under ``reasonKey(_:)`` in the shared catalog `WordingKit`, in three languages;
    /// `LockedDoorsTests` demands it for every door.
    public struct Door: Sendable, Equatable {
        /// Whether the PIN is asked for.
        public let locked: Bool

        public init(locked: Bool) {
            self.locked = locked
        }
    }

    /// The doors, named like the views and sheets they open.
    ///
    /// **Strings and not an enumeration from the UI package.** This package is logic-only and
    /// is meant to stay so — it could later move into the shared set, where `ViewID`
    /// does not exist. The view passes in its `rawValue`; that both lists match is checked by a
    /// test in the phone project.
    public static let board: [String: Door] = [
        // â Accounts: the door through which all others would be reachable ----------
        "kontowechsel": Door(locked: true),
        "konten": Door(locked: true),
        "kontoNeu": Door(locked: true),
        // **Managing and creating profiles** (G3, 26.09.2026) — own views on the phone, behind
        // `accounts` and `newAccount` on the TV. A new profile is one without a limit, a removed one
        // takes progress and lock with it; both have the same reach as a new login.
        "profile": Door(locked: true),
        "profilNeu": Door(locked: true),
        // **The PIN of a profile, set, changed or removed** (AP52, 25.09.2026). The old PIN
        // proves who the profile belongs to — it does not prove that an adult is sitting in
        // front of it. A child knows its own PIN; without this door it would remove it itself
        // (and open its profile to its siblings) or set one that locks the parents out for 24
        // hours. The door only asks when parental controls are in effect; an adult on an open
        // device gets through without it.
        "profilpin": Door(locked: true),
        "umzug": Door(locked: true),
        "zertifikate": Door(locked: true),
        "uebergabe": Door(locked: true),
        // **The opposite direction, and it needs an entry of its own** (AP23, 11.09.2026). The
        // door above is expressly worded from the **sender's** side ("go … out"); reusing it at
        // the receiver would show a sentence about an outgoing transfer that is not happening at
        // all.
        //
        // **What arrives here overwrites.** A bundle brings logins with it, and it brings parental
        // controls with it — one with `active: false` and without a PIN would switch off the local
        // ones without anyone having seen a PIN. The bolt against that is in
        // ``SecondScreen/Takeover``; this door is the first layer.
        "uebergabeEmpfang": Door(locked: true),
        "kontoEinstellungen": Door(locked: true),
        // **Pairing is a handoff without a wire and without a home network** (AP44,
        // 21.09.2026). It has the same reach as the two doors above and a range that neither of
        // them has: what goes out here goes to a foreign Apple account in a foreign house — with
        // logins, progress and the PIN of this lock. And it stays out there: an accepted share
        // link remains valid until someone withdraws it.
        // **Confirming lifts a lock on ANOTHER device** (AP43, 23.09.2026) — and that is why
        // this door is shut although "forgot PIN" next to it is open.
        //
        // The difference is the direction. `forgotPin` leads to a request with a waiting
        // period: announced, visible, cancellable, for twenty-four hours. Whoever confirms here
        // skips the waiting period and opens the TV **immediately** — that is no longer a way out
        // but the key. If the door stood open, the way for a child with the phone in hand would be
        // shorter than the one via the TV that the waiting period is meant to protect.
        //
        // **The PIN of this device is a different one from the TV's** (see ``Pin``: "On a second
        // device it is assigned anew"). The parent who has forgotten one knows the other — for
        // them the door costs one tap. And where no PIN is set at all there is nothing to
        // protect: then it is open anyway.
        "pinRuecksetzung": Door(locked: true),
        "wolke": Door(locked: true),
        // **Other devices** (AP59 N7) — the same door as "Devices & Sharing" within it: whoever
        // hands over a profile hands over logins and child protection with it.
        "andereGeraete": Door(locked: true),
        "abmelden": Door(locked: true),

        // â Parental controls themselves: the way out is the point -------------------
        // **The most serious finding of the pass ended behind exactly this door.** From the
        // child account, four taps led to the "Adult channels" switch, without a PIN. The switch
        // has since lived **here** and nowhere else — under `Settings → Live` there is only the
        // row that leads here.
        "kindersicherung": Door(locked: true),
        "freigaben": Door(locked: true),
        // **The settings areas that lift nothing** (AP26, 11.09.2026). `SettingsView.door(forItem:)`
        // had always named this name in its `default` — and the table did **not** know it. It
        // worked correctly anyway, because what the table does not know is open; but it appeared
        // nowhere as a **decision**, and nobody could look up why appearance and playback do not
        // ask.
        //
        // **Locking all of them would be the more convenient rule and the wrong one:** a lock
        // that asks at every action gets switched off.
        "einstellungenOffen": Door(locked: false),
        // **The one way that must stay open.** A lock without a way out is not a lock but a
        // defect: whoever has forgotten the PIN would otherwise never get back to their own
        // device.
        "pinVergessen": Door(locked: false),

        // â Settings: all ways in -----------------------------------------------------
        //
        // **`settings` and `einstellungenOffen` are not two policies but two
        // navigations** (AP40, 2026-09-20). On the **phone** "Settings" is a sheet of its own that
        // you enter; this door stands in front of it there. On the **TV** there is no entry point
        // â the list of areas lies open next to it, and what is locked there is whatever can lift a
        // limit: `channelLists`, `portalSettings`, `liveSettings`, `parentalControls`,
        // `accountSettings`.
        //
        // **What the pass reported on 2026-09-19 as drift was one half of that, and a real hole:** the
        // TV mapped everything except parental controls and account to `einstellungenOffen` â
        // **including the three source areas**. A child could thereby reach the switch for the
        // adult channels, on the phone not. Fixed on 2026-09-20 in ``SettingsView/door(forItem:)``, which
        // since then manages without a `default`.
        //
        // **What stays open is the smaller question**, and it is in the phone roadmap: whether the
        // phone should keep locking the *entry*. A child today cannot even reach "Appearance" there,
        // on the TV it can — and the rule "a lock that asks at every action gets switched off"
        // speaks for the TV.
        "einstellungen": Door(locked: true),
        "einrichtung": Door(locked: true),
        "senderlisten": Door(locked: true),
        "senderlisteAendern": Door(locked: true),
        "senderlisteNeu": Door(locked: true),
        "listeLoeschen": Door(locked: true),
        "liveEinstellungen": Door(locked: true),
        "gruppen": Door(locked: true),
        "portaleEinstellungen": Door(locked: true),
        "bewertungenEinstellungen": Door(locked: true),
        "wiedergabe": Door(locked: true),
        "darstellung": Door(locked: true),
        "regaleOrdnen": Door(locked: true),
        "diagnose": Door(locked: true),
        "protokoll": Door(locked: true),

        // â Explicitly open ------------------------------------------------------------
        "vorrat": Door(locked: false),
        "speicher": Door(locked: false),
        // **Open, although it lies behind the settings** (07.09.). "About" carries the version,
        // the privacy policy and the licences — the page that App Store guideline 5.1.1(i)
        // expressly requires to be **easy to reach**. A policy that you only read after a PIN is
        // not easy to reach; and it names neither server address nor account names, unlike the
        // diagnostics.
        "ueber": Door(locked: false),
        "datenschutz": Door(locked: false),
        "lizenzen": Door(locked: false),
        "melden": Door(locked: false),
        "detail": Door(locked: false),
        "detailFilm": Door(locked: false),
        "detailPortal": Door(locked: false),

        // â The tabs themselves and the two playback targets ---------------------------
        // **They are listed here although none of them locks.** The test suite demands an entry
        // for EVERY ID of the app; without these rows the tabs would be the only paths nobody has
        // decided about — and at the next new screen one would no longer know whether "not in the
        // table" was deliberate.
        //
        // **Live and portals are nevertheless not open** — in child mode they are not there at
        // all. That is the ``TabScope`` and not this table: what disappears needs no door.
        "start": Door(locked: false),
        "bibliothek": Door(locked: false),
        "live": Door(locked: false),
        "portale": Door(locked: false),
        "favoriten": Door(locked: false),
        "suche": Door(locked: false),
        "spieler": Door(locked: false),
        "fernbedienung": Door(locked: false),
    ]

    /// Whether this door requires the PIN in child mode.
    ///
    /// **What the table does not know is open** — and that is the only possible direction:
    /// whoever locked an unknown ID would lock the app shut at the next new screen without
    /// anyone noticing. So that no door is forgotten anyway, the test suite demands an entry
    /// for **every** ID.
    /// The doors that parental controls list as **"What the PIN locks"** — the same ones on
    /// both devices (G3, finding C9; until then a list on the phone only).
    ///
    /// **A selection and not the whole table:** the table knows every view; the information
    /// names the doors behind which something lies that lifts or reveals a limit.
    public static let info = [
        "kontowechsel", "einstellungen", "kindersicherung", "senderlisten", "diagnose",
    ]

    public static func locked(_ identifier: String) -> Bool {
        board[identifier]?.locked ?? false
    }

    /// The key of the sentence that explains what lies behind the door — `nil` for a door the
    /// table does not know.
    ///
    /// **The name at the end and no insertion in between:** this way the prefix appears as a
    /// whole word in the source, and the checkers recognise the keys as used.
    public static func reasonKey(_ identifier: String) -> String? {
        board[identifier] == nil ? nil : "childLock.doorReason." + identifier
    }

    /// The sentence itself, in the app's language.
    ///
    /// **Translated before it reaches the UI** — a ``PinTask`` carries it as wording, and
    /// both devices show it as it comes.
    public static func reason(_ identifier: String) -> String? {
        reasonKey(identifier).map { AppLanguageSetting.word(String.LocalizationValue($0)) }
    }
}
