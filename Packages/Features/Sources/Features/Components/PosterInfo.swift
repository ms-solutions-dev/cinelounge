import Core
import DesignSystem
import Flows
import RatingsKit
import SwiftUI

/// **Top right on the poster: open episodes, otherwise the rating** — as on the phone
/// (2026-09-29, product decision after the comparison page).
///
/// Until then the TV never showed a rating on the poster, while the phone did.
/// The rule lives in ``Flows/PosterCorner`` and ``Flows/Rating/forItem(_:)``; the
/// dimensions are the phone's, scaled up by the poster ratio (240 to 110
/// pt, so 2.18): 46 pt high, "small" type (25 pt). Watched and favourite sit at the top
/// left (``StatusBadges``).
///
/// **For anime the MAL score** (AP68): the poster asks for it as soon as it is visible,
/// via ``RatingsKit/AnimeScores``; until it arrives, it shows what the server brought along.
struct PosterInfo: View {

    let item: MediaItem
    @Environment(AnimeScores.self) private var animeRatings: AnimeScores?

    private var request: AnimeQuery? { AnimeQuery.from(item) }

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            content
            if let badge = PosterCorner.audioBadge(item) {
                AudioCapsule(badge: badge)
            }
        }
        .padding(10)
        .task(id: request) {
            guard let request, PosterCorner.remainingEpisodes(item) == nil else { return }
            animeRatings?.query(request)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let pending = PosterCorner.remainingEpisodes(item) {
            Text(verbatim: AppLanguageSetting.text("tile.remaining \(pending)"))
                .font(TypeLevel.lowercased.font)
                .foregroundStyle(ColorRole.text.color)
                .padding(.horizontal, 13)
                .frame(minWidth: 46, minHeight: 46)
                .background(ColorRole.tag.color, in: Capsule())
        } else if let rating = Rating.forItem(item, mal: request.flatMap { animeRatings?.note($0) }) {
            HStack(spacing: 7) {
                Image(systemName: Glyph.rating.name)
                    // festeschrift: an icon next to the number, no text — 9 pt on the
                    // phone, scaled up by 2.18.
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(ColorRole.progress.color)
                Text(verbatim: rating.text)
                    .font(TypeLevel.lowercased.font)
                    .foregroundStyle(ColorRole.text.color)
                    .monospacedDigit()
            }
            .padding(.horizontal, 13)
            .frame(minHeight: 46)
            .background(ColorRole.reason.color.opacity(0.65), in: Capsule())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                Text(verbatim: AppLanguageSetting.text(.init(rating.originKey)) + " " + rating.text))
        }
    }
}

/// **The language corner** (AP84, variant B of the canvas `design/sprachschild-2026-11-08.html`):
/// "EN" or "OmU" below the info line when there is no German audio.
///
/// Same height and type as the rating capsule next to it, so that the two form one column.
/// **Colours from the roles and not from the canvas:** there the badge was
/// light blue, a signal colour that none of the three colour boards carries; a line in
/// ``ColorRole/textMatt`` sets it apart from the rating without introducing a fourth colour.
struct AudioCapsule: View {

    let badge: PosterCorner.AudioBadge

    var body: some View {
        Text(verbatim: badge.short)
            .font(TypeLevel.lowercased.font.weight(.bold))
            .tracking(1)
            .foregroundStyle(ColorRole.text.color)
            .padding(.horizontal, 13)
            .frame(minHeight: 46)
            .background(ColorRole.reason.color.opacity(0.78), in: Capsule())
            .overlay(Capsule().strokeBorder(ColorRole.textMatt.color.opacity(0.7), lineWidth: 2))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: badge.spoken))
    }
}
