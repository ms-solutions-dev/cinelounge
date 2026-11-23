import Core
import DesignSystem
import SwiftUI

/// A wide-format episode tile — for "Continue Watching" and episode lists.
///
/// 420 × 236 points at 16:9, taken over from the template. For episodes already started it
/// shows the remaining time instead of the total runtime: anyone who wants to keep watching
/// cares about how much is left.
public struct EpisodeCard: View {

    /// Which heading the tile carries.
    ///
    /// In "Continue Watching" and the shelves on the Home screen the series name is the more
    /// important piece of information — people look for the series, not the episode. On the
    /// detail page, however, it already appears as the page heading, and on every card in the
    /// same row it would be the same line again; there the episode title counts.
    /// Same pattern as ``PosterCard``'s `showsTitle`, except that here the line is not
    /// omitted but replaced.
    public enum TitleMode {
        /// Series name; for titles without a series, the title's own name.
        case series
        /// Episode title, prefixed with the number when it is known.
        case episode
    }

    let item: MediaItem
    let imageURL: URL?
    /// The image is a poster — see ``HomeModel/TileImage/up``.
    let isPortraitImage: Bool
    let isFocused: Bool
    let titleMode: TitleMode
    /// Spoiler protection is on for this profile (AP85) — ``Core/SpoilerGuard`` decides
    /// per episode.
    let guardsSpoilers: Bool

    @Environment(\.accentPalette) private var palette

    public init(
        item: MediaItem, imageURL: URL?, isPortraitImage: Bool = false, isFocused: Bool,
        titleMode: TitleMode = .series, guardsSpoilers: Bool = false
    ) {
        self.guardsSpoilers = guardsSpoilers
        self.item = item
        self.imageURL = imageURL
        self.isPortraitImage = isPortraitImage
        self.isFocused = isFocused
        self.titleMode = titleMode
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            image
                .frame(
                    width: MetricsBoard.tv.episode.width,
                    height: MetricsBoard.tv.episode.height
                )
                .clipShape(
                    RoundedRectangle(cornerRadius: MetricsBoard.tv.cardRadius, style: .continuous)
                )
                .overlay(alignment: .bottom) { progressBar }
                .overlay(alignment: .topTrailing) { StatusBadges(item: item) }
                .focusHighlight(isFocused, accent: Color(palette, .bright))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(TypeLevel.footer.font)
                    .fontWeight(.semibold)
                    .foregroundStyle(isFocused ? ColorRole.text.color : ColorRole.text.color.opacity(0.9))
                    .lineLimit(1)
                subtitle
                    .font(TypeLevel.lowercased.font)
                    .foregroundStyle(ColorRole.textMatt.color)
                    .lineLimit(1)
            }
            .frame(width: MetricsBoard.tv.episode.width, alignment: .leading)
        }
    }

    /// **A poster shown whole, on a blurred backdrop made from itself** (2026-10-01) — the way
    /// Apple shows tall images in wide frames. Cropped, the title and faces would be missing;
    /// a grey border would look like a bug.
    @ViewBuilder
    private var image: some View {
        if isPortraitImage {
            ZStack {
                RemoteImage(url: imageURL, displaySize: MetricsBoard.tv.episode)
                    .blur(radius: 28)
                    .overlay(ColorRole.reason.color.opacity(0.35))
                RemoteImage(
                    url: imageURL, contentMode: .fit, displaySize: MetricsBoard.tv.episode)
            }
        } else if SpoilerGuard.hides(item, enabled: guardsSpoilers) {
            RemoteImage(url: imageURL, displaySize: MetricsBoard.tv.episode)
                .blur(radius: SpoilerGuard.blurRadius, opaque: true)
                .overlay {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                }
        } else {
            RemoteImage(url: imageURL, displaySize: MetricsBoard.tv.episode)
        }
    }

    private var title: String {
        Self.title(for: item, mode: titleMode)
    }

    /// Pulled out as a function so the rule can be tested — which name appears on which card
    /// is decided here and not scattered across the views. The reasoning for the two cases is
    /// at ``TitleMode``.
    static func title(for item: MediaItem, mode: TitleMode) -> String {
        switch mode {
        case .series:
            return item.parentTitle ?? item.title
        case .episode:
            guard let number = item.episodeNumber else { return item.title }
            return "\(number). \(item.title)"
        }
    }

    /// The subtitle line is assembled from `Text` building blocks, not from
    /// strings.
    ///
    /// The reason is the language choice in the app: `Text` looks up through the
    /// environment language, whereas older paths such as `NSLocalizedString` look up through
    /// the device language. Mixing the two gives a half-translated
    /// interface — which is exactly what showed up.
    @ViewBuilder
    private var subtitle: some View {
        HStack(spacing: 6) {
            // **For a channel, this shows what is on** (AP29, 2026-09-11) — and that
            // is the whole purpose of the Live shelf. The channel name sits on top because people
            // recognise it; the programme below it because it answers the question.
            // Without this line the tile would show a logo and **not a word** about
            // what is playing right now — the same finding as on the phone (contradiction W2, 2026-09-06).
            if item.kind == .channel {
                Text(verbatim: item.title)
            } else if let identifier = item.episodeIdentifier {
                Text(verbatim: identifier)
                Text(verbatim: "·")
            }
            if let progress = item.progress, progress.isResumable {
                // Remaining time, not total runtime — anyone who wants to keep watching
                // cares about how much is left.
                Text(app: "card.minutesLeft \(minutes(progress.remaining))")
            } else if let runtime = item.runtime {
                Text(app: "card.minutes \(minutes(runtime))")
            }
        }
    }

    private func minutes(_ seconds: TimeInterval) -> Int {
        max(1, Int((seconds / 60).rounded()))
    }

    @ViewBuilder
    private var progressBar: some View {
        if let progress = item.progress, progress.isResumable {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle().fill(.white.opacity(0.24))
                    Rectangle()
                        .fill(ColorRole.progress.color)
                        .frame(width: geometry.size.width * progress.fraction)
                }
            }
            .frame(height: 6)
        }
    }
}
