import Testing

@testable import FeaturesPhone

/// What goes on the badge — and what is not claimed.
///
/// **The ranking is the whole purpose of this value.** A won Oscar that is dropped in favor
/// of "160 wins" is the worse information, even though the number is larger. On
/// screen the error is not visible: a number stands there, and it is even
/// correct.
@Suite("Award")
struct AwardTests {

    @Test("Without anything there is no badge")
    func nothing() {
        #expect(Accolade.from() == nil)
        #expect(Accolade.from(oscarsWon: 0, wins: 0) == nil)
    }

    /// A won Oscar beats any total.
    @Test("The Oscar goes before the larger number")
    func oscarFirst() throws {
        let award = try #require(Accolade.from(oscarsWon: 4, wins: 160, nominations: 220))
        #expect(award.award == .oscar)
        #expect(award.kind == .gained)
        #expect(award.count == 4)
    }

    /// **The Oscar nomination comes before the total number of wins**: it names an
    /// award by name, "21 wins" names none.
    @Test("The nomination names a name, the total does not")
    func nominationBeforeWins() throws {
        let award = try #require(Accolade.from(oscarNominations: 7, wins: 21))
        #expect(award.award == .oscar)
        #expect(award.kind == .nominated)
        #expect(award.count == 7)
    }

    /// For series OMDb names Emmys instead of Oscars.
    @Test("The Emmy comes before the Oscar nomination")
    func emmy() throws {
        let award = try #require(Accolade.from(oscarNominations: 2, emmysWon: 9))
        #expect(award.award == .emmy)
        #expect(award.count == 9)
    }

    /// **The finding from the TV, 2026-08-08:** *Siege on Corvane* showed 42, *Crown
    /// Cipher* 4 — both total wins, both numbers correct, both badges looked like
    /// an Oscar count. Without a name the number has to explain itself.
    @Test("Without a name the number carries its word")
    func extras() throws {
        let withoutName = try #require(Accolade.from(wins: 42))
        #expect(withoutName.extraKey == "detail.awardWins")

        let oscarWin = try #require(Accolade.from(oscarsWon: 4))
        // "OSCAR 4" reads correctly — the win is the obvious reading of
        // a golden badge.
        #expect(oscarWin.extraKey == nil)

        let oscarNominated = try #require(Accolade.from(oscarNominations: 7))
        #expect(oscarNominated.extraKey == "detail.awardNominated")
    }
}
