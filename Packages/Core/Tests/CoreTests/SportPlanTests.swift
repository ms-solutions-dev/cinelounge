import Foundation
import Testing

@testable import Core

/// The schedule: detect the sport, sort out reruns, merge events —
/// on titles from the REAL provider EPG (dump of 2026-08-16).
@Suite("Schedule: events are built from the program guide")
struct SportPlanTests {

    private func programs(
        _ title: String, epg: String = "kanal.1", startOffset: TimeInterval = 0,
        length: TimeInterval = 7200
    ) -> Programme {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000 + startOffset)
        return Programme(
            id: "\(epg)-\(title)-\(startOffset)", channelID: epg, title: title,
            start: start, end: start.addingTimeInterval(length))
    }

    @Test("The sport is in the title — across languages")
    func kindsAreRecognized() {
        #expect(
            SportKind.classify(title: "Live Liga Portugal: Rio Lume-Serrano Etapa 2") == .football)
        #expect(
            SportKind.classify(title: "Piłka nożna: 2. Bundesliga: 1. FC Kaiserfeld - Karlstaler SC")
                == .football)
        #expect(SportKind.classify(title: "Süper Lig: Demirbahçe - Kalesaray") == .football)
        #expect(SportKind.classify(title: "Formel 1: Großer Preis der Niederlande") == .motorsport)
        #expect(SportKind.classify(title: "ATP Jadeport: Halbfinale") == .tennis)
        #expect(SportKind.classify(title: "Boks: Kalberg - Serrat") == .fighting)
        #expect(SportKind.classify(title: "Voleybol Sultanlar Ligi: Final") == .volleyball)
        #expect(SportKind.classify(title: "NHL: Frostbears - Ironwolves") == .iceHockey)

        // The channel name helps when the title is silent.
        #expect(SportKind.classify(title: "Sunhawks - Pinecrests", channelName: "NBA Arena") == .basketball)

        // A cooking magazine stays a cooking magazine, even on a sports channel.
        #expect(SportKind.classify(title: "Die Pfannenparade") == nil)
    }

    @Test("A bare pairing on the league channel: the channel says football")
    func leagueChannelCarriesTheKind() {
        // On-device finding 2026-08-16. (too much content missing): the Süper Lig matches
        // appear in the EPG only under the pairing — football is not named anywhere
        // except in the channel.
        #expect(
            SportKind.classify(title: "Demirbahçe - Bulutspor", channelName: "Pusula SPORTS 1 FHD")
                == .football)
        #expect(
            SportKind.classify(title: "Gökyamaç - Dumanspor", channelName: "TR: Pusula SPORTS 1")
                == .football)
        // The title beats the channel: basketball on Pusula stays basketball.
        #expect(
            SportKind.classify(
                title: "Basketbol: Anadolu Ova - Demirbahçe Kolay",
                channelName: "PUSULA SPORTS MAX 1") == .basketball)
        // KULE-SPORT airs LaLiga as a bare pairing — the channel carries it
        // (Zenit lookup 2026-08-16); "Wassersport" stays out thanks to the word boundary.
        #expect(
            SportKind.classify(title: "Gaitero Vimar - Olmedo", channelName: "TR: KULE-SPORT 1 FHD")
                == .football)
        #expect(
            SportKind.classify(title: "Torrelinda - Lagares", channelName: " kulesport2.tr") == .football)
        #expect(SportKind.classify(title: "Regatta - Rückblick", channelName: "Wassersport TV") == nil)
        // The provider mangles the display names — the programme identifier
        // still carries the detection (the schedule passes it along).
        #expect(
            SportKind.classify(
                title: "Gökyamaç - Dumanspor",
                channelName: "TR: b**N SP*RTS 1 | HD pusulasports1.tr") == .football)
    }

    @Test("From EPG to card: the Süper Lig match on the league channel")
    func bareLeaguePairingBecomesAnEvent() {
        // The on-device finding case, end to end: bare pairing, no football
        // word, mangled channel name — only the identifier carries.
        let events = SportPlan.events(
            from: [programs("Gökyamaç - Dumanspor", epg: "pusulasports1.tr")],
            channelNames: ["pusulasports1.tr": "TR: b**N SP*RTS 1 | HD"])
        #expect(events.count == 1)
        #expect(events.first?.kind == .football)
        #expect(SportPlan.pairing(in: events.first?.title ?? "")?.home == "Gökyamaç")
    }

    @Test("Precision beats order: the longer pattern wins")
    func mostSpecificPatternWins() {
        // Real EPG titles that used to pass as football because "super lig"
        // was checked before "basketbol".
        #expect(SportKind.classify(title: "Basketbol Süper Lig Özetler") == .basketball)
        #expect(SportKind.classify(title: "Basketbol: Kadınlar Süper Ligi") == .basketball)
        #expect(SportKind.classify(title: "Ova Sigorta Basketbol Süper Ligi") == .basketball)
        // And the other way around, football stays football.
        #expect(SportKind.classify(title: "Süper Lig: Demirbahçe - Kalesaray") == .football)
    }

    @Test("Magazines and repeats drop out")
    func magazinesAndRerunsAreDropped() {
        // Real EPG title: news on a sports channel — no pairing,
        // no live marker, no event.
        #expect(!SportPlan.isLiveEvent("Stirile Digi Sport"))
        // Rerun markers beat everything — even a pairing.
        #expect(!SportPlan.isLiveEvent("Süper Lig Maç Özeti: Demirbahçe - Kalesaray"))
        #expect(!SportPlan.isLiveEvent("Bundesliga Highlights"))

        // Goal shows of the league channels (2026-08-16): thanks to the hyphen they look
        // like pairings but are not broadcasts.
        #expect(!SportPlan.isLiveEvent("Süper Lig Haftanın Golleri"))
        #expect(!SportPlan.isLiveEvent("1 Yıldız 10 Gol - Van Kerstıe"))
        #expect(!SportPlan.isLiveEvent("Premier League Goller"))

        // What stays: the pairing, the race, the live marker.
        #expect(SportPlan.isLiveEvent("Jogo Grande - Rio Lume FC x FC Serrano (Direto)"))
        #expect(SportPlan.isLiveEvent("Rio Lume-Serrano"))
        #expect(SportPlan.isLiveEvent("Großer Preis der Niederlande: Qualifying"))
    }

    @Test("Competition and pairing are extracted from the title")
    func titlesAreParsed() {
        let (competition, event) = SportPlan.parsed("Live Liga Portugal: Rio Lume-Serrano Etapa 2")
        #expect(competition == "Liga Portugal")
        #expect(event == "Rio Lume-Serrano Etapa 2")

        let pairing = SportPlan.pairing(in: "Süper Lig: Demirbahçe - Kalesaray")
        #expect(pairing?.home == "Demirbahçe")
        #expect(pairing?.away == "Kalesaray")

        // The hyphen in the competition name does not cut a pairing apart.
        #expect(
            SportPlan.pairing(in: "DFB-Pokal: Bergland München - Rheinufer Köln")?.home == "Bergland München")
    }

    @Test("The same match on several channels is ONE entry")
    func sameMatchMergesAcrossChannels() {
        let events = SportPlan.events(from: [
            programs("Süper Lig: Demirbahçe - Kalesaray", epg: "pusula1.tr"),
            programs("Süper Lig: Demirbahçe - Kalesaray", epg: "kanal1.tr", startOffset: 600),
            programs("Süper Lig: Demirbahçe - Kalesaray", epg: "pusula1hd.tr"),
            // A different match at the same time — stays a separate entry.
            programs("Süper Lig: Yeşiltaş - Dalgaspor", epg: "pusula2.tr"),
        ])

        #expect(events.count == 2)
        let derby = events.first { $0.title.contains("Demirbahçe") }
        #expect(derby?.epgIDs.sorted() == ["kanal1.tr", "pusula1.tr", "pusula1hd.tr"])
        #expect(derby?.competition == "Süper Lig")
    }

    @Test("Several airings on one broadcast day yield ONE row")
    func rerunsWithinTheDayCollapse() {
        // On-device finding 2026-08-16. (many items have nothing to do with live):
        // Pusula repeats the same match three times without marking it.
        // It stays at one row.
        let events = SportPlan.events(from: [
            programs("Kumsalspor - Demirbahçe", epg: "pusulasports1.tr"),
            programs("Kumsalspor - Demirbahçe", epg: "pusulasports1.tr", startOffset: 6 * 3600),
            programs("Kumsalspor - Demirbahçe", epg: "pusulasports1.tr", startOffset: 12 * 3600),
            // A different match stays untouched.
            programs("Gökyamaç - Dumanspor", epg: "pusulasports1.tr", startOffset: 4 * 3600),
        ])
        #expect(events.count == 2)
    }

    @Test("With equal duration the later airing of the broadcast day wins")
    func laterAiringWinsWhenDurationSaysNothing() {
        // **The reversal of the old rule, and it is measured** (2026-08-29): the
        // Turkish Pusula channels air the pre-recorded version in the morning and live in the evening.
        // "The first broadcast wins" systematically picked the pre-recorded one —
        // on the dump that cost nine of today's matches.
        let events = SportPlan.events(from: [
            programs("Demirbahçe - Tarlaspor", epg: "pusulasports1.tr"),
            programs("Demirbahçe - Tarlaspor", epg: "pusulasports1.tr", startOffset: 6 * 3600),
        ])
        #expect(events.count == 1)
        #expect(
            events.first?.start
                == Date(timeIntervalSinceReferenceDate: 800_000_000 + 6 * 3600))
    }

    @Test("The longer airing beats the later one — it is the broadcast")
    func longerAiringWins() {
        // A pre-recorded version is cut together. If the earlier one runs two
        // hours and the later one only one, the earlier one is the match.
        let events = SportPlan.events(from: [
            programs("Demirbahçe - Tarlaspor", epg: "pusulasports1.tr", length: 7200),
            programs(
                "Demirbahçe - Tarlaspor", epg: "pusulasports1.tr", startOffset: 6 * 3600,
                length: 3600),
        ])
        #expect(events.count == 1)
        #expect(events.first?.start == Date(timeIntervalSinceReferenceDate: 800_000_000))
    }

    @Test("Beyond the look-back window it is a separate event")
    func beyondTheLookbackItIsItsOwnEvent() {
        // **The bug that E2 fixes:** the rule looked back without a time limit.
        // `SportModel` also reads two days before the window so that the
        // first broadcast can swallow its reruns — and so the match of yesterday
        // swallowed the match of today. Beyond ``SportPlan/rerunWindow`` there are
        // two events; which day is shown is then decided by the day cut.
        let events = SportPlan.events(from: [
            programs("Demirbahçe - Tarlaspor", epg: "pusulasports1.tr"),
            programs("Demirbahçe - Tarlaspor", epg: "pusulasports1.tr", startOffset: 24 * 3600),
        ])
        #expect(events.count == 2)
    }

    @Test("The competition belongs in the key — Moto2 is not MotoGP")
    func competitionSeparatesTheKey() {
        // Measured 2026-08-29: the MotoGP race was missing from the schedule because "Moto 2"
        // two days earlier had occupied the same key. The EPG journal
        // writes the class into the competition part before the colon.
        let events = SportPlan.events(from: [
            programs("Moto 2: Grand Prix von Valmont", epg: "bergtv.de"),
            programs(
                "MotoGP: Grand Prix von Valmont", epg: "bergtv.de", startOffset: 4 * 3600),
        ])
        #expect(events.count == 2)
    }

    @Test("Two spellings of the same team are one event")
    func teamCoresJoinSpellings() {
        #expect(SportPlan.teamCore("F. Akgümrük") == SportPlan.teamCore("Akgümrük"))
        #expect(SportPlan.teamCore("1. FC Sündorf") == SportPlan.teamCore("FC Sündorf"))
        // And what is different stays different — the core is not a
        // similarity measure.
        #expect(SportPlan.teamCore("Bergland München") != SportPlan.teamCore("Bergland Munich"))
        let events = SportPlan.events(from: [
            programs("F. Akgümrük - Kozaspor", epg: "pusulasports1.tr"),
            programs("Akgümrük - Kozaspor", epg: "pusulasports2.tr", startOffset: 4 * 3600),
        ])
        #expect(events.count == 1)
    }

    // MARK: - Die Eintrittskarten des Ereignis-Nachweises

    @Test("The slash separates the pairing — before the bare hyphen")
    func slashSeparatesBeforeTheBareHyphen() {
        // The French market writes exclusively "home / away".
        #expect(SportPlan.pairing(in: "Blue Comet / Valmeuse")?.home == "Blue Comet")
        #expect(SportPlan.pairing(in: "Blue Comet / Valmeuse")?.away == "Valmeuse")
        // And the order is the rule: without the precedence the bare hyphen
        // in "Lutèce-SG / Bellerive" turned the pairing into
        // "Lutèce" against "SG / Bellerive".
        let pairing = SportPlan.pairing(in: "Lutèce-SG / Bellerive")
        #expect(pairing?.home == "Lutèce-SG")
        #expect(pairing?.away == "Bellerive")
    }

    /// **The bare hyphen no longer turns rights packages into pairings**
    /// (E7; open finding from the acceptance of E2).
    ///
    /// Measured on the dump of 2026-08-29, five such rows were in the
    /// schedule — "Fußball-Bundesliga", "Fußball: DFB-Pokal", "Fußball:
    /// DFB-Pokal Junioren", "Fußball: Frauen-Bundesliga" and "FIFA Fußball-WM
    /// 2026 Achtelfinale". According to the concept (§2) the section is meant to show exactly
    /// those not.
    ///
    /// **The rule is asymmetric, and the second block here is the
    /// reason.** On the left no sport name may stand (German
    /// compounds write `Sportart-Wettbewerb`), on the right no
    /// competition or rights-package word. The reverse holds for neither —
    /// otherwise "Valdoria-Marathon", "FIA-Weltmeisterschaft Valmont" and "2026
    /// E-spor Dünya Kupası" would be lost too, and those are real events. The
    /// symmetric version would have killed three of them on the same dump.
    @Test("The bare hyphen joins words instead of separating opponents")
    func bareHyphenDoesNotSplitCompetitions() {
        // Rights packages: no pairing, and thus no row.
        #expect(SportPlan.pairing(in: "Fußball-Bundesliga") == nil)
        #expect(SportPlan.pairing(in: "Fußball: Frauen-Bundesliga") == nil)
        #expect(SportPlan.pairing(in: "Fußball: DFB-Pokal") == nil)
        #expect(SportPlan.pairing(in: "Fußball: DFB-Pokal Junioren") == nil)
        #expect(SportPlan.pairing(in: "FIFA Fußball-WM 2026 Achtelfinale") == nil)
        #expect(!SportPlan.isLiveEvent("Fußball-Bundesliga"))

        // Real events that the symmetric rule would have taken along:
        // a sport name on the right, a place name on the left.
        #expect(SportPlan.pairing(in: "Marathon: Valdoria-Marathon") != nil)
        #expect(SportPlan.pairing(in: "Radsport: Valmora-Tour") != nil)
        #expect(SportPlan.pairing(in: "Formel E: FIA-Weltmeisterschaft Valmont") != nil)
        #expect(SportPlan.pairing(in: "2026 E-spor Dünya Kupası") != nil)

        // And the real pairing with a bare hyphen stays one: only the word
        // DIRECTLY at the hyphen is checked, not the whole rest.
        let real = SportPlan.pairing(in: "Sahilspor-Ekip Grup Sarıdere")
        #expect(real?.home == "Sahilspor")
        #expect(real?.away == "Ekip Grup Sarıdere")
        #expect(SportPlan.pairing(in: "Rio Lume-Serrano")?.away == "Serrano")
    }

    @Test("The live marker only counts as a word of its own")
    func liveMarkersOnlyAtWordBoundaries() {
        // "live" is contained in "Livernholm" and in "Oliver" — without a word boundary
        // it would have knighted the marker of every magazine in which one of them appeared.
        #expect(!SportPlan.isLiveEvent("Olivera Krumbach"))
        #expect(!SportPlan.isLiveEvent("Livernholm Legends: Das Magazin"))
        #expect(SportPlan.isLiveEvent("LIVE: Premier League"))
        // Capitalised, as the Turkish channels write it.
        #expect(SportPlan.isLiveEvent("CANLI: Süper Lig"))
    }

    @Test("The tournament word is the third ticket in — and lets no filler through")
    func tournamentWordIsTheThirdTicket() {
        // Tournament and stage formats have no opponent. Without this map
        // they would all drop out: Ronda 22 broadcasts → 0, Lindmar Open 5 → 0,
        // Euroleague 4 → 0, WTA 4 → 0, Golf 25 → 0.
        #expect(SportPlan.isLiveEvent("La Ronda a Valmora , 8. Etap"))
        #expect(SportPlan.isLiveEvent("Tennis: Lindmar Open"))
        #expect(SportPlan.isLiveEvent("Snooker: Kesterby Open"))
        #expect(SportPlan.isLiveEvent("Golf: Ladies European Tour"))
        #expect(SportPlan.isLiveEvent("2e tour"))

        // **And this is the line the concept draws.** Reversing filter 2
        // ("a detected sport is enough") yields, measured, 155 → 770
        // broadcasts, among them 56 rows of "Sendepause". The word list lets
        // none of them in — none of these titles carries a tournament word.
        #expect(!SportPlan.isLiveEvent("Sendepause"))
        #expect(!SportPlan.isLiveEvent("Premier League"))
        #expect(!SportPlan.isLiveEvent("Ça se passe sur ARENA SPORT"))
        #expect(!SportPlan.isLiveEvent("Eredivisie"))
        #expect(!SportPlan.isLiveEvent("Fußball: Bundesliga"))
    }

    @Test("Studio panels and goal shows stay out")
    func studioAndGoalShowsStayOut() {
        // They only got in with the tournament word — they carry the same
        // words as the match they are built around.
        #expect(!SportPlan.isLiveEvent("Avant-match Ligue 2"))
        #expect(!SportPlan.isLiveEvent("Après-match"))
        #expect(!SportPlan.isLiveEvent("Pitchside - Supercup 26/27"))
        #expect(!SportPlan.isLiveEvent("Supercup Backstage - Hinter den Kulissen"))
        #expect(!SportPlan.isLiveEvent("Die Telefunk Highlight-Show"))
        #expect(!SportPlan.isLiveEvent("Fußball: 2. Bundesliga, Alle Spiele, alle Tore"))
    }

    @Test("Turkish suffixes belong to the word, foreign syllables do not")
    func turkishSuffixesCountAsPartOfTheWord() {
        // Turkish glues its endings on: "Süper Lig" becomes "Süper
        // Ligi", "Bisiklet" becomes "Bisikleti", "Maraton" becomes "Maratonu".
        #expect(SportKind.classify(title: "Valdoria Maratonu") == .athletics)
        #expect(SportKind.classify(title: "2026 Dünya Dağ Bisikleti Şampiyonası") == .cycling)
        // The bare league title, without a counterpart word. Until the acceptance on
        // 2026-08-29 this had "Basketbol: Kadınlar Süper Ligi" — that did not prove this rule:
        // it matches "basketbol" and is also detected without the suffix chain
        // (re-measured), and as a pattern-precedence case it is
        // already in ``mostSpecificPatternWins``. Without "Lig"+"i" this
        // row turns red, that one does not.
        #expect(SportKind.classify(title: "Kadınlar Süper Ligi") == .football)
        // And the control from the same dump: what only looks like an
        // ending is not one. Without this boundary these would all be
        // combat-sports and football broadcasts.
        #expect(SportKind.classify(title: "Sommaire Premier League") == .football)
        #expect(SportKind.classify(title: "Kloster TV Abendlob") == nil)
        #expect(SportKind.classify(title: "Senza programmazione") == nil)
        #expect(SportKind.classify(title: "torrr! Das internationale Fussballmagazin") == nil)

        // **The price of the rule, measured and recorded (acceptance 2026-08-29).**
        // Calculated over the uncut recording — 29,259 broadcasts across
        // all 492 channels, not just the sports channels of the dump —
        // the suffix chain wins exactly three titles, and one of them is
        // wrong: "Tomi'nin Bisikleti" on BABY TV, eight times that day, a
        // children's cartoon as cycling. The schedule stays untouched because
        // filter 2 stops it — neither pairing nor live nor tournament word —,
        // but the sport chips counted it. Two right against one
        // wrong is the whole balance of this rule; whoever extends it measures
        // that against the uncut file and not against the
        // dump, which does not contain BABY TV at all.
        #expect(SportKind.classify(title: "Tomi'nin Bisikleti") == .cycling)
        #expect(!SportPlan.isLiveEvent("Tomi'nin Bisikleti"))
    }

    @Test("The four new sports are recognized")
    func theFourNewKinds() {
        // Together 92 broadcasts in the dump of 2026-08-29, and none
        // could ever get into the schedule.
        #expect(SportKind.classify(title: "Snooker: Kesterby Open") == .snooker)
        #expect(SportKind.classify(title: "Rugby à 7 : In Extenso Maxisevens") == .rugby)
        #expect(SportKind.classify(title: "Motocross World Championship") == .motocross)
        #expect(SportKind.classify(title: "Judo : Grand Slam de Valcourt") == .judo)
        #expect(SportKind.classify(title: "Formule E : ePrix de Valmont") == .motorsport)
        #expect(SportKind.classify(title: "Formel E: FIA-Weltmeisterschaft Valmont") == .motorsport)
        #expect(SportKind.classify(title: "Fractionné WRC") == .motorsport)
    }

    @Test("The phrase World Cup alone does not make football")
    func worldCupAloneIsNotFootball() {
        // The "Kessler-Dorn Bagger World Cup" appeared as a football match in the
        // schedule. The real football World Cup is called something
        // different in this EPG journal — so it is not lost.
        #expect(SportKind.classify(title: "Kessler-Dorn Bagger World Cup") == nil)
        #expect(SportKind.classify(title: "FIFA Fußball-WM 2026 Achtelfinale") == .football)
        #expect(SportKind.classify(title: "DÜNYA KUPASI: MAROVIA - ISTERYA") == .football)
    }

    @Test("Finding 29.08.: the dotless ı survives case folding")
    func dotlessIStaysUnfolded() {
        // **A found defect, deliberately not fixed.** The
        // comparison form folds diacritics away — "ü" becomes "u", "ş"
        // becomes "s". But the Turkish "ı" is not an "i" with a missing dot,
        // it is a letter of its own with no decomposition; it stays.
        // So every pattern that writes an "i" does not match its
        // lowercase Turkish counterpart.
        //
        // **Why it stays like this anyway:** measured on the dump of 2026-08-29,
        // this affects exactly five broadcasts — "2026 E-spor Dünya
        // Kupası" (3) and "Fiba Dünya Kupası Elemeleri" (2). Both are
        // detected through another pattern ("e-spor", "fiba"), so the schedule
        // gains **zero** events. Against that would stand a change to
        // ``SportKind/normalized(_:)``, and that is the
        // comparison form of the whole merge. A rule without
        // measured benefit is not worth intervening there.
        //
        // This check records the finding so that it does not have to be found
        // twice. If the folding is ever changed, it turns red and
        // points to this paragraph.
        #expect(SportKind.normalized("Dünya Kupası") == "dunya kupası")
        #expect(SportKind.classify(title: "Dünya Kupası: Marovia - İsterya") == nil)
    }

    @Test("Patterns only apply at word boundaries")
    func patternsRespectWordBoundaries() {
        // The substring plague of 2026-08-16 — all real EPG titles:
        #expect(SportKind.classify(title: "Voci di Paese - Puntata del 16/08/2026") == nil)
        #expect(SportKind.classify(title: "Volgend programma om 06:00") == nil)
        #expect(SportKind.classify(title: "Bruno i jego paczka") == nil)
        #expect(SportKind.classify(title: "Kursblitz") == nil)
        #expect(SportKind.classify(title: "Kanadalı Kehribar Avcıları") == nil)
        // And the real ones stay: a boundary means a boundary, not a word start.
        #expect(SportKind.classify(title: "Sporty walki: Babilon MMA 51") == .fighting)
        #expect(SportKind.classify(title: "NFL - Stormriders x Canyoners") == .americanFootball)
        #expect(SportKind.classify(title: "Superliga: FCVL-Moravita Etapa 5") == .football)
        #expect(SportKind.classify(title: "Formel 1: Großer Preis, F1 Qualifying") == .motorsport)
    }

    // MARK: - Das Sendersignal je Sender (E5)

    /// **What the speed-up could break, and why it does not.**
    /// Since E5, ``SportPlan/events(from:channelNames:)`` computes the
    /// channel signal once per channel instead of once per broadcast. The one way
    /// this kind of thing goes wrong is an index that gives the answer of one
    /// channel to the next — and that would only be noticed on the TV if
    /// someone counted, because the row would be there, just under the wrong
    /// chip.
    ///
    /// The check reproduces exactly that: three channels with three different
    /// signals, their broadcasts passed in **alternately**, and not a
    /// single one of them names its sport in the title. What comes out here comes
    /// exclusively from the channel.
    @Test("The per-channel channel signal does not mix channels")
    func channelSignalStaysWithChannel() {
        let events = SportPlan.events(
            from: [
                // Pusula is recognised only by ``SportKind/channelPatterns`` — the
                // weakest of the three levels.
                programs("Kalesaray - Dalgaspor", epg: "pusulasports1.tr", startOffset: 0),
                // "NBA Arena" matches an ordinary pattern in the channel name.
                programs("Sunhawks - Pinecrests", epg: "nba.us", startOffset: 3600),
                programs("Yesiltas - Demirbahce", epg: "pusulasports1.tr", startOffset: 7200),
                programs("Tidewaters - Ridgebacks", epg: "nba.us", startOffset: 10800),
                // A channel without any signal: the pairing alone does not yet make
                // a sport, the row must not even come into being.
                programs("Meier - Schulze", epg: "regional.de", startOffset: 14400),
            ],
            channelNames: [
                "pusulasports1.tr": "Pusula SPORTS 1", "nba.us": "NBA Arena",
                "regional.de": "Regionalfenster",
            ])

        let perIdentifier = Dictionary(
            uniqueKeysWithValues: events.map { ($0.epgIDs[0] + "#" + $0.title, $0.kind) })
        #expect(perIdentifier["pusulasports1.tr#Kalesaray - Dalgaspor"] == .football)
        #expect(perIdentifier["pusulasports1.tr#Yesiltas - Demirbahce"] == .football)
        #expect(perIdentifier["nba.us#Sunhawks - Pinecrests"] == .basketball)
        #expect(perIdentifier["nba.us#Tidewaters - Ridgebacks"] == .basketball)
        #expect(events.count == 4)
    }

    /// And the order of the two channel levels stays as it was: an
    /// ordinary pattern in the name beats the league channel board.
    @Test("The channel signal keeps the order of the two lower tiers")
    func channelSignalKeepsTheOrder() {
        // "NBA Arena" matches `patterns`, nothing else.
        #expect(SportKind.channelSignal("NBA Arena") == .basketball)
        // "Pusula SPORTS 1" matches only `channelPatterns`.
        #expect(SportKind.channelSignal("Pusula SPORTS 1 pusulasports1.tr") == .football)
        // A channel that carries both: the ordinary pattern wins, because it
        // stands one level higher in the rule.
        #expect(SportKind.channelSignal("Pusula SPORTS Basketbol") == .basketball)
        // No signal is also an answer — and the empty string must
        // not happen to match a sport.
        #expect(SportKind.channelSignal("Regionalfenster") == nil)
        #expect(SportKind.channelSignal("") == nil)
        // And the title still beats the channel.
        #expect(
            SportKind.classify(title: "Voleybol: Demirbahce - Cinicibasi", channelSignal: .football)
                == .volleyball)
        #expect(SportKind.classify(title: "Kalesaray - Dalgaspor", channelSignal: .football) == .football)
    }

    @Test("Equestrian is not esports")
    func equestrianIsNotEsports() {
        // On-device finding 2026-08-16: "esport" is contained as a substring in
        // "Pferdesport" — the FEI World Championships from Aachen were listed under e-sports.
        #expect(
            SportKind.classify(title: "Pferdesport FEI Weltmeisterschaft 2026: Vielseitigkeit")
                == .equestrian)
        #expect(SportKind.classify(title: "FEI Weltmeisterschaft: Springen aus Aachen") == .equestrian)
        // And real e-sports stays e-sports.
        #expect(SportKind.classify(title: "Esports Nordcup: Lave-Breitia Finale") == .esports)
    }
}

