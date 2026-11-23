import Foundation
import Testing

@testable import Core

/// The team cores — what the matching claims is the same team.
///
/// **The finding from E6:** a core that both sides carry cannot separate the sides.
/// "Covewood City – Hollin City" required of a title, via the single formation, only
/// that "City" appears somewhere — once for the home side, once for the away side, and
/// both times satisfied by the same word. That way this fixture sealed every broadcast
/// with "City" in the title, and that with `isVerified`, the mark that is supposed to
/// say that the row is watertight.
@Suite("The team cores of the matching")
struct SportCoresTests {

    static func fixture(
        _ home: String, _ away: String,
        homeVariants: [String] = [], awayVariants: [String] = []
    ) -> SportFixture {
        SportFixture(
            id: "espn#1", source: .espn, path: "soccer/eng.2", kind: .football,
            league: "English League Championship", home: home, away: away,
            start: Date(timeIntervalSince1970: 1_787_000_000),
            homeVariantsList: homeVariants, awayVariantsList: awayVariants)
    }

    @Test("A core shared by both sides drops out for both")
    func sharedCoresDropOut() {
        let (home, away) = SportMatch.cores(forItem: Self.fixture("Covewood City", "Hollin City"))
        #expect(home == ["covewood"])
        #expect(away == ["hollin"])
        // And with that the fixture no longer seals the crime documentary.
        #expect(!SportMatch.sharesBothTeams(Self.fixture("Covewood City", "Hollin City"), with: "Brack City"))
    }

    @Test("Generic cores never stand alone for a team")
    func genericCoresAreBlocked() {
        // "millbrook" alone, plus the aliases of the board — but nowhere "united", "real" or
        // "city".
        #expect(SportMatch.cores("Millbrook United").first == "millbrook")
        #expect(!SportMatch.cores("Millbrook United").contains("united"))
        #expect(SportMatch.cores("Real Hermandad") == ["hermandad"])
        #expect(SportMatch.cores("Newmarsh United") == ["newmarsh"])
        #expect(SportMatch.cores("Millbrook City").first == "millbrook")
        #expect(!SportMatch.cores("Millbrook City").contains("city"))
        // "club" has to go on the list, otherwise exactly [club] would be left of "United
        // Club" — a core that fits every second title.
        #expect(!SportMatch.cores("United Club").contains("club"))
    }

    /// **The price of the block, measured openly.** If a side is left with no core, it
    /// searches for its whole phrase. That finds less — "United Bergtal" in the EPG does
    /// not hit the phrase "united club" — but it seals nothing wrong, and that is the
    /// order of evils here.
    @Test("If no core is left, the side searches for its whole phrase")
    func fallbackToTheWholePhrase() {
        #expect(SportMatch.cores("United Club") == ["united club"])
        let match = Self.fixture("United Club", "Real Castellar")
        #expect(SportMatch.sharesBothTeams(match, with: "United Club - Real Castellar"))
        #expect(!SportMatch.sharesBothTeams(match, with: "United Bergtal - Real Castellar"))
    }

    /// **The spellings of the source as a whole phrase**, not split into words: "Klianoskand
    /// Naglai" split would give "kesselburg", and that would carry Viktoria as well.
    @Test("The source's spellings are added as phrases")
    func variantsOfTheSource() {
        let cores = SportMatch.cores(
            "1. FC Union Kesselburg", variants: ["Union Kesselburg", "FCU", "1. FC Union Kesselburg"])
        #expect(cores.contains("union"))
        #expect(cores.contains("union kesselburg"))
        // "FCU" is too short to be a core — three letters hit too much. And the repetition of
        // the display name does not come twice.
        #expect(!cores.contains("fcu"))
        #expect(cores.count(where: { $0 == "union kesselburg" }) == 1)
    }

    /// **The alias board stays anyway.** ESPN writes English: it delivers "Cologne" and
    /// "Bergland Munich", the German EPG "Köln" and "Bergland München". What the source brings
    /// along does not replace the board — it only spares maintaining it further.
    @Test("The alias board carries what the source does not supply")
    func aliasBoardCarriesOver() {
        let cores = SportMatch.cores("Rheinufer Cologne", variants: ["Cologne", "KOE"])
        #expect(cores.contains("cologne"))
        #expect(cores.contains("koln"), "the EPG writes Koeln, ESPN never does")
    }
}
