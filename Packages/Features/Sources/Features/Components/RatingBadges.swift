import Core
import DesignSystem
import RatingsKit
import SwiftUI

/// Ratings labelled with their origin.
///
/// Fed from two sources: what the media server delivers, and what was additionally
/// queried from the ratings service. Together they yield up to four values for films
/// — for series usually two, because critic portals do not carry
/// anime.
///
/// Whatever is empty is **left out** instead of being filled with a dash. A line
/// of placeholders looks like an error.
///
/// The marks are recreated, not the original logos: those are protected, and
/// at three metres' distance the difference cannot be seen anyway.
public struct RatingBadges: View {

    let serverRatings: Ratings
    let external: ExternalRatings

    public init(serverRatings: Ratings, external: ExternalRatings = ExternalRatings()) {
        self.serverRatings = serverRatings
        self.external = external
    }

    /// The height of a badge — and with it that of a single-line row.
    ///
    /// Named because the library's information column caps its row at exactly
    /// this height: its height budget is calculated, and a number changed here
    /// has to update the calculation there. See ``DetailColumn`` and
    /// `LayoutBudgetTests`.
    public static let badgeHeight: CGFloat = 46

    /// Whether the row should be built at all.
    ///
    /// **This was the trap that kept the badge invisible.** The
    /// condition was written out three times in the views and only asked about
    /// ratings. A film with four Oscars but no score therefore got no
    /// row at all — the badge would never have appeared, and the
    /// bug would have been sought in the evaluator, which works flawlessly.
    ///
    /// ``ExternalRatings/isEmpty`` stays untouched by this and still does not count
    /// awards: it also decides whether anything is fetched at all,
    /// and an award alone is no reason for a request.
    ///
    /// **The silent condition that goes with it:** for every award that triggers the row here,
    /// ``AwardBadge/of(_:)`` must also deliver a badge. Otherwise
    /// a title without a score ends up with an empty row — visible only as
    /// a gap in the spacing. The test suite pins this down.
    public static func hasContent(serverRatings: Ratings, external: ExternalRatings) -> Bool {
        !serverRatings.isEmpty || !external.isEmpty || external.hasAwards
    }

    public var body: some View {
        // **Wrap instead of truncate.** In the information column (520 points) four
        // badges do not fit side by side; the last one dropped out, and from outside
        // it looked as if the server had not delivered the rating. How wide they
        // really are depends on language and content — "…/…" is shorter than "8,7/10" —,
        // so they are measured instead of fixing a count per row.
        // See ``FlowLayout``.
        FlowLayout(spacing: 22, lineSpacing: 14) {
            if let award = AwardBadge.of(external.awards) {
                // At the very front, not the back: in the narrow information column
                // (520 points) there is not room for all badges, and whatever
                // no longer fits is cut off at the end. Almost every title has a score,
                // very few an Oscar — the rarer one
                // must not be the first to disappear.
                badge(
                    label: award.plate,
                    background: award.background,
                    foreground: award.foreground,
                    border: award.border,
                    value: String(award.count),
                    suffix: award.suffixKey.map { Text(app: LocalizedStringKey($0)) }
                )
            }

            if let imdb = external.imdb {
                badge(
                    label: "IMDb",
                    background: Color(hex: 0xF5C518),
                    foreground: Color(hex: 0x12100B),
                    value: imdb.formatted(.number.precision(.fractionLength(1))),
                    suffix: Text(verbatim: "/ 10")
                )
            }

            if let tomatoes = external.rottenTomatoes ?? serverRatings.critic {
                badge(
                    label: "🍅",
                    background: Color(hex: 0xFA320A),
                    foreground: .white,
                    value: String(tomatoes),
                    suffix: Text(verbatim: "%")
                )
            }

            if let metacritic = external.metacritic {
                // Metacritic colours its values itself: green from 61, yellow from
                // 40, red below. That is quicker to take in on a TV
                // than the number.
                badge(
                    label: "MC",
                    background: Self.metacriticColor(metacritic),
                    foreground: Color(hex: 0x0B1A0B),
                    value: String(metacritic),
                    suffix: Text(verbatim: "/ 100")
                )
            }

            if let mal = external.mal {
                // The brand blue of MyAnimeList, with two decimal places as on
                // myanimelist.net — "9,25" is recognisable, "9,3" is not (AP68).
                badge(
                    label: "MAL",
                    background: Color(hex: 0x2E51A2),
                    foreground: .white,
                    value: mal.formatted(.number.precision(.fractionLength(2))),
                    suffix: Text(verbatim: "/ 10")
                )
            }

            if let community = serverRatings.community {
                badge(
                    label: "TMDB",
                    background: Color(hex: 0x01B4E4),
                    foreground: Color(hex: 0x04222B),
                    value: community.formatted(.number.precision(.fractionLength(1))),
                    suffix: Text(verbatim: "/ 10")
                )
            }
        }
    }

