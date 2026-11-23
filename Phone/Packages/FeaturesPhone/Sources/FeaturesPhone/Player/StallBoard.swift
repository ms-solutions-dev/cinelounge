import Core
import DesignSystemPhone
import Flows
import SwiftUI

/// The board "the picture is stuck" — **a sentence, not a technical term**
/// (decision 12).
///
/// **Until 2026-09-25 the spinner on the phone turned without end** when a channel stopped
/// after minutes: the player had long been in `.isPlaying`, and there was no more information
/// there. The board appears as soon as ``PlayerModel/settled`` flips, and names what the
/// interpretation from `Core` found (``Core/StallInterpretation``). **The sentence per
/// finding** has lived in ``StallWording`` for both devices since AP58 R3 — without a
/// finding, the indeterminate one.
///
/// **No action.** No button, no "try again" — at this tier the app resets nothing, and a
/// button that promises it would be the sentence that lies (tier 3 waits for the
/// measurement). That is why the board also catches no touch: swipe way back and bar stay
/// operable beneath it.
struct StallBoard: View {

    let finding: StallInterpretation.Finding?
    /// Where it plays to and what the line delivers — for "Line is tight" (AP75), see
    /// ``Flows/StallWording/lineTight(_:_:)``.
    var target: PlaybackTarget? = nil
    var line: LineFinding? = nil

    private var lineTight: Bool { StallWording.lineTight(target, line) && finding == nil }

    /// **Two versions, and the stage gets the one that fits** (finding B1, 2026-09-25).
    ///
    /// Until then this said `.fixedSize(horizontal: false, vertical: true)`: the board did
    /// not accept the height that the ``FeedbackStage`` proposed to it at all, and with
    /// large type drew far beyond its zone — at 110 × 40 points, 116 points tall. The tight
    /// version dispenses with the spinner, takes two lines and may shrink the type down to
    /// half.
    var body: some View {
        ViewThatFits(in: .vertical) {
            board(tight: false)
            board(tight: true)
        }
        .allowsHitTesting(false)
        .transition(.opacity)
        .accessibilityElement(children: .combine)
    }

    private func board(tight: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: MetricsBoard.phone.gutter) {
            if !tight {
                ProgressView()
                    .tint(ColorRole.text.color)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(appKey: StallWording.key(finding, target: target, line: line))
                    .font(TypeLevel.footer.font)
                    .foregroundStyle(ColorRole.text.color)
                if lineTight, !tight, let line {
                    Text(
                        app:
                            "player.stillstandLeitungKnappHint \(LineFinding.mbit(line.lineMbit)) \(LineFinding.mbit(line.demandMbit))"
                    )
                    .font(TypeLevel.footer.font)
                    .foregroundStyle(ColorRole.textQuiet.color)
                }
            }
            .multilineTextAlignment(.leading)
            .lineLimit(tight ? 2 : nil)
            .minimumScaleFactor(tight ? 0.5 : 1)
        }
        .padding(.horizontal, tight ? 10 : 18)
        .padding(.vertical, tight ? 4 : 12)
        .background(
            Material.chromeBar, in: RoundedRectangle(cornerRadius: MetricsBoard.phone.cardRadius)
        )
        .edge()
    }
}
