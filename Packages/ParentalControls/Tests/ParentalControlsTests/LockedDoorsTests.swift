import Testing
import WordingKit

@testable import ParentalControls

/// That every door locks — **and the open ones stay open.**
///
/// **The most serious finding of the usability review was here:** From the child account,
/// **four taps** led to the "adult channels" switch, without a PIN. This check is
/// the answer to it — and it is the reason why the doors are a table and
/// not scattered `if` checks.
///
/// **The "sixteen doors" of the roadmap have been recounted**, and the number was no
/// longer right: Views have been added since the design. This check therefore names
/// **no number** but a property — every identifier the app keeps needs
/// an entry. A number would be wrong again with the next screen; the property
/// stays right.
@Suite("Locked doors")
struct LockedDoorsTests {

    /// The paths that must be **closed** in child mode.
    ///
    /// Listed out and not read from the table: A test suite that takes its expectation
    /// from the subject under test checks nothing.
    static let mustBeClosed = [
        "kontowechsel", "konten", "kontoNeu", "umzug", "zertifikate", "kontoEinstellungen",
        // Managing and creating profiles since G3 (2026-09-26), on the phone views of their own.
        "profile", "profilNeu",
        // The profile PIN since AP52: The old PIN proves the owner, not the age.
        "profilpin",
        // The device handoff since 2026-09-10: From it, access tokens, passwords
        // and the PIN of **this** lock go out to another device — to a
        // TV that this lock does not know. The app has no more open door.
        "uebergabe",
        // And the opposite direction since 2026-09-11. (AP23): What comes in here brings
        // access AND a parental control with it — one with `active: false` and without a PIN
        // would switch off the local one without anybody having seen a PIN. An
        // entry of its own and not the same one: The reason at "uebergabe" is worded from the sender's
        // side and would stand at the receiver above a process that does not
        // take place.
        "uebergabeEmpfang",
        // And pairing via iCloud since 2026-09-21. (AP44): the same reach as the
        // two doors above and a reach that neither of them has. What goes out
        // here goes to a foreign Apple account in a foreign house — and it
        // stays out until someone withdraws the share. The wire needs
        // at least the same home network; this path does not.
        "wolke",
        "andereGeraete",
        // And confirming a PIN escape since 2026-09-23. (AP43): It lifts the
        // lock of **another** device immediately — without the waiting period that protects it
        // there. "pinVergessen" stays open next to it because it only files the request.
        "pinRuecksetzung",
        "abmelden", "kindersicherung", "freigaben", "einstellungen", "einrichtung",
        "senderlisten", "senderlisteNeu", "senderlisteAendern", "listeLoeschen",
        "liveEinstellungen", "gruppen",
        "portaleEinstellungen", "bewertungenEinstellungen", "wiedergabe", "darstellung",
        // The log since 2026-09-06: It shows exactly the text that the diagnostics
        // otherwise only submit — so the same door and the same reason.
        "regaleOrdnen", "diagnose", "protokoll",
    ]

    /// The paths that stay **open** — listed with the same weight.
    static let mustBeOpen = [
        "vorrat", "speicher", "detail", "detailFilm", "detailPortal", "pinVergessen",
        // The areas of Settings that lift nothing (AP26, 2026-09-11). The
        // name had always been in the `default` of `SettingsView.door(forItem:)` and was missing
        // from this board — it looked right, but was not a decision that could be looked up.
        "einstellungenOffen",
        "start", "bibliothek", "live", "portale", "favoriten", "suche", "spieler",
        "fernbedienung",
        // **The mandatory pages of the store, since 2026-09-07** "About" carries version,
        // privacy policy and licences — App Store guideline 5.1.1(i) demands them
        // explicitly **easy to reach**, and a policy that you read only after a
        // PIN is not that. "Report" is the route from guideline 1.2; behind a
        // PIN it would be none.
        //
        // **They were in the table and in neither of the two lists** — and exactly that
        // is what ``noOrphans()`` reported. This check was thereby not a nuisance
        // but did what it is there for: It catches every door about which
        // nobody has decided here.
        "ueber", "datenschutz", "lizenzen", "melden",
    ]

    @Test("Every locked door requires the PIN")
    func allClosed() {
        for door in Self.mustBeClosed {
            #expect(LockedDoors.locked(door), "\(door) muss zu sein")
        }
    }

    /// **The downloads, storage and every detail page stay open.** A child may
    /// see what it may see — the limit lies with the title, not with the screen.
    @Test("The open paths stay open")
    func allOpen() {
        for door in Self.mustBeOpen {
            #expect(!LockedDoors.locked(door), "\(door) muss offen bleiben")
        }
    }

    /// **The one path that must stay open.** A lock without an escape is not a
    /// lock but a defect: Whoever has forgotten the PIN would otherwise never get back to
    /// their own device.
    @Test("The \"forgot PIN\" path is never closed")
    func recovery() {
        #expect(!LockedDoors.locked("pinVergessen"))
        #expect(LockedDoors.reason("pinVergessen") != nil)
    }