    static func metacriticColor(_ score: Int) -> Color {
        switch score {
        case 61...: Color(hex: 0x00CE7A)
        case 40..<61: Color(hex: 0xFFBD3F)
        default: Color(hex: 0xFF6874)
        }
    }

    /// The suffix is a `Text` and not a string, because one of them has to be
    /// translated. `Text` looks up through the environment language, `NSLocalizedString`
    /// through the device's — mixing the two gives a half-translated
    /// interface, which has already been seen in this app.
    private func badge(
        label: String,
        background: Color,
        foreground: Color,
        border: Color? = nil,
        value: String,
        suffix: Text?
    ) -> some View {
        let plate = RoundedRectangle(cornerRadius: 9, style: .continuous)

        return HStack(spacing: 10) {
            // Width follows the text — with a fixed square
            // area it used to read "T…" instead of "TMDB".
            Text(verbatim: label)
                // festeschrift: 22 instead of 18: "IMDb" and "TMDB" are text meant to be read, and
                // 18 points at three metres' distance are 13 arc minutes — below
                // what is reliably legible on a 55-inch set. The area does not grow with it:
                // it follows the text and at 46 points height has plenty of
                // room for a line of 29.
                .font(.system(size: 22, weight: .heavy))
                .foregroundStyle(foreground)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 12)
                .frame(minWidth: Self.badgeHeight, minHeight: Self.badgeHeight)
                .background(background, in: plate)
                .overlay {
                    if let border {
                        // Decoration above an area: without `allowsHitTesting(false)`
                        // the overlay intercepts the focus that should actually hit the
                        // element underneath. This bug has already occurred five times in the
                        // project — here there is no selectable area underneath, but the rule applies anyway:
                        // as soon as the row moves into a button, it would
                        // otherwise be the sixth.
                        plate.strokeBorder(border, lineWidth: 3)
                            .allowsHitTesting(false)
                    }
                }

            HStack(spacing: 4) {
                Text(verbatim: value)
                    .font(TypeLevel.footer.font)
                    .fontWeight(.bold)
                if let suffix {
                    suffix
                        .font(TypeLevel.footer.font)
                        .foregroundStyle(ColorRole.textQuiet.color)
                }
            }
            .foregroundStyle(ColorRole.text.color)
        }
    }
}

/// Which badge to show for awards — and whether to show one at all.
///
/// A value of its own and not an `if` chain in the view: there is only one thing to decide
/// here, and that is exactly where the costly bug would lurk — a win that
/// looks like a nomination, or the other way round. A view cannot be tested for
/// that, a value can.
///
/// **Only one award is shown, not all.** The row carries up to five
/// badges and sits in the information column at 520 points; a second
/// award badge next to it would displace the scores. What is shown is therefore the
/// strongest statement the evaluator yields.
enum AwardBadge: Equatable {