/// A pairing is not an endurance run.
///
/// **On-device finding 2026-08-29, 21:00:** the Sport section
/// showed Mill U against Ashwick from 17:30 although it was already 21:00 and the
/// match was long over. In the EPG journal this fixture runs from 18:30 to 07:45
/// local time, thirteen hours long, and therefore stayed marked as live all evening.
@Suite("The duration cap only applies to pairings")
struct PairingDurationTests {

    private func broadcast(_ title: String, hours: Double) -> Programme {
        let start = Date(timeIntervalSince1970: 1_788_016_800)
        return Programme(
            id: "kanal#1#\(title)", channelID: "kanal", title: title, start: start,
            end: start.addingTimeInterval(hours * 3600), description: nil)
    }

    @Test("A thirteen-hour pairing is truncated")
    func pairingIsCapped() {
        let long = broadcast("Mill Utd - Ashwick", hours: 13)

        let end = SportPlan.end(from: long, title: "Mill Utd - Ashwick")

        #expect(end == long.start.addingTimeInterval(SportPlan.pairingAtMost))
    }

    @Test("A short pairing stays as it is")
    func shortOneStays() {
        let normal = broadcast("Mill Utd - Ashwick", hours: 2)

        #expect(SportPlan.end(from: normal, title: "Mill Utd - Ashwick") == normal.end)
    }

    /// **And this is the reason for the restriction.** The concept rejects a
    /// general duration cap, as measured: it would kill the "Ultra-Trail du
    /// Mont-Valmeur" and the 165 other broadcasts over six hours — precisely
    /// the formats the section exists for.
    @Test("An ultra run keeps going as long as it wants")
    func noCapWithoutPairing() {
        let trail = broadcast("Ultra-Trail du Mont-Valmeur", hours: 20)

        #expect(SportPlan.end(from: trail, title: "Ultra-Trail du Mont-Valmeur") == trail.end)
    }
}