    /// **A sentence of its own per door.** "Not allowed" explains nothing; whoever stands in front of a
    /// locked door wants to know what lies behind it.
    @Test("Every door carries its own reason")
    func everyReasonOwn() {
        for door in Self.mustBeClosed + Self.mustBeOpen {
            let reason = LockedDoors.reason(door)
            #expect(reason != nil, "\(door) hat keinen Grund")
            #expect(!(reason ?? "").isEmpty)
        }
    }

    /// **Every reason is translated** (AP58 final step, report B finding 3). Until then
    /// the reasons stood as German raw text in the board and appeared in German in English and
    /// Turkish.
    @Test("Every reason is in the shared catalog in three languages")
    func everyReasonTranslated() throws {
        for door in LockedDoors.board.keys {
            let key = try #require(LockedDoors.reasonKey(door))
            let variants = ["de", "en", "tr"].map {
                WordingKit.text(String.LocalizationValue(key), language: $0)
            }
            #expect(variants.allSatisfy { $0 != key }, "\(door): \(key) fehlt")
            #expect(Set(variants).count == 3, "\(door): nicht in jeder Sprache eigen")
        }
        #expect(LockedDoors.reasonKey("gibtesnicht") == nil)
    }

    /// **The table must not know anything the app does not keep.** An entry for a
    /// view that no longer exists is a rule about nothing — and on the next
    /// reading somebody believes it is in force.
    @Test("The table lists exactly the two lists and nothing else")
    func noOrphans() {
        let expected = Set(Self.mustBeClosed + Self.mustBeOpen)
        #expect(Set(LockedDoors.board.keys) == expected)
    }

    /// **What the table does not know is open** — the only possible direction: Whoever
    /// locked an unknown identifier would lock up the app at the next new screen
    /// without anybody noticing.
    @Test("An unknown identifier does not lock")
    func unknownIsOpen() {
        #expect(!LockedDoors.locked("gibtesnicht"))
    }

    // MARK: - The facade

    /// **Without a PIN nothing takes effect.** A lock without a stored PIN could be lifted by anyone with two
    /// taps; showing it would claim something that is not true.
    @Test("Without a PIN child mode locks nothing")
    func noPinNoLock() {
        let without = ProtectionRule(deviceLocked: true, isPinSet: false)
        #expect(!without.applies)
        #expect(!without.requiresPin(forItem: "einstellungen"))
    }

    /// **Two sources, and the stricter one applies.** A child with a parent's phone
    /// has no child account; a child account at which an adult is sitting
    /// may have the switch off.
    @Test("Device state and account type each lock on their own")
    func bothSources() {
        let viaDevice = ProtectionRule(
            deviceLocked: true, accountKind: .adult, isPinSet: true)
        let viaAccount = ProtectionRule(
            deviceLocked: false, accountKind: .kind, isPinSet: true)
        let none = ProtectionRule(
            deviceLocked: false, accountKind: .adult, isPinSet: true)

        #expect(viaDevice.applies)
        #expect(viaAccount.applies)
        #expect(!none.applies)
    }

    /// **The finding of back then, as a test suite:** four taps to the switch
    /// "adult channels", without a PIN. The path there leads via `settings` and
    /// `liveSettings` — both are now closed.
    @Test("The path to the \"adult channels\" switch is closed")
    func theFindingFromBack() {
        let locked = ProtectionRule(deviceLocked: true, isPinSet: true)
        for step in ["einstellungen", "liveEinstellungen"] {
            #expect(locked.requiresPin(forItem: step), "\(step) war der Weg dorthin")
        }
    }

    /// **Live and portals disappear, not dimmed.** There are no ratings for them
    /// — 7,746 channels without an age rating, and a portal catalog is read from foreign pages.
    @Test("In child mode Live and portals drop out")
    func tabScope() {
        let locked = ProtectionRule(deviceLocked: true, isPinSet: true)
        #expect(!locked.scope.remains("live"))
        #expect(!locked.scope.remains("portale"))
        #expect(locked.scope.remains("start"))
        #expect(locked.scope.remains("bibliothek"))
        #expect(locked.scope.remains("suche"))
        // And their titles must not appear via other paths either — otherwise the
        // removed tab would be mere decoration.
        #expect(!locked.scope.delivers("senderliste"))
        #expect(!locked.scope.delivers("portale"))
        #expect(locked.scope.delivers("medienserver"))
    }

    @Test("Without a lock every tab stays")
    func withoutLockEverything() {
        let pending = ProtectionRule(deviceLocked: false, isPinSet: true)
        #expect(pending.scope.remains("live"))
        #expect(pending.scope.delivers("portale"))
    }
}
