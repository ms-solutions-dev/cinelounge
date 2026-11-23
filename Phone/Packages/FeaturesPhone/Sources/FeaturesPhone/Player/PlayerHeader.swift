import DesignSystemPhone
import Playback
import SwiftUI

/// Title, way back and the buttons at the top right.
///
/// **Every target is 44 × 44, also after fading out.** The usability pass found 22 × 22
/// here for "Back" and 21 × 21 each for subtitles, AirPlay and More — on a screen held
/// sideways in both hands, whose upper corners the thumbs can just reach.
///
/// **If the title fits next to the buttons, it stands there — otherwise below, across
/// the full width and in two lines** (on-device test build 1332, 2026-09-27). In portrait
/// about 25 points remained next to Back, subtitles, Info, Zoom, Picture in Picture and
/// AirPlay, and the title read "Sc…". The Zoom button has been gone since then
/// (``CommandButtons``), but even without it there is no room in portrait for a real
/// title. It is therefore no longer truncated but wrapped: ``ViewThatFits`` takes the
/// one line as long as title and episode line fit entirely — in landscape almost always
/// — and otherwise the second row under the buttons.
struct PlayerHeader: View {

    let host: EngineHost
    let title: String
    let beside: String?
    let hasSubtitles: Bool
    let back: () -> Void
    let trackSelection: () -> Void

    /// The source choice — **`nil` where there is nothing to choose.**
    ///
    /// The same rule as with the subtitle button next to it: gone instead of greyed out. A
    /// media server has one file and a channel one stream; the choice between third-party
    /// addresses exists only with the portals, and there only if there is more than one.
    var sourceChoice: (() -> Void)?

    /// The channel list over the picture — **`nil` where no channel is running.**
    var channelList: (() -> Void)?

    /// The board for the title — see ``CommandButtons/infoBoard``.
    var infoBoard: (() -> Void)?

    /// What happens when the viewer returns from the small window.
    var exitPictureInPicture: () -> Void = {}

    /// Short notes from the button row — see ``PlayerView/briefHint``.
    var report: (String) -> Void = { _ in }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Metrics.targetSpacing) {
                backPath
                titleBlock(rows: 1)
                Spacer(minLength: MetricsBoard.phone.gutter)
                buttons
            }
            VStack(alignment: .leading, spacing: MetricsBoard.phone.gutter) {
                HStack(spacing: Metrics.targetSpacing) {
                    backPath
                    Spacer(minLength: MetricsBoard.phone.gutter)
                    buttons
                }
                titleBlock(rows: 2)
            }
        }
        .padding(.horizontal, MetricsBoard.phone.margin)
    }

    private var backPath: some View {
        Button(action: back) {
            Image(systemName: Glyph.back.name)
        }
        .buttonStyle(.rounded)
        .accessibilityLabel(Text(app: "common.back"))
    }

    /// Title and episode line.
    ///
    /// **In the one line nothing is truncated, it is rejected.** `fixedSize` reports the
    /// full width to ``ViewThatFits``; if it does not fit, the second row applies. There
    /// the title may take two lines and shrinks to 80 percent at most — a series title with
    /// an episode number is long, and it has to stay legible all the same.
    @ViewBuilder
    private func titleBlock(rows: Int) -> some View {
        let isSingleLine = rows == 1
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: title)
                .font(TypeLevel.header.font)
                .minimumScaleFactor(isSingleLine ? 1 : 0.8)
                .lineLimit(rows)
                .fixedSize(horizontal: isSingleLine, vertical: !isSingleLine)
                .foregroundStyle(ColorRole.text.color)
            if let beside {
                Text(verbatim: beside)
                    .font(TypeLevel.lowercased.font)
                    .foregroundStyle(ColorRole.textMatt.color)
                    .lineLimit(1)
                    .fixedSize(horizontal: isSingleLine, vertical: false)
            }
        }
        .frame(maxWidth: isSingleLine ? nil : .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    /// **The row lives in its own file.** It has grown from one button to four, and the
    /// rule by which each one appears is the same for all — see ``CommandButtons``.
    private var buttons: some View {
        CommandButtons(
            host: host, hasSubtitles: hasSubtitles, trackSelection: trackSelection,
            sourceChoice: sourceChoice, exitPictureInPicture: exitPictureInPicture,
            channelList: channelList, infoBoard: infoBoard,
            report: report)
    }
}