    /// The award whose name is printed on the badge.
    enum Trophy: Equatable {
        case oscar
        /// For series: critic portals do not award Oscars there, OMDb names
        /// Emmys instead.
        case emmy
        /// Neither Oscar nor Emmy named, only the total from
        /// "N wins & M nominations total". A Bundesfilmpreis is a win like
        /// any other — just without a name that can be written on a badge.
        case unnamed
    }

    case won(Trophy, count: Int)
    case nominated(Trophy, count: Int)

    /// Picks the badge. `nil` when nothing is available.
    ///
    /// The order is the ranking of the statements. A won Oscar beats
    /// everything; leaving it out in favour of "160 wins" would be the worse
    /// information, even though the number is larger. An **Oscar nomination** deliberately
    /// ranks ahead of the total number of wins: it names an award
    /// by name, "21 wins" does not.
    static func of(_ awards: Awards?) -> AwardBadge? {
        guard let awards, !awards.isEmpty else { return nil }

        if awards.hasOscar { return .won(.oscar, count: awards.oscarsWon) }
        if awards.emmysWon > 0 { return .won(.emmy, count: awards.emmysWon) }
        if awards.oscarNominations > 0 {
            return .nominated(.oscar, count: awards.oscarNominations)
        }
        if awards.totalWins > 0 { return .won(.unnamed, count: awards.totalWins) }
        if awards.totalNominations > 0 {
            return .nominated(.unnamed, count: awards.totalNominations)
        }

        // Unreachable as long as `Awards.isEmpty` checks exactly these five fields.
        // It stays here anyway: if a sixth field were added, a row
        // without content would otherwise result — `hasAwards` would be true, but there would be no badge.
        // The test suite fails in that case; the screen shows only a gap.
        return nil
    }

    var count: Int {
        switch self {
        case .won(_, let count), .nominated(_, let count): count
        }
    }

    var trophy: Trophy {
        switch self {
        case .won(let trophy, _), .nominated(let trophy, _): trophy
        }
    }

    var isWin: Bool {
        if case .won = self { return true }
        return false
    }

    var plate: String {
        switch trophy {
        case .oscar: "OSCAR"
        case .emmy: "EMMY"
        case .unnamed: "🏆"
        }
    }

    /// The suffix after the number — **only for the nomination**.
    ///
    /// The labelling is one-sided on purpose. "OSCAR 4" reads like "four
    /// Oscars", and that is exactly what it says: the win is the self-evident
    /// reading of a golden badge. The nomination is the exception and has to
    /// refute that, otherwise the viewer counts four wins where there are four nominations.
    /// It therefore carries both — the word and the unfilled badge.
    /// Changing only the colour was not enough: at three metres and with
    /// colour-vision deficiency that is no difference.
    var suffixKey: String? {
        // **Without a name the number has to explain itself** (test report
        // 2026-08-08): for "Skeblus deitseflaum Poblaplal" it said 42, for "Biziskei Biamik" 4 — both
        // are total wins, and both numbers are correct. It is just that the badge looked
        // like an Oscar count. The evaluator was fine, the
        // labelling was not.
        //
        // For Oscar and Emmy the one-sided labelling stays: there
        // the name of the award is on the badge, and "OSCAR 4" reads
        // correctly. The reasoning for that is above.
        if trophy == .unnamed { return isWin ? "detail.awardWins" : "detail.awardNominated" }
        return isWin ? nil : "detail.awardNominated"
    }

    /// No gold tone invented: `ColorRole.progress.color` is the only
    /// warm yellow in the template and matches the colour of a trophy. The warning on
    /// the template — progress must not blur into the accent — does not apply
    /// here: there is no progress bar in the badge row.
    /// Computed and not a constant — otherwise the colour of the pattern that applied
    /// at first access would stay put.
    static var gold: Color { ColorRole.progress.color }

    var background: Color { isWin ? Self.gold : ColorRole.surface.color }

    var foreground: Color { isWin ? ColorRole.textOnLight.color : Self.gold }

    var border: Color? { isWin ? nil : Self.gold }
}
