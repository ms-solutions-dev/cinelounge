import Foundation
import Testing

@testable import Core

/// The one competition board — and the check that could not exist before.
///
/// **Why it matters.** Until E6 the tapped leagues stood in PlaylistKit and the EPG
/// placeholders in Core, connected only by string similarity. A league without a
/// placeholder therefore dropped silently out of the placeholder stage — measured,
/// that hit MLS, the EFL Cup and the Euroleague, without a number getting smaller
/// anywhere. It could not be checked: there was no place through which a check could
/// have run.
@Suite("The competition board")
struct SportCompetitionTests {

    /// **Since E7 there are two ways to a vocabulary, and the check knows both.** Until E6
    /// every competition had to bring its words by hand. Since then the source hands over
    /// its own: ESPN names the competition in the head of every answer ("English League
    /// Championship" / "EFL Championship"), and ``SportMatch/sourceWords(_:)`` passes them
    /// on to the placeholder stage.
    ///
    /// Exactly one uses this: `soccer/eng.2`. Its hand-written vocabulary was the bare
    /// "championship" — a generic word that in the real guide of 2026-08-29 belongs to
    /// motorsport in 72 of 74 cases. It therefore stands there **empty**, and the check
    /// allows that precisely for those that get their words from the source — not as an
    /// exception to the rule, but as the second half of it. (The synthetic sports fixtures of
    /// PlaylistKit carry the same trap; `ScheduleFixturesTests` checks it end to end.)
    @Test("Every tapped competition has a vocabulary")
    func everyCompetitionHasAVocabulary() {
        let fromTheSource: Set<String> = ["soccer/eng.2"]
        for competition in SportCompetition.all {
            #expect(
                !competition.lexicon.isEmpty || fromTheSource.contains(competition.path),
                "\(competition.name) is queried, but the program guide cannot name it")
            #expect(!competition.path.isEmpty)
            #expect(competition.tsdb > 0, "\(competition.name) would have no fallback")
        }
    }

    /// **The generic word that was noticed in the acceptance of E6.** "EFL Championship"
    /// is the English second division; "Motocross World Championship" is not. The
    /// vocabulary from the source separates the two, the bare word did not.
    @Test("Championship alone does not name a competition")
    func championshipAloneNamesNothing() {
        let secondDivision = SportCompetition.using(path: "soccer/eng.2")!
        let sourceWords = ["English League Championship", "EFL Championship"]
        #expect(!secondDivision.names(SportKind.normalized("Motocross World Championship")))
        #expect(
            !secondDivision.names(
                SportKind.normalized("Superenduro World Championship 2024"),
                also: sourceWords))
        #expect(
            !secondDivision.names(
                SportKind.normalized("Supercars Championship"), also: sourceWords))
        #expect(
            secondDivision.names(
                SportKind.normalized("Fußball: England, EFL Championship"), also: sourceWords))
    }

    @Test("Every identifier occurs exactly once")
    func identifiersAreUnique() {
        let paths = SportCompetition.all.map(\.path)
        #expect(Set(paths).count == paths.count)
        let numbers = SportCompetition.all.map(\.tsdb)
        #expect(Set(numbers).count == numbers.count)
        #expect(SportCompetition.all.count == 20)
    }

    @Test("The identifier looks it up instead of comparing names")
    func lookupByIdentifier() {
        #expect(SportCompetition.using(path: "soccer/ger.1")?.name == "Bundesliga")
        #expect(SportCompetition.using(path: "basketball/nba")?.kind == .basketball)
        #expect(SportCompetition.using(path: "soccer/gibtesnicht") == nil)
    }

    /// **The rest of the old order.** The old placeholder board had to be sorted — "2.
    /// bundesliga" before "bundesliga", otherwise the shorter string ate the longer one.
    /// The lookup by identifier relieves the order of this task; for the search IN the
    /// program guide it remains, and there it carries ``SportCompetition/except``.
    @Test("A vocabulary does not spill over into the neighboring competition")
    func vocabularyDoesNotSpillOver() {
        func names(_ path: String, _ title: String) -> Bool {
            SportCompetition.using(path: path)?.names(SportKind.normalized(title)) ?? false
        }
        #expect(names("soccer/ger.1", "Bundesliga 26/27"))
        #expect(!names("soccer/ger.1", "2. Bundesliga 26/27"))
        #expect(!names("soccer/ger.1", "Frauen-Bundesliga"))
        #expect(names("soccer/ger.2", "2. Bundesliga 26/27"))
        #expect(names("soccer/esp.1", "LaLiga 26/27"))
        #expect(!names("soccer/esp.1", "LaLiga 2 26/27"))
        // **The measured false hit of the old state** (2026-08-29): "laliga 2" is contained in
        // "laliga 26/27". The channel Zenit 2 names only "LaLiga 26/27" in the whole
        // recording — and still the old state sealed a match of the SECOND Spanish league
        // (Telares – Albería) as verified on it. A digit is as little a word boundary here
        // as a letter.
        #expect(!names("soccer/esp.2", "LaLiga 26/27"))
        #expect(names("soccer/esp.2", "LaLiga 2 26/27"))
        #expect(!names("soccer/fra.1", "Ligue 12"))
        #expect(names("soccer/ita.1", "Serie A: Vesuviana"))
        #expect(!names("soccer/ita.1", "Brasileirao Serie A"))
        #expect(names("soccer/bra.1", "Brasileirao Serie A"))
        #expect(names("soccer/tur.1", "Super Lig Magazin"))
        #expect(!names("soccer/tur.1", "Basketbol Super Ligi"))
        // The three that had no placeholder at all before.
        #expect(names("soccer/usa.1", "MLS: Live"))
        #expect(names("soccer/eng.league_cup", "Carabao Cup 26/27"))
        #expect(names("basketball/euroleague", "Euroleague 26/27"))
    }

    /// **At word boundaries, like everywhere else.** "nba" is not contained in
    /// "Urbnbanana" because there is no word boundary in between — the same rule that
    /// already protects the sport patterns from the substring plague.
    @Test("A competition word in the middle of a word does not count")
    func onlyAtWordBoundaries() {
        let nba = SportCompetition.using(path: "basketball/nba")!
        #expect(nba.names(SportKind.normalized("NBA: Sunhawks")))
        #expect(!nba.names(SportKind.normalized("Turnbank")))
    }
}
