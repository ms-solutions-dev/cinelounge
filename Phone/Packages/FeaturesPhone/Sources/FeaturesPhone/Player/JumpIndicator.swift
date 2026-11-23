import DesignSystemPhone
import SwiftUI

/// What a double tap on the left or right half has just done.
///
/// **The finding of 2026-09-07. (E38):** *"The double tap ±10 s in the player shows nothing —
/// no ring, no capsule, like every comparison player has."* So the gesture jumped, and
/// the only thing the viewer saw of it was a picture that continued at a different
/// position. On a channel without scrubbing he saw **nothing at all** — and could not
/// tell whether the app does not know the gesture or whether this title cannot do it.
///
/// **Why it accumulates.** Ten seconds are rarely enough; one taps two, three times in a
/// row. If every tap showed "10 s", the same number would stand there three times while
/// the film jumps thirty seconds — the display would contradict what it is meant to
/// explain. As long as it is up, it counts along; once it is gone, it starts anew. YouTube
/// and the system player use the same rule.
///
/// **It stands on the side that was tapped**, and not in the middle: there lies the pause
/// button, and the side is at the same time the answer to "where to".
struct JumpIndicator: View {

    /// Direction and sum — both together, because a change of direction resets the sum and
    /// the display would otherwise show "−10 s" with the arrow pointing forward.
    ///
    /// **`nonisolated`, like the rules in ``SwipeZones``.** A view hangs on the main thread,
    /// a calculation does not — and the release build objected to exactly that on 2026-09-10,
    /// while `swift test` still let it pass.
    nonisolated struct State: Equatable {
        var forward: Bool
        var seconds: TimeInterval

        /// A further tap in the same direction adds to it, one in the other direction starts
        /// over.
        nonisolated func and(_ span: TimeInterval) -> State {
            let forwardAmount = span > 0
            guard forwardAmount == forward else { return State(forward: forwardAmount, seconds: abs(span)) }
            return State(forward: forward, seconds: seconds + abs(span))
        }

        nonisolated static func first(_ span: TimeInterval) -> State {
            State(forward: span > 0, seconds: abs(span))
        }
    }

    let state: State

    /// **With a symbol if there is room, otherwise only the number** (finding B1,
    /// 2026-09-25) — with large type the display was taller than the strip above +30 and sat
    /// on its head.
    ///
    /// **It catches no touch** — the same rule as with the ``HintCapsule``: anyone who taps
    /// four times taps on the place where it stands. **And it is information and not a
    /// button:** the screen-reader aid reads it along when it appears, but nobody is meant to
    /// tap on it — the second way to the same action is carried by the ``GestureCommands``.
    var body: some View {
        ViewThatFits(in: .vertical) {
            withSymbol
            Text(verbatim: Self.wording(state.seconds))
                .font(TypeLevel.header.font)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .foregroundStyle(ColorRole.text.color)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Material.chromeBar, in: Capsule())
                .edge()
        }
        .allowsHitTesting(false)
        .transition(.opacity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: Self.wording(state.seconds)))
    }

    private var withSymbol: some View {
        VStack(spacing: MetricsBoard.phone.gutter / 2) {
            // **From the scale and not from a point size.** `Typografie/title` grows with the
            // system type; a fixed size would be the only element standing still at
            // `accessibilityExtraExtraExtraLarge` while the number beneath it grew — exactly the
            // error that AP5 counts.
            Image(systemName: state.forward ? Glyph.skipForward.name : Glyph.skipBack.name)
                .font(TypeLevel.title.font)
            Text(verbatim: Self.wording(state.seconds))
                .font(TypeLevel.header.font)
                .monospacedDigit()
        }
        .foregroundStyle(ColorRole.text.color)
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(Material.chromeBar, in: Capsule())
        .edge()
    }

    /// "10 s" — **a number with a unit and not a sentence.**
    ///
    /// Deliberately in no language catalog: "s" is the unit of the second in all three
    /// languages of this app, and a key for it would be one that nobody ever translates. The
    /// same consideration as with ``SwipeZones/speedText``.
    nonisolated static func wording(_ seconds: TimeInterval) -> String {
        "\(Int(seconds.rounded())) s"
    }
}
