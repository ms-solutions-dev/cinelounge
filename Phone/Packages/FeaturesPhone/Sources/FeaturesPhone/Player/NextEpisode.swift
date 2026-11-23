import Core
import DesignSystemPhone
import Flows
import SwiftUI

/// The offer at the end of an episode — **with a counter and a way to dismiss it.**
///
/// **It appears when the counter runs** — from the credits, otherwise forty seconds before
/// the end (``Core/NextUpPrompt``), and only if there really is a next one. Until
/// 2026-09-26 this was a button that appeared a fixed ninety seconds before the end and did
/// not count; since AP58 R4 the ``Flows/PlaybackCore`` calculates the offer, the same
/// one as on the TV.
///
/// **It plays the episode in the same player** (``PlayerModel/playNext()``),
/// automatically at the end of the counter or on a press. **"Watch credits" dismisses** —
/// whoever wants to hear the song at the end is not dragged along.
///
/// **The same small card as on the TV** (variant B, Max 2026-11-09): the still with a ring
/// that fills while the counter runs, the title in one line, "Watch credits" beside it.
struct NextEpisode: View {

    let title: String
    let image: URL?
    let state: NextUpPrompt.State
    /// Whether the offer is a **similar film** (AP58 G1, A8) — then the ring stays away,
    /// because it never starts by itself (the same principle as on the TV: an episode has a
    /// successor, a film a suggestion).
    var similar = false
    let stay: () -> Void
    let start: () -> Void

    private static let stillWidth: CGFloat = 168

    var body: some View {
        HStack(alignment: .bottom, spacing: MetricsBoard.phone.gutter) {
            Button(action: stay) {
                Text(appKey: PlaybackWording.stay)
                    .font(TypeLevel.lowercased.font)
                    .foregroundStyle(ColorRole.text.color)
                    .lineLimit(1)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 40)
                    .background(Material.chromeBar, in: Capsule())
                    .edge()
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)

            Button(action: start) {
                VStack(alignment: .leading, spacing: 6) {
                    ZStack {
                        RemoteImage(source: image, longestEdge: Self.stillWidth, withColor: false)
                            .frame(width: Self.stillWidth, height: Self.stillWidth * 9 / 16)
                        // systemfarbe: drawn over a still frame, which is always a picture and never the page — white and a dark veil read on any picture in both themes.
                        Color.black.opacity(0.35)
                        mark
                    }
                    .frame(width: Self.stillWidth, height: Self.stillWidth * 9 / 16)
                    .clipShape(
                        RoundedRectangle(cornerRadius: MetricsBoard.phone.imageRadius, style: .continuous))

                    Text(verbatim: title)
                        .font(TypeLevel.label.font.weight(.semibold))
                        .foregroundStyle(ColorRole.text.color)
                        .lineLimit(1)
                        .frame(width: Self.stillWidth, alignment: .leading)
                }
                .padding(8)
                .background(Material.chromeBar, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .edge()
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                Text(verbatim: PlaybackWording.offer(similar: similar, seconds: state.secondsLeft))
            )
            .accessibilityValue(Text(verbatim: title))
        }
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }

    private var mark: some View {
        ZStack {
            if !similar {
                // systemfarbe: drawn over a still frame, which is always a picture and never the page — white and a dark veil read on any picture in both themes.
                Circle().stroke(Color.white.opacity(0.25), lineWidth: 3.5)
                Circle()
                    .trim(
                        from: 0,
                        to: min(1, max(0, 1 - CGFloat(state.secondsLeft) / CGFloat(NextUpPrompt.countdown)))
                    )
                    // systemfarbe: drawn over a still frame, which is always a picture and never the page — white and a dark veil read on any picture in both themes.
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: state.secondsLeft)
            }
            Image(systemName: "play.fill")
                // festeschrift: a mark inside a small fixed picture (96 × 54 / the 40 pt ring) — it must not grow with Dynamic Type beyond the frame it sits in.
                .font(.system(size: 15, weight: .bold))
                // systemfarbe: drawn over a still frame, which is always a picture and never the page — white and a dark veil read on any picture in both themes.
                .foregroundStyle(Color.white)
        }
        .frame(width: 40, height: 40)
    }
}

/// The button for skipping a section — **only within the section's window.**
///
/// New on the phone since AP58 R4; the label names the section (intro, recap, credits),
/// the same wording as on the TV (``Flows/PlaybackWording``).
struct SkipButton: View {

    let kind: MediaSegment.Kind
    /// After skipping by itself (AP85): "Intro skipped · Back".
    var isUndo = false
    let jump: () -> Void

    var body: some View {
        Button(action: jump) {
            Text(appKey: isUndo ? PlaybackWording.undoSkip(kind) : PlaybackWording.skip(kind))
                .font(TypeLevel.label.font.weight(.semibold))
                .foregroundStyle(ColorRole.text.color)
                .lineLimit(1)
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .background(Material.chromeBar, in: Capsule())
                .edge()
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .transition(.opacity)
    }
}

/// "Still watching?" on the phone (AP85) — the picture stands paused behind it.
struct StillWatching: View {

    let onContinue: () -> Void
    let onStop: () -> Void

    var body: some View {
        ZStack {
            ColorRole.reason.color.opacity(0.7).ignoresSafeArea()
            VStack(spacing: 18) {
                Text(appKey: "player.stillWatching")
                    .font(TypeLevel.header.font)
                    .foregroundStyle(ColorRole.text.color)
                HStack(spacing: 12) {
                    Button(action: onContinue) {
                        Text(appKey: "player.keepWatching")
                            .font(TypeLevel.label.font.weight(.semibold))
                            .foregroundStyle(ColorRole.textOnLight.color)
                            .padding(.horizontal, 20)
                            .frame(minHeight: 44)
                            .background(ColorRole.text.color, in: Capsule())
                    }
                    Button(action: onStop) {
                        Text(appKey: "player.stopWatching")
                            .font(TypeLevel.label.font.weight(.semibold))
                            .foregroundStyle(ColorRole.text.color)
                            .padding(.horizontal, 20)
                            .frame(minHeight: 44)
                            .background(Material.chromeBar, in: Capsule())
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .transition(.opacity)
    }
}
