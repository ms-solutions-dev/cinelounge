import Core
import SwiftUI

// **`canImport(UIKit)` and not `os(tvOS)`** — the condition was from the start
// whether UIKit exists, and the comment below said so too ("On the Mac there is no
// UIKit"). As long as only the TV built, both were the same; since the phone came
// along they are not any more — and there the picture stayed black, although
// `AVPlayerLayer` and `AVSampleBufferDisplayLayer` are the same on iOS.
#if canImport(UIKit)
    import AVFoundation
    import UIKit
#endif

/// How the picture is laid into the surface.
///
/// **On the TV there is no such choice, and that stays so.** There
/// ``ImageLayout/fullImage`` is fixed — a TV has the same format as almost everything
/// that runs on it, and the remote has no pinch gesture. The default value of
/// ``VideoSurface/init(host:state:)`` ensures that nothing has to be adjusted there.
///
/// **On the phone it is a real question:** a 21:9 film on a 19.5:9 screen sits with
/// bars. Whoever wants them gone pays with the edges — two answers, no third. What
/// the viewer last wanted is remembered by `FeaturesPhone.PictureFill`, and per
/// aspect ratio: a 4:3 home video must not be cropped by the decision for a cinema
/// film.
public enum ImageLayout: String, Sendable, CaseIterable {

    /// Everything is visible, bars in return. **The default.**
    case fullImage = "ganzesBild"

    /// No bars, cropped in return.
    case fillsScreen = "bildschirmfuellend"

    public var other: ImageLayout { self == .fullImage ? .fillsScreen : .fullImage }

    #if canImport(UIKit)
        var gravity: AVLayerVideoGravity {
            self == .fullImage ? .resizeAspect : .resizeAspectFill
        }
    #endif
}

/// The picture of the engine that is currently running.
///
/// Deliberately only the picture and nothing more: control bar, caption and selection
/// lie above it and are built separately. This view knows no state except the
/// question of which engine is playing.
public struct VideoSurface: View {

    /// Observed and not merely held: when the engine changes, the surface must be
    /// replaced. A mere reference would leave the old bridge standing, and the picture
    /// would stay black.
    ///
    /// **Since AP32 (2026-09-11) without annotation**, and that is no loss: an
    /// `@Observable` is observed because a view **reads** its properties — not because it
    /// carries an attribute. What this surface reads is `engine`, and that is exactly
    /// what it now listens to.
    private let host: EngineHost

    /// How the picture sits. **The default is "whole picture"** — it always applies on the
    /// TV and on the phone until the viewer has said something else for this aspect
    /// ratio.
    private let state: ImageLayout

    public init(host: EngineHost, state: ImageLayout = .fullImage) {
        self.host = host
        self.state = state
    }

    public var body: some View {
        surface
            // The film goes to the edge. The safe area applies to the controls, not to the
            // picture — a film with an 80-point margin looks like a bug.
            .ignoresSafeArea()
    }

    @ViewBuilder
    private var surface: some View {
        #if canImport(UIKit)
            // Since the VLC removal there is only the one drawing surface — the host replaces a
            // legacy `.vlc` decision with the system engine anyway.
            if let engine = host.nativeEngine {
                PlayerLayerSurface(
                    engine: engine, pictureInPicture: host.pictureInPicture, state: state)
            } else if let engine = host.rendererEngine {
                RendererLayerSurface(
                    engine: engine, pictureInPicture: host.pictureInPicture, state: state)
            } else {
                // systemfarbe: The surface of a video before it plays — black like its bars.
                Color.black
            }
        #else
            // systemfarbe: On the Mac there is no UIKit. A black surface is no stopgap but the
            // precondition for `Features` being compiled and checked at all.
            Color.black
        #endif
    }
}

