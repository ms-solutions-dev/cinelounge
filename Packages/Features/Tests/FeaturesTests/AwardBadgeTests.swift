import Core
import RatingsKit
import Testing

@testable import Features

/// Tests what of the awards arrives on the screen.
///
/// The evaluator itself is tested elsewhere. Here it is about the two steps after it,
/// both of which fail silently: The row is not built at all — then one looks for the
/// error in the evaluator, which works flawlessly —, or it is built and claims a win
/// where a nomination stood. The second is worse: Whoever knows that their movie did
/// not win no longer believes the rating next to it either.
/// **On the main actor**, like the other test suites of this package.
/// ``RatingBadges/hasContent(serverRatings:external:)`` belongs to a view and is
/// therefore bound to the main actor. Without this annotation the compiler reports a
/// concurrency warning on every call — a warning today, an error in the next language
/// mode, and the test suite then no longer builds.
@Suite("Badges for awards")
@MainActor
struct AwardBadgeTests {

    // MARK: - Whether the row exists at all

    @Test("A film with an Oscar but without a rating gets the plaque row")
    func awardAloneBuildsTheRow() {
        // The case in which the badge stayed invisible: The condition asked only about
        // ratings. An old movie without an IMDb rating in the server's catalog, but with four
        // Oscars, therefore never made it into the row — and a badge in a row that is not
        // built cannot be seen on any TV.
        let external = ExternalRatings(awards: Awards(oscarsWon: 4, totalWins: 4))

        #expect(RatingBadges.hasContent(serverRatings: Ratings(), external: external))
    }

    @Test("A title without a rating and without an award gets no row")
    func nothingAtAllBuildsNoRow() {
        // The counter-check to the previous one. Without it the condition would be satisfied
        // even if it simply always returned true — and what would remain is an empty row that
        // shows itself only as a gap in the spacing.
        #expect(!RatingBadges.hasContent(serverRatings: Ratings(), external: ExternalRatings()))
    }

    @Test("A rating without an award still gets the row")
    func ratingAloneStillBuildsTheRow() {
        // The normal case, which worked before. It is here because the condition was rebuilt:
        // An extension that incidentally switches off the most common case would be noticed
        // only on the TV.
        let external = ExternalRatings(imdb: 8.7)

        #expect(RatingBadges.hasContent(serverRatings: Ratings(), external: external))
    }

    @Test("Every award that triggers the row also has a badge")
    func everyAwardThatOpensTheRowAlsoFillsIt() {
        // The silent condition between the two sides. The row opens on `hasAwards`, and it is
        // filled by `AwardBadge.of`. If the two drift apart — for example because a sixth
        // field is added that `of` does not know —, a title without a rating produces a row
        // without content. On the screen that is only a spacing that is too large, and nobody
        // looks for that.
        let cases = [
            Awards(oscarsWon: 4, totalWins: 4),
            Awards(oscarNominations: 7, totalNominations: 7),
            Awards(emmysWon: 6, totalWins: 6),
            Awards(totalWins: 160),
            Awards(totalNominations: 220),
        ]

        for awards in cases {
            let external = ExternalRatings(awards: awards)

            #expect(external.hasAwards)
            #expect(AwardBadge.of(awards) != nil, "no plaque for \(awards)")
        }
    }

    @Test("Without an award no badge appears")
    func noAwardsNoBadge() {
        // Both ways by which "nothing" arrives: The evaluator returns `nil`, and from the
        // store an old entry with all zeros can come. A badge with "0" would be a claim about
        // a title about which OMDb gives no information at all.
        #expect(AwardBadge.of(nil) == nil)
        #expect(AwardBadge.of(Awards()) == nil)
    }

    // MARK: - What the badge says

    @Test("Four won Oscars show as four on the plaque")
    func oscarWinsAreShownWithTheirCount() {
        let badge = AwardBadge.of(Awards(oscarsWon: 4, totalWins: 4))

        #expect(badge == .won(.oscar, count: 4))
        #expect(badge?.plate == "OSCAR")
    }

    @Test("For a series it says Emmy instead of Oscar")
    func seriesShowEmmys() {
        // For series OMDb names Emmys, never Oscars. If "OSCAR" stood there anyway, it would
        // simply be wrong — and in a way that every viewer notices immediately.
        let badge = AwardBadge.of(Awards(emmysWon: 6, totalWins: 6))

        #expect(badge == .won(.emmy, count: 6))
        #expect(badge?.plate == "EMMY")
    }

    @Test("The won Oscar displaces the larger total")
    func theOscarWinsOverTheLargerNumber() {
        // "Won 3 Oscars. 140 wins & 205 nominations total": 140 is the larger number and the
        // weaker statement. Whoever picks by size writes "140" on a movie that one knows for
        // its three Oscars.
        let badge = AwardBadge.of(
            Awards(oscarsWon: 3, totalWins: 140, totalNominations: 205)
        )

        #expect(badge == .won(.oscar, count: 3))
    }

    @Test("Without a name the trophy stays nameless instead of guessed")
    func unnamedWinsStayUnnamed() {
        // "19 wins & 37 nominations total" without a named prize. Turning that into an Oscar
        // would be the one invention that makes the whole display implausible; omitting the
        // number would be unnecessary, because it is correct.
        let badge = AwardBadge.of(Awards(totalWins: 19, totalNominations: 37))

        #expect(badge == .won(.unnamed, count: 19))
        #expect(badge?.plate != "OSCAR")
    }

    // MARK: - Win versus nomination

    @Test("A nomination does not look like a win")
    func nominationLooksDifferentFromAWin() {
        // The same number, two completely different statements. If the distinction relies on
        // colour alone, it is none at three metres and with a colour deficiency — so what is
        // tested is that it carries in several ways at once: wording, fill and outline.
        let win = AwardBadge.of(Awards(oscarsWon: 4, totalWins: 4))
        let nomination = AwardBadge.of(Awards(oscarNominations: 4, totalNominations: 4))

        #expect(win?.count == nomination?.count)
        #expect(win != nomination)

        // The word carries the difference alone, even without any colour.
        #expect(win?.suffixKey == nil)
        #expect(nomination?.suffixKey != nil)

        // And the plaque in addition: filled versus outlined.
        #expect(win?.background != nomination?.background)
        #expect(win?.border == nil)
        #expect(nomination?.border != nil)
    }

    @Test("An Oscar nomination comes before the nameless total")
    func namedNominationBeatsUnnamedWins() {
        // "Nominated for 6 Oscars. 19 wins & 37 nominations total". Both could be shown, but
        // only one names a prize by name. "19" without a name tells the viewer nothing about
        // the rank of the awards.
        let badge = AwardBadge.of(
            Awards(oscarNominations: 6, totalWins: 19, totalNominations: 37)
        )

        #expect(badge == .nominated(.oscar, count: 6))
    }

    @Test("The parser does not count nominations as Oscars")
    func nominationsDoNotCountAsOscars() {
        // The boundary comes from the evaluator, but is tested here against the display: A
        // badge that outputs "Won" although only "Nominated for" stood there would be the
        // error that one cannot explain to anyone later.
        let awards = Awards.parse("Nominated for 6 Oscars. 19 wins & 37 nominations total")

        #expect(awards?.hasOscar == false)
        #expect(AwardBadge.of(awards)?.isWin == false)
    }
}
