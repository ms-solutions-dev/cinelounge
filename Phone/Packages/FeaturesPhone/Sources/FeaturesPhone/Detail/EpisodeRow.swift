import Core
import DesignSystemPhone
import Downloads
import SwiftUI

/// Number, image, title, details — and the text, if there is one.
///
/// **283 of 2,000 episodes of this catalog have no description text**, and a
/// placeholder ("No description available") would be worse than the gap: it would fill
/// the same height with information that gets nobody anywhere.
///
/// **Whether texts are shown at all is decided by the season and not the row** —
/// all or none; the reasoning is at ``Season/showsDescriptions``.
///
/// **The image is 16 : 9 and small.** An episode image is a still frame from the show,
/// not a poster; shown large it carries nothing the title does not already say.
///
/// **The menu is a target of its own next to the row, not a long press on it.** A
/// long press is invisible: whoever does not know it never finds "mark as watched".
/// And a button **in** a button is a bet on a touch screen on
/// which of the two hits — that is why they sit side by side and not inside one another.
struct EpisodeRow: View {

    let episode: EpisodeInfo
    /// Whether the list shows texts. The season decides that, not the row.
    var withDescription = true
    /// Spoiler protection of the profile (AP85): an unseen episode without still and text.
    var guardsSpoilers = false
    let play: () -> Void
    let menu: () -> Void

    /// **The button on the episode — the finding that the usability check wrote down as
    /// number 12.** The downloads' own empty-state message promises "in the menu on every title, on
    /// an episode or on a whole season"; on the episode it was missing. Whoever wants to take two
    /// episodes along for the train ride otherwise loads 4.9 GB instead of 1.2.
    var downloadState: DownloadState?
    var onDownloadsTap: () -> Void = {}

    var body: some View {
        HStack(spacing: 0) {
            Button(action: play) {
                HStack(alignment: .top, spacing: MetricsBoard.phone.gutter) {
                    image
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: headerLine)
                            .font(TypeLevel.header.font)
                            .foregroundStyle(ColorRole.text.color)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)

                        MetaRow(split: details)

                        if withDescription, !isHidden, let description = episode.description {
                            Text(verbatim: description)
                                .font(TypeLevel.label.font)
                                .foregroundStyle(ColorRole.textMatt.color)
                                .lineLimit(3)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, MetricsBoard.phone.margin)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)

            // **Before the ⋯ and not in it.** The finding of 2026-09-08 was that there is no
            // visible point; putting it into the same menu in which it was already missing
            // would be the answer to a different question.
            if let downloadState {
                DownloadButton(state: downloadState, lowercased: true, action: onDownloadsTap)
            }

            Button(action: menu) {
                Image(systemName: Glyph.more.name)
                    .iconSize(15, weight: .semibold)
                    .foregroundStyle(ColorRole.textQuiet.color)
                    .frame(width: Metrics.target, height: Metrics.target)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(app: "action.more.menu"))
            .padding(.trailing, MetricsBoard.phone.margin - 10)
        }
    }

    /// One rule with the TV (``Core/SpoilerGuard``).
    private var isHidden: Bool {
        SpoilerGuard.hides(
            watched: episode.seen, started: (episode.progress ?? 0) > 0, enabled: guardsSpoilers)
    }

    private var image: some View {
        ZStack(alignment: .bottom) {
            RemoteImage(source: episode.image, longestEdge: 96)
                .frame(width: 96, height: 54)
                .blur(radius: isHidden ? SpoilerGuard.blurRadius / 3 : 0, opaque: true)
                .overlay {
                    if isHidden {
                        Image(systemName: "eye.slash")
                            // festeschrift: a mark inside a small fixed picture (96 × 54 / the 40 pt ring) — it must not grow with Dynamic Type beyond the frame it sits in.
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: MetricsBoard.phone.imageRadius))
            if let progress = episode.progress {
                ProgressBar(portion: progress)
                    .frame(width: 96)
            }
        }
        .overlay(alignment: .topTrailing) {
            if episode.seen && episode.progress == nil {
                WatchedCheck().padding(4)
            }
        }
    }

    private var headerLine: String {
        guard let number = episode.number else { return episode.title }
        return "\(number). \(episode.title)"
    }

    private var details: [String] {
        guard let duration = episode.duration, duration > 0 else { return [] }
        return [
            AppLanguageSetting.text("episode.minutes \(Int(duration / 60))")
        ]
    }
}
