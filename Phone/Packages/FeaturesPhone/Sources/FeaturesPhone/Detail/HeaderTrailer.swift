import AVKit
import DesignSystemPhone
import SwiftUI

/// The trailer takes the place of the header image — and ends by itself on scrolling away.
///
/// **The transfer of the "linger three seconds" from the TV.** There the
/// trailer starts when focus stays on a title; here there is no focus that could
/// linger. What replaces it is the explicit press on the trailer button —
/// and what is moving focus on there is scrolling away here.
///
/// **Muted and without controls.** It stands in place of an image, not of a
/// film: a volume slider and a timeline in a 300-point-high
/// header area would be a second player next to the one waiting one row further down. Whoever
/// wants to hear the film presses the button below.
///
/// **It plays once and does not repeat.** A trailer looping behind the
/// title is no longer an offer after the second round but restlessness on a page on
/// which you want to read.
struct HeaderTrailer: View {

    let address: URL
    let end: () -> Void

    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
                    .disabled(true)
            } else {
                ColorRole.surface.color
            }
        }
        .task(id: address) {
            let new = AVPlayer(url: address)
            // **Muted, and on the player and not on the session.** Whoever touches the
            // audio session interrupts the music that may be playing —
            // for a preview nobody wanted to hear.
            new.isMuted = true
            new.play()
            player = new
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
        // **The end is an end and not a restart.** When the trailer runs out, the
        // header image comes back — otherwise a black still frame would remain, and that looks
        // like a film that was cut off.
        .onReceive(
            NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)
        ) { _ in
            end()
        }
    }
}
