import Core
import DesignSystem
import Flows
import SwiftUI

/// The offer to switch to the next episode.
///
/// **A small card, not a sheet** (variant B, Max 2026-11-09): the still with a ring that
/// fills while the counter runs, the title in one line — and "Watch credits" beside it as a
/// slim button. Until then the card took more than half of the picture's height and covered
/// exactly the credits one might want to see. The card itself is the play button.
///
/// The counter comes from ``NextUpPrompt`` and is not kept here: a separate timer in the
/// overlay keeps running during pause and scrubbing, and the next episode starts while the
/// picture stands still.
///
/// **Dismissable, and that is no side issue.** In anime the credits carry the song, in
/// series the preview of next week. Anyone who wants to see that must not be dragged along.
struct NextUpOffer: View {

    let episode: MediaItem
    let state: NextUpPrompt.State
    /// Whether a **similar film** is offered instead of the next episode — only the label
    /// decides, the mechanics are the same. For films this used to say, literally, "Next
    /// episode", and that was a lie.
    let isSimilar: Bool
    let stillURL: URL?
    @FocusState.Binding var focus: String?
    let onPlay: () -> Void
    let onDismiss: () -> Void

    @Environment(\.accentPalette) private var palette

    /// Width of the still and therefore of the card's content.
    static let stillWidth: CGFloat = 320
    /// 16:9 like every episode still.
    static let stillHeight: CGFloat = 180
    /// Margin inside the card.
    static let cardPadding: CGFloat = 14
    /// "Watch credits" — a fixed width so that the offer's width is known in advance.
    static let stayWidth: CGFloat = 250
    static let gap: CGFloat = 20

    /// Total width of the offer — card plus the button beside it. It must not run into the
    /// centred button row, and content that is too wide is centred by SwiftUI without a
    /// warning.
    static var cardWidth: CGFloat {
        stayWidth + gap + stillWidth + 2 * cardPadding
    }

    var body: some View {
        VStack {
            Spacer()
            HStack(alignment: .bottom, spacing: Self.gap) {
                Spacer()
                stayButton
                card
            }
        }
        .padding(.trailing, MetricsBoard.tv.margin)
        .padding(.bottom, 112)
        .focusSection()
    }

    /// The card is the button: one click on the picture starts the episode.
    private var card: some View {
        let isFocused = focus == "nextup-play"
        return Button(action: onPlay) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack {
                    RemoteImage(url: stillURL)
                        .frame(width: Self.stillWidth, height: Self.stillHeight)
                    // systemfarbe: drawn over a still frame, which is always a picture and never the page — white and a dark veil read on any picture in both themes.
                    Color.black.opacity(0.35)
                    countdownMark
                }
                .frame(width: Self.stillWidth, height: Self.stillHeight)
                .clipShape(
                    RoundedRectangle(cornerRadius: MetricsBoard.tv.cardRadius, style: .continuous))

                Text(verbatim: titleLine)
                    .font(TypeLevel.footer.font)
                    .fontWeight(.semibold)
                    .foregroundStyle(ColorRole.text.color)
                    .lineLimit(1)
                    .frame(width: Self.stillWidth, alignment: .leading)
            }
            .padding(Self.cardPadding)
            .background(
                isFocused ? Color(palette).opacity(0.9) : ColorRole.surface.color.opacity(0.92),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .bareFocusableButton()
        .focused($focus, equals: "nextup-play")
        .focusHighlight(isFocused, scale: Tokens.Focus.buttonScale, accent: Color(palette, .bright))
        .shadow(color: .black.opacity(0.6), radius: 30, y: 14)
        .info(appKey: isSimilar ? "player.similarMovie" : "player.nextEpisode")
    }

    /// The ring fills while the counter runs; the similar film does not start by itself
    /// (F-026, 2026-09-05), so it shows only the play mark and promises nothing.
    private var countdownMark: some View {
        ZStack {
            if !isSimilar {
                Circle()
                    // systemfarbe: drawn over a still frame, which is always a picture and never the page — white and a dark veil read on any picture in both themes.
                    .stroke(Color.white.opacity(0.25), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: Self.progress(state))
                    // systemfarbe: drawn over a still frame, which is always a picture and never the page — white and a dark veil read on any picture in both themes.
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: state.secondsLeft)
            }
            Image(systemName: "play.fill")
                .font(.system(size: 30, weight: .bold))
                // systemfarbe: drawn over a still frame, which is always a picture and never the page — white and a dark veil read on any picture in both themes.
                .foregroundStyle(Color.white)
        }
        .frame(width: 78, height: 78)
    }

    /// Season, episode and title in one line — "S2 · E3 · The Rift".
    private var titleLine: String {
        guard let identifier = episode.episodeIdentifier else { return episode.title }
        return "\(identifier) · \(episode.title)"
    }

    /// How full the ring is: 0 at the start of the counter, 1 when the episode starts.
    static func progress(_ state: NextUpPrompt.State) -> CGFloat {
        let total = max(1, NextUpPrompt.countdown)
        return min(1, max(0, 1 - CGFloat(state.secondsLeft) / CGFloat(total)))
    }

    private var stayButton: some View {
        let isFocused = focus == "nextup-stay"
        return Button(action: onDismiss) {
            Text(appKey: PlaybackWording.stay)
                .font(TypeLevel.footer.font)
                .fontWeight(.semibold)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(ColorRole.text.color)
                .frame(width: Self.stayWidth, height: 56)
                .background(
                    isFocused ? Color(palette) : ColorRole.surface.color.opacity(0.78),
                    in: Capsule()
                )
                .overlay {
                    Capsule().stroke(ColorRole.text.color.opacity(0.35), lineWidth: 2)
                        .allowsHitTesting(false)
                }
        }
        .bareFocusableButton()
        .focused($focus, equals: "nextup-stay")
        .focusHighlight(isFocused, scale: Tokens.Focus.buttonScale, accent: Color(palette, .bright))
    }
}
