import DesignSystemPhone
import SwiftUI

/// All ratings in detail — and the sentence when there are none.
///
/// **Here the origin is spelled out.** In the badge row the mark is enough, because
/// there the number is the subject; here the question is "whose verdict is this", and
/// "RT" does not answer it.
///
/// **Without a configured account, it does not say nothing but why.** "No rating
/// found" and "no key stored" look the same on screen — and only one of the two cases
/// can be fixed. The way there is named, not offered: a button that jumps from a sheet
/// into the settings would lose the title the user came here for.
struct RatingsSheet: View {

    let ratings: [Rating]
    let award: Accolade?
    /// Whether an OMDb account is configured at all.
    let credential: Bool

    /// Whether AniList would be responsible but has delivered nothing.
    var hasMuteMark = false

    var body: some View {
        SheetFrame(title: "common.ratings") {
            if let award {
                HStack(spacing: MetricsBoard.phone.gutter) {
                    AwardPlaque(award: award)
                    Text(appKey: "detail.awards")
                        .font(TypeLevel.text.font)
                        .foregroundStyle(ColorRole.text.color)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, MetricsBoard.phone.margin)
                .frame(minHeight: Metrics.choiceRow)

                Divider().overlay(ColorRole.lineQuiet.color).padding(.leading, MetricsBoard.phone.margin)
            }

            ForEach(ratings, id: \.origin) { rating in
                HStack(spacing: MetricsBoard.phone.gutter) {
                    ScoreBadge(rating: rating)
                    Text(appKey: rating.originKey)
                        .font(TypeLevel.text.font)
                        .foregroundStyle(ColorRole.text.color)
                    Spacer(minLength: MetricsBoard.phone.gutter)
                    // **The bar says what the number does not.** "8.4" and "88 %" are
                    // almost the same verdict on two scales; laid side by side you see
                    // that without having to convert.
                    ProgressBar(portion: rating.portion)
                        .frame(width: 64)
                }
                .padding(.horizontal, MetricsBoard.phone.margin)
                .frame(minHeight: Metrics.choiceRow)
                .accessibilityElement(children: .combine)
            }

            if ratings.isEmpty {
                Footnote(message: credential ? "detail.noRatingsFound" : "detail.noRatingsKey")
            }

            // **A gap that has a cause gets a sentence.** For an anime
            // the MAL number is the most meaningful of all; if it is missing
            // without comment, it looks as if the service does not carry the title —
            // and exactly that is not true here.
            if hasMuteMark {
                Footnote(message: "detail.malSilent")
            }
        }
    }
}
