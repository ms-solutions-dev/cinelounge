import Core
import DesignSystemPhone
import Flows
import SwiftUI

/// What the film database knows about a title you do **not** have.
///
/// **"What you have opens; what you don't have explains itself."** The sentence appears verbatim
/// in the TV project, where the same question was already answered once on 2026-08-08 — and
/// wrongly at first: foreign rows were not to answer at all, because a button that does nothing on
/// two thirds of the rows is worse than a row without a button. The
/// objection was right, the answer was the smaller of two.
///
/// **On the phone it was the same smaller answer until 2026-09-08** `Core.TitleProfile` and
/// `FilmographySource.profile(for:)` have always been in the shared package — nobody called them
/// here.
///
/// **It is not a second detail page.** A detail page has a play button, seasons,
/// sources and a downloads button; none of that exists for a title you do not
/// own. What stands here is **information** — and therefore a sheet and not a path.
struct TitleProfileSheet: View {

    let title: String
    let profile: TitleProfile?
    let isLoading: Bool
    /// The trailer is being resolved right now (AP78) — the button shows it instead of staying silent.
    var isTrailerLoading = false
    /// Plays the profile's trailer. For a title outside the catalog that is the
    /// only thing that can be played here.
    var playTrailer: () -> Void = {}

    /// Back to the filmography you came from — with the person's name.
    var back: (wohin: String, action: () -> Void)?

    /// The height that the loading state reserves — the same reasoning as at the
    /// ``CareerSheet``: without it the content jumps on arrival.
    static let loadingHeight: CGFloat = 200

    var body: some View {
        SheetFrame(wording: title, back: back) {
            if isLoading {
                VStack(spacing: MetricsBoard.phone.gutter) {
                    ProgressView().tint(ColorRole.textQuiet.color)
                    Text(appKey: PlaybackPhase.loadingStart.form.message ?? "")
                        .font(TypeLevel.label.font)
                        .foregroundStyle(ColorRole.textQuiet.color)
                }
                .frame(maxWidth: .infinity)
                .frame(height: Self.loadingHeight)
            } else if let profile {
                content(profile)
            } else {
                // **Nothing found is information and not an error.** TMDb does not keep
                // a profile for every entry — mostly for announced titles that have nothing yet besides a
                // name.
                Footnote(message: "filmography.noProfile")
            }
        }
    }

    @ViewBuilder
    private func content(_ profile: TitleProfile) -> some View {
        HStack(alignment: .top, spacing: MetricsBoard.phone.gutter) {
            RemoteImage(
                source: profile.posterURL,
                longestEdge: CGFloat(
                    ImageSizes.pixels(
                        forItem: MetricsBoard.phone.poster.height, reference: ImageSizes.reference)),
                withColor: false
            )
            .frame(width: MetricsBoard.phone.poster.width, height: MetricsBoard.phone.poster.height)
            .clipShape(RoundedRectangle(cornerRadius: MetricsBoard.phone.fieldRadius))

            VStack(alignment: .leading, spacing: 6) {
                // **First filter, then join** — the same rule as at ``MetaRow``:
                // a missing year otherwise leaves a separator pointing at nothing.
                let attributes =
                    ([profile.year.map(String.init)]
                    + profile.genres.prefix(2).map { Optional($0) })
                    .compactMap { $0 }
                if !attributes.isEmpty {
                    Text(verbatim: attributes.joined(separator: DelimiterChars.point))
                        .font(TypeLevel.label.font)
                        .foregroundStyle(ColorRole.textQuiet.color)
                }

                // **Zero is not a rating** — the same rule as everywhere here: all
                // services deliver it when nobody has voted.
                if let note = profile.rating {
                    Text(verbatim: String(format: "★ %.1f", note))
                        .font(TypeLevel.label.font)
                        .foregroundStyle(ColorRole.progress.color)
                }

                if let trailer = profile.trailer {
                    Button(action: playTrailer) {
                        HStack(spacing: 6) {
                            if isTrailerLoading {
                                ProgressView().tint(ColorRole.text.color)
                            } else {
                                Image(systemName: Glyph.broadcast.name)
                            }
                            Text(appKey: "detail.trailer")
                            if let badge = trailer.badge {
                                Text(verbatim: badge)
                                    .font(TypeLevel.lowercased.font.weight(.bold))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(ColorRole.text.color.opacity(0.16), in: Capsule())
                            }
                        }
                        .font(TypeLevel.label.font.weight(.semibold))
                        .foregroundStyle(ColorRole.text.color)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(ColorRole.surface.color, in: Capsule())
                        .overlay(Capsule().strokeBorder(ColorRole.outline.color, lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .disabled(isTrailerLoading)
                    .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, MetricsBoard.phone.margin)

        if !profile.overview.isEmpty {
            Text(verbatim: profile.overview)
                .font(TypeLevel.footer.font)
                .foregroundStyle(ColorRole.textMatt.color)
                .padding(.horizontal, MetricsBoard.phone.margin)
                .padding(.top, Metrics.targetSpacing)
        }

        if !profile.cast.isEmpty {
            SectionHeader(title: "detail.cast")
            // **Names and no circles.** The portraits cost one request each to a
            // third-party endpoint, and this sheet is information about a title
            // you do not have — that would be effort for the weakest row of the list.
            Text(verbatim: profile.cast.prefix(6).joined(separator: DelimiterChars.point))
                .font(TypeLevel.footer.font)
                .foregroundStyle(ColorRole.textQuiet.color)
                .padding(.horizontal, MetricsBoard.phone.margin)
        }

        Footnote(message: "filmography.notInLibrary")
    }
}