#if canImport(UIKit)

    /// The surface for the system player.
    ///
    /// Takes the **engine** and not merely the player: the layer is attached to it so that
    /// it can attest to its first drawn frame — the basis of the honest startup
    /// measurement (roadmap AP5).
    private struct PlayerLayerSurface: UIViewRepresentable {

        let engine: NativePlaybackEngine
        let pictureInPicture: PictureInPicture
        let state: ImageLayout

        func makeUIView(context: Context) -> PlayerLayerView {
            let view = PlayerLayerView()
            view.backgroundColor = .black
            view.playerLayer?.player = engine.player
            // **The default stays `resizeAspect`**: a home video in 4:3 would otherwise be
            // cropped at top and bottom, and nobody would think of the margin as the cause. Since
            // 2026-09-08 it is a default and no longer a fixed setting — on the phone the viewer may
            // choose something else per aspect ratio (AP4).
            view.playerLayer?.videoGravity = state.gravity
            if let layer = view.playerLayer {
                engine.attachDisplayLayer(layer)
                // Picture in Picture hangs on the surface, not on the engine (AP8).
                pictureInPicture.attach(layer)
            }
            return view
        }

        func updateUIView(_ uiView: PlayerLayerView, context: Context) {
            if uiView.playerLayer?.player !== engine.player {
                uiView.playerLayer?.player = engine.player
            }
            // **Here too, otherwise the choice applies only from the next film.** `makeUIView`
            // runs once; switching happens in the middle of playback.
            if uiView.playerLayer?.videoGravity != state.gravity {
                uiView.playerLayer?.videoGravity = state.gravity
            }
            // Here too, not only at construction: when the host changes the engine, SwiftUI
            // often keeps the view — only this place then still gets visited. The engine itself
            // guards against attaching the same layer twice.
            if let layer = uiView.playerLayer {
                engine.attachDisplayLayer(layer)
            }
        }
    }

    /// The surface for the direct renderer.
    ///
    /// **The layer belongs to the engine**, not to this view — the frames flow before a
    /// view comes into being. Here it is only hung in and re-aligned on every size
    /// change; that is the price of it not being able to be the view's own layer.
    private struct RendererLayerSurface: UIViewRepresentable {

        let engine: SampleBufferPlaybackEngine
        /// Picture in Picture — **here too**, since the direct renderer can do it (AP2,
        /// 2026-09-07). Until then only the system-player surface attached the controller, and the
        /// button stayed grey on every channel of the `ts` access.
        let pictureInPicture: PictureInPicture
        let state: ImageLayout

        func makeUIView(context: Context) -> RendererLayerView {
            let view = RendererLayerView()
            view.backgroundColor = .black
            view.host(engine.displayLayer)
            // **The direct renderer can do it too**, and that is no aside: it plays the channels
            // of the `ts` access. If the choice existed only on the system player, it would hang
            // on the origin of the title instead of its format.
            engine.displayLayer.videoGravity = state.gravity
            pictureInPicture.attach(engine)
            return view
        }

        func updateUIView(_ uiView: RendererLayerView, context: Context) {
            // When the host changes the engine, SwiftUI often keeps the view — then the new
            // layer must replace the old one.
            uiView.host(engine.displayLayer)
            if engine.displayLayer.videoGravity != state.gravity {
                engine.displayLayer.videoGravity = state.gravity
            }
            pictureInPicture.attach(engine)
        }
    }

    /// A view that carries a foreign layer and gives it its layout.
    private final class RendererLayerView: UIView {

        private weak var hosted: CALayer?

        func host(_ layer: CALayer) {
            guard hosted !== layer else { return }
            hosted?.removeFromSuperlayer()
            hosted = layer
            layer.frame = bounds
            self.layer.addSublayer(layer)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            // Without animation: a layer that swims behind when rotating or fading in looks like
            // a bug.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hosted?.frame = bounds
            CATransaction.commit()
        }
    }

    /// A view whose **own** layer is the video layer.
    ///
    /// `layerClass` instead of an additionally hung-in `AVPlayerLayer`: a sublayer gets no
    /// layout and would have to be re-aligned by hand on every size change. Whoever
    /// forgets that has a picture of size zero or one that sits off after rotating the
    /// screen.
    private final class PlayerLayerView: UIView {

        override class var layerClass: AnyClass { AVPlayerLayer.self }

        /// Optional instead of a forced cast: a crash at this place would be too high a price
        /// for a pure display problem.
        var playerLayer: AVPlayerLayer? { layer as? AVPlayerLayer }
    }

#endif
