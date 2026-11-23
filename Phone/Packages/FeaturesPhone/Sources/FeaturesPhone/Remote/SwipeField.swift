import DesignSystemPhone
import SwiftUI

/// The surface for swiping — **and explicitly no rebuilt trackpad.**
///
/// **Why not rebuild the Siri Remote.** That would have been the obvious form:
/// up, down, select. It would be the worse remote for the same device — a
/// glass field hits worse than a trackpad you operate blind, and the real
/// remote is mostly in the same room. **What the phone can do better is everything
/// for which the Siri Remote has no button.**
///
/// **So this surface seeks, and nothing else.** Swiping horizontally moves the position,
/// double-tapping jumps ten seconds — the same two gestures as in the own player
/// (``SwipeZones``), with the same numbers. Whoever switches between the two screens
/// should not have to relearn.
///
/// **Reporting happens on release.** Seeking on every intermediate frame would mean
/// making the TV jump fifty times a second — over a network that takes half a second.
/// The preview follows the finger, the jump follows the end of the movement.
struct SwipeField: View {

    /// How long the movie is — `nil` where there is no end (channel).
    let duration: TimeInterval?
    /// Where it currently is.
    let location: TimeInterval

    /// Jumps to this position.
    let jumpTo: (TimeInterval) -> Void
    /// Jumps by this amount.
    let jumpBy: (TimeInterval) -> Void

    @State private var lookahead: TimeInterval?

    /// How far a full screen seeks across — **the same number as in the own
    /// player.** Ninety seconds across the width; finer would no longer be accurate, coarser
    /// would be a jump instead of a seek.
    static let span: TimeInterval = 90

    /// How far a double tap jumps — the system's number, as everywhere.
    static let jump: TimeInterval = 10

    var body: some View {
        GeometryReader { space in
            ZStack {
                ColorRole.surface.color
                if let lookahead {
                    HintCapsule(
                        wording: Timeline.time(lookahead) + "  "
                            + SwipeZones.distanceText(lookahead - location))
                } else {
                    // **The surface says what it can do.** An empty rectangle on a
                    // screen full of buttons is the one place where nobody swipes on
                    // their own.
                    Text(appKey: canSeek ? "remote.swipeHint" : "remote.swipeLive")
                        .font(TypeLevel.label.font)
                        .foregroundStyle(ColorRole.textQuiet.color)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, MetricsBoard.phone.margin)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { location in duplicate(location, in: space.size) }
            .gesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { drag in move(drag, in: space.size) }
                    .onEnded { _ in release() }
            )
        }
        .frame(height: 180)
        .clipShape(RoundedRectangle(cornerRadius: MetricsBoard.phone.cardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: MetricsBoard.phone.cardRadius)
                .strokeBorder(ColorRole.line.color, lineWidth: 0.5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(app: "remote.swipeArea"))
        // **The same twins as in the own player** (E66): swiping cannot be performed with
        // the screen reader — not harder, but not at all.
        .accessibilityAction(named: Text(app: "player.back10")) { jumpBy(-Self.jump) }
        .accessibilityAction(named: Text(app: "player.forward10")) { jumpBy(Self.jump) }
    }

    private var canSeek: Bool { (duration ?? 0) > 0 }

    private func move(_ drag: DragGesture.Value, in surface: CGSize) {
        guard canSeek, let duration else { return }
        let portion = Double(drag.translation.width / max(1, surface.width))
        lookahead = min(duration, max(0, location + portion * Self.span))
    }

    private func release() {
        guard let target = lookahead else { return }
        lookahead = nil
        jumpTo(target)
    }

    private func duplicate(_ location: CGPoint, in surface: CGSize) {
        guard canSeek else { return }
        // **The same dead centre as in the own player.** A double tap exactly on the
        // seam would otherwise be a coin toss.
        let portion = Double(location.x / max(1, surface.width))
        guard let span = SwipeZones.span(at: portion) else { return }
        jumpBy(span)
    }
}
