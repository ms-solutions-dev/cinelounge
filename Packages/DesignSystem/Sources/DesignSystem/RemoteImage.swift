import CoreGraphics
import Foundation
import SwiftUI

/// An image from an address, with a styled placeholder in the meantime.
///
/// Deliberately not Apple's `AsyncImage`: it retains nothing and reloads on every
/// appearance — when scrolling through a library every
/// tile flickers as a result. That is exactly what users of comparable apps complain about.
public struct RemoteImage: View {

    private let url: URL?
    private let contentMode: ContentMode
    /// Where the image sits when it is larger than its surface.
    ///
    /// **This is the crop anchor, and it belongs here.** With `contentMode: .fill`
    /// the image grows beyond the surface; where it is cut off is decided by
    /// this alignment. An `alignment` on the call site's `.frame` has no effect — there
    /// the image view as a whole is aligned, and it is exactly as large as the
    /// frame.
    ///
    /// Centered is the right default for posters and tiles. For the header it is
    /// the wrong one: a 16:9 background image in a surface of 2.23:1
    /// loses 220 points, centered that is 110 at the top — and the subject slides up out of
    /// the image.
    private let alignment: Alignment
    /// At what size the surface is **drawn**, in points.
    ///
    /// Only for downscaling when decoding — the layout is still determined by the
    /// call site via `.frame(…)`. Merging the two would be tempting, but would
    /// not work everywhere: the header takes the full width, a logo has only
    /// an upper limit, and a channel icon fills what the row leaves it.
    ///
    /// Without it the image is decoded at full size — correct only where the surface
    /// is not known until runtime.
    private let displaySize: CGSize?
    /// Surcharge for the enlargement in focus. For surfaces that do not
    /// enlarge, 1 belongs here.
    private let headroom: CGFloat
    /// How far to enlarge beyond filling — **from the anchored
    /// edge**.
    ///
    /// The anchor alone has a stop: anchored at the top, the image's top edge lies
    /// on the top edge of the surface, and the subject cannot get lower that way. Whoever wants to bring it
    /// further down has to go into the image; then it grows away from
    /// the anchored edge. This is paid for with the opposite edges.
    ///
    /// Feeds into the decode size: an image drawn enlarged by twelve percent
    /// also needs twelve percent more pixels, otherwise it gets interpolated soft.
    private let zoom: CGFloat

    /// The image — and the address it belongs to.
    ///
    /// **The address belongs with it, and that was a bug.** Here stood only the image,
    /// and the task returned immediately on `image != nil`. If the address of an
    /// existing view changes, the old image is still there — the view
    /// therefore kept the first image it had ever loaded, forever.
    ///
    /// It was noticed on the fixed info column in the grid: **one** instance
    /// whose title changes on every focus move. It looked as if images
    /// were "sometimes not loaded properly" — nothing was ever loaded, it was just never
    /// replaced. The same trap hit the preview while scrubbing.
    @State private var image: Image?
    @State private var loadedURL: URL?
    @State private var didFail = false

    /// - Parameter placeholderSymbol: What is shown in the empty frame. The default is
    ///   the film strip — right for posters and episode images, **wrong for
    ///   a person** (user finding 2026-08-22: at the provider the source delivers
    ///   only names and no portraits, and every cast circle then showed
    ///   a film strip).
    public init(
        url: URL?,
        contentMode: ContentMode = .fill,
        alignment: Alignment = .center,
        displaySize: CGSize? = nil,
        headroom: CGFloat = ImageSizing.focusHeadroom,
        zoom: CGFloat = 1,
        placeholderSymbol: String = "film"
    ) {
        self.url = url
        self.contentMode = contentMode
        self.alignment = alignment
        self.displaySize = displaySize
        self.headroom = headroom
        self.zoom = zoom
        self.placeholderSymbol = placeholderSymbol

        // **The cache is queried here, not only in `.task`.**
        //
        // Previously every tile started at `nil`, that is with the placeholder, and fetched
        // its image afterwards — even if it had long been in memory. The
        // way there led via an actor and back to the main thread; while
        // scrolling both are busy, and "immediately" became one to two
        // frames. That was visible as a flash of the gray surface, although
        // the same tile had been visible a second earlier.
        //
        // The access costs one dictionary hit and runs on every rebuild of
        // this struct — that is the cheapest place there is: it
        // decides whether the very first frame already shows the right image.
        let limit = Self.decodeLimit(displaySize, headroom * zoom)
        let ready = url.flatMap { ImageCache.shared.cachedImage(for: $0, decodeLimit: limit) }
        _image = State(initialValue: ready)
        _loadedURL = State(initialValue: ready == nil ? nil : url)
    }

    public var body: some View {
        ZStack(alignment: alignment) {
            if let image {
                image
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    // At `zoom == 1` an identity transform and thus free — the
                    // condition would cost more than the effect, and it would depend on
                    // a value that never changes per call site.
                    .scaleEffect(zoom, anchor: zoomAnchor)
            } else {
                placeholder
            }
        }
        .task(id: url) {
            guard let url else {
                image = nil
                loadedURL = nil
                didFail = true
                return
            }
            // Only the image for the **current** address counts as present.
            if loadedURL == url, image != nil { return }

            // When the address changes too, look first without waiting: the fixed
            // info column and the header swap their image on an
            // *existing* instance — the path via `init` does not apply to them,
            // their state is already set.
            if let ready = ImageCache.shared.cachedImage(for: url, decodeLimit: decodeLimit) {
                image = ready
                loadedURL = url
                didFail = false
                return
            }

            let fetched = await ImageCache.shared.image(for: url, decodeLimit: decodeLimit)
            // Whoever has been cancelled in the meantime belongs to an address that nobody
            // wants to see anymore — its result must not overwrite that of the running task.
            guard !Task.isCancelled else { return }

            // The old image stays until the new one is there. A placeholder
            // in between means a blink on every focus move in the grid, and
            // from the cache the new image is there immediately anyway.
            image = fetched
            loadedURL = fetched == nil ? nil : url
            didFail = fetched == nil
        }
        .animation(.easeOut(duration: 0.2), value: image != nil)
    }

    /// The edge length to which decoding downscales.
    ///
    /// As a static calculation, because ``init(url:contentMode:alignment:displaySize:headroom:zoom:)``
    /// needs it before the instance exists. Two versions of it would be a
    /// silent source of errors: one determines the key in the cache,
    /// the other would then miss — and that would look like a cache
    /// that never hits.
    static func decodeLimit(_ displaySize: CGSize?, _ headroom: CGFloat) -> Int? {
        displaySize.map { ImageSizing.decodeLimit(points: $0, headroom: headroom) }
    }

    private var decodeLimit: Int? {
        Self.decodeLimit(displaySize, headroom * zoom)
    }

    /// From where the enlargement grows: from the same edge that the crop
    /// hangs on. Anything else would cancel the anchor that the call site
    /// has just set.
    /// See ``init(url:contentMode:alignment:displaySize:headroom:zoom:placeholderSymbol:)``.
    private let placeholderSymbol: String

    private var zoomAnchor: UnitPoint {
        if alignment == .top { return .top }
        if alignment == .bottom { return .bottom }
        return .center
    }

    /// No empty gray: if an image is missing — the normal case for home videos —, the
    /// surface should still look designed instead of looking like an error.
    private var placeholder: some View {
        ZStack {
            ColorRole.surfaceHigh.color
            if didFail {
                Image(systemName: placeholderSymbol)
                    .font(.system(size: 44))
                    .foregroundStyle(ColorRole.textQuiet.color)
            }
        }
    }
}
