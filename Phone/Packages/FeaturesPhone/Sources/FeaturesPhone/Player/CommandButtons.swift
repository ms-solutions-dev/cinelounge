import DesignSystemPhone
import Playback
import SwiftUI

/// The button row at the top right of the player — subtitles, sources, Picture in Picture, AirPlay.
///
/// **A file of its own, because the row has grown.** Until 2026-09-06 a single
/// subtitle button hung in ``PlayerHeader``; with source choice, Picture in Picture and AirPlay there are
/// four, and the rule by which they appear is the same for all.
///
/// **Gone instead of grayed out, for every single one.** A title without a subtitle track gets
/// no subtitle button, a media server no host choice, a device without
/// Picture in Picture no Picture in Picture. A dimmed button is an invitation that is not
/// honored — the same reasoning as at ``TitleMenuSheet``.
///
/// **Every target stays 44 × 44.** The heaviest finding of the usability check lay
/// exactly here: 21 × 21 for subtitles, AirPlay and More, on a screen that is held
/// sideways in both hands and whose top corners the thumbs just about reach.
/// More buttons therefore does **not** mean smaller buttons: if four do not fit side by side,
/// one drops out — and none shrinks.
///
/// **No zoom key any more** (on-device test build 1332, 2026-09-27). It stood between info and
/// Picture in Picture, and in portrait the title beside it was left with so little room that it
/// shrank to "Sc…". Filling the picture goes via the two-finger gesture as in the TV app and on
/// Netflix (``PinchGesture``); whoever cannot pinch finds it under "More commands"
/// (``GestureCommands``). Until then the button was the obligation for the screen reader — which
/// is now fulfilled by the command, without costing room in the bar.
struct CommandButtons: View {

    let host: EngineHost
    let hasSubtitles: Bool
    let trackSelection: () -> Void
    /// The source choice — `nil` where there is nothing to choose.
    var sourceChoice: (() -> Void)?
    /// What happens when returning from the small window.
    let exitPictureInPicture: () -> Void

    /// The channel list — **`nil` where no channel is playing.**
    ///
    /// **And the row does not get narrower because of it.** With a channel there is no
    /// subtitle track from the server and no host choice; where this button appears,
    /// the other two are gone. Four remain — the same number as with a film.
    var channelList: (() -> Void)?

    /// The board for the title — cast, more episodes, similar (AP58 G1, A4). `nil` where there is
    /// none: for channels and everything without a catalog.
    var infoBoard: (() -> Void)?

    /// Short notices from the row — see ``PlayerView/briefHint``.
    var report: (String) -> Void = { _ in }

    var body: some View {
        HStack(spacing: Metrics.targetSpacing) {
            if hasSubtitles {
                Button(action: trackSelection) {
                    Image(systemName: Glyph.subtitles.name)
                }
                .buttonStyle(.rounded)
                .accessibilityLabel(Text(app: "player.tracks"))
            }

            if let infoBoard {
                Button(action: infoBoard) {
                    Image(systemName: Glyph.info.name)
                }
                .buttonStyle(.rounded)
                .accessibilityLabel(Text(app: "player.aboutTitle"))
            }

            if let sourceChoice {
                Button(action: sourceChoice) {
                    Image(systemName: Glyph.sources.name)
                }
                .buttonStyle(.rounded)
                .accessibilityLabel(Text(app: "common.sources"))
            }

            PictureInPictureView(host: host, back: exitPictureInPicture, rejected: report)

            if let channelList {
                Button(action: channelList) {
                    Image(systemName: Glyph.Tab.live.outlined)
                }
                .buttonStyle(.rounded)
                .accessibilityLabel(Text(app: "player.channels"))
            }

            Button {
                // **The system's picker and none of our own.** Whoever rebuilds it builds
                // a list that would have to be updated with every new device in the home —
                // and the system picker already knows AirPods, car and TV.
                AirPlayRouting.shared.present()
            } label: {
                Image(systemName: Glyph.aerialImage.name)
            }
            .buttonStyle(.rounded)
            .accessibilityLabel(Text(app: "player.airplay"))

            // **The invisible anchor that makes the button next to it possible at all.**
            // `AVRoutePickerView` is a system button with a shape of its own; it stands
            // one point in size in the player, and the row presses it. That way the bar stays
            // uniform and the choice is still the system's.
            AirPlayPickerAnchor()
        }
    }
}
