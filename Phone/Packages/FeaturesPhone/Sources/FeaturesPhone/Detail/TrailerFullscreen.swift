import AVKit
import Core
import DesignSystemPhone
import Playback
import SwiftUI
import Trailer

#if canImport(UIKit)
    import UIKit
#endif

/// The trailer of a foreign title in full screen (AP78) — with sound, because someone pressed here
/// and did not merely linger; ``HeaderTrailer`` stays muted, for its own reason.
///
/// A separate, one-off player and not the app player: that one knows position, tracks and
/// chapters of a title, and a trailer has none of that. It writes nothing to the playback ledger
/// and does not count as watched.
struct TrailerFullscreen: View {

    let address: URL
    let end: () -> Void

    @State private var player: AVPlayer?

    var body: some View {
        ZStack(alignment: .topLeading) {
            // systemfarbe: black as the background, because the trailer in 2.39:1 format has bars at top and
            // bottom and those should be black, not the app's surface.
            Color.black.ignoresSafeArea()
            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            }
            Button(action: end) {
                Image(systemName: Glyph.close.name)
            }
            .buttonStyle(.rounded)
            .accessibilityLabel(Text(app: "common.done"))
            .padding(.horizontal, MetricsBoard.phone.margin)
            .padding(.top, 8)
        }
        .task(id: address) {
            // First fix the audio track, then play: never a dubbed version, see
            // ``Playback/OriginalAudio`` (2026-11-08).
            let element = AVPlayerItem(url: address)
            await OriginalAudio.select(forItem: element)
            let new = AVPlayer(playerItem: element)
            new.play()
            player = new
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
        .onReceive(
            NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)
        ) { _ in
            end()
        }
    }
}

extension View {

    /// The trailer in full screen above the detail page — on the device only: `fullScreenCover`
    /// does not exist on macOS, and the checks of this package run there.
    func trailerFullscreen(_ playback: Binding<DetailModel.TrailerPlayback?>) -> some View {
        #if os(iOS)
            return fullScreenCover(item: playback) { running in
                TrailerFullscreen(address: running.url) { playback.wrappedValue = nil }
            }
        #else
            return self
        #endif
    }

    /// The board when resolution fails (AP78): YouTube changed or the
    /// video is blocked. With the jump into the YouTube app, if it is installed.
    func trailerErrorBoard(_ youtubeID: Binding<String?>) -> some View {
        alert(
            Text(app: "detail.trailerUnavailable"),
            isPresented: Binding(
                get: { youtubeID.wrappedValue != nil },
                set: { if !$0 { youtubeID.wrappedValue = nil } })
        ) {
            if let id = youtubeID.wrappedValue, !id.isEmpty,
                let url = TrailerResolution.youtubeApp(id), TrailerBoard.canOpen(url)
            {
                Button {
                    TrailerBoard.open(url)
                } label: {
                    Text(app: "detail.trailerOpenYouTube")
                }
            }
            Button(role: .cancel) {
            } label: {
                Text(app: "common.ok")
            }
        } message: {
            Text(app: "detail.trailerUnavailableText")
        }
    }
}

/// The jump into the YouTube app — on the device only; the package also compiles for macOS for the checks,
/// and there is no `UIApplication` there.
enum TrailerBoard {
    @MainActor static func canOpen(_ url: URL) -> Bool {
        #if canImport(UIKit)
            return UIApplication.shared.canOpenURL(url)
        #else
            return false
        #endif
    }

    @MainActor static func open(_ url: URL) {
        #if canImport(UIKit)
            UIApplication.shared.open(url)
        #endif
    }
}
