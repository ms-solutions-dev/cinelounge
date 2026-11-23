import CoreGraphics
import Foundation
import ImageIO

/// Fetches an image, downscales it while decoding and remembers the result.
///
/// **Downscaled while decoding, not afterwards.** `ImageIO` can build an image at the target
/// size without unpacking it completely first. The difference is no fine-tuning: a poster of
/// 1000 × 1500 takes six megabytes unpacked, two hundred kilobytes at tile size — and a
/// shelf shows ten of them side by side.
///
/// The series color falls out of it: it is calculated from the same image that is in memory
/// anyway.
///
/// **Three levels, and the order is the cost order.** First memory (free), then the disk
/// (``ImageStore``, one file access), then the network — through a tunnel with a measured
/// 0.31 Mbit/s the most expensive level by three orders of magnitude. Without the middle
/// level every program start was a complete rebuild, and exactly that was visible on 2026-09-05:
/// the title logo already there, the image behind it still black.
public actor ImageLoader {

    public static let shared = ImageLoader()

    public struct Outcome: Sendable {
        public let image: CGImage
        public let color: AccentPaletteValue?
    }

    /// The series color as a value of its own, so that `Outcome` stays `Sendable`.
    public struct AccentPaletteValue: Sendable, Equatable {
        public let hue: Double
        public let saturation: Double
    }

    private let storage: ImageCacheActor
    private let store: ImageStore?
    private let session: URLSession

    /// What is currently being **preloaded**.
    ///
    /// **Only preloading is here, and there is a reason for that.** Whoever fetches an image
    /// to display it can cancel at any time — when quickly browsing through a shelf that is
    /// exactly the point, otherwise a hundred loads run for ninety images nobody sees. A board
    /// over *all* loads would make the jobs unstructured and thereby defeat the cancellation.
    /// A preload, by contrast, never cancels: it was started because the image is needed soon.
    /// Whoever requests it for display in the meantime attaches to it instead of sending a
    /// second request through the same tunnel.
    private var preloaded: [String: Task<CGImage?, Never>] = [:]

    /// - Parameter ablage: `nil` switches the disk off — for checks that are not to leave
    ///   anything behind.
    public init(
        storage: ImageCacheActor = .shared,
        store: ImageStore? = .shared,
        session: URLSession = .shared
    ) {
        self.storage = storage
        self.store = store
        self.session = session
    }

    /// Loads an image at the requested edge length.
    ///
    /// - Parameters:
    ///   - source: from where
    ///   - pixels: the longer edge in pixels, from ``ImageSizes``
    ///   - withColor: whether the series color is to be calculated too. For an episode image it
    ///     is not worth it — no edge carries it there.
    public func load(_ source: URL, pixels: Int, withColor: Bool = true) async -> Outcome? {
        let key = "\(source.absoluteString)|\(pixels)"
        if let remembered = await storage.image(for: key) {
            return Outcome(
                image: remembered,
                color: withColor ? await color(from: remembered, key: key) : nil)
        }
        if let running = preloaded[key] {
            guard let image = await running.value else { return nil }
            return Outcome(
                image: image,
                color: withColor ? await color(from: image, key: key) : nil)
        }

        guard let image = await fetch(source, pixels: pixels, key: key) else {
            return nil
        }
        return Outcome(
            image: image, color: withColor ? await color(from: image, key: key) : nil)
    }

    /// Makes an image ready without displaying it.
    ///
    /// **For the header area** that pages through eight titles: whoever loads only when a page's
    /// turn comes shows a black area for four seconds while swiping. The color is not calculated
    /// here — it costs a pass over the image and falls due when displaying anyway.
    public func preload(_ sources: [URL], pixels: Int) {
        for source in sources {
            let key = "\(source.absoluteString)|\(pixels)"
            guard preloaded[key] == nil else { continue }
            preloaded[key] = Task {
                let image = await fetch(source, pixels: pixels, key: key)
                forget(key)
                return image
            }
        }
    }

    /// A **cell** from a sheet — for chapter images from the trickplay grid.
    ///
    /// **Why at all** (finding of 2026-09-05 on *Bringrarn Piosiaspeit Slausnonspel*): of sixteen chapters, **one**
    /// carried a still frame. Jellyfin pulls chapter images in a maintenance task that does not
    /// run on many servers — the trickplay sheets, by contrast, it generates for scrubbing
    /// anyway, and in them lies an image every ten seconds. For every chapter mark there is thus
    /// one ready, without anything having to run on the server.
    ///
    /// **The sheet is not kept, only the cell.** A sheet is 10 × 10 cells and sits in memory as
    /// an image at around 22 MB; a film with sixteen chapters touches five of them. Keeping them
    /// would tie up over a hundred megabytes for sixteen thumbnails. Hence: fetch the sheet, cut
    /// out the cells, drop the sheet — what stays in memory is what is displayed.
    ///
    /// **And it is cut with a copy, not with `cropping(to:)`.** A cropped `CGImage` shares the
    /// data provider with its origin and thereby keeps it alive — the sheet would stay in memory
    /// although nobody refers to it any more. Exactly what is to be avoided here.
    ///
    /// - Parameter pixels: the width of **one cell** in pixels.
    public func slice(
        _ sheet: URL, columns: Int, rows: Int, column: Int, row: Int, pixels: Int
    ) async -> CGImage? {
        let key = "\(sheet.absoluteString)#\(column)x\(row)|\(pixels)"
        if let remembered = await storage.image(for: key) { return remembered }
        if let stored = await store?.image(for: key) {
            await storage.create(stored, under: key)
            return stored
        }

        guard columns > 0, rows > 0,
            let full = await fetchAtlas(sheet, pixels: pixels * columns)
        else { return nil }

        let cellWidth = full.width / columns
        let cellHeight = full.height / rows
        guard cellWidth > 0, cellHeight > 0 else { return nil }
        let field = CGRect(
            x: cellWidth * column, y: cellHeight * row, width: cellWidth, height: cellHeight)
        guard let raw = full.cropping(to: field), let cell = copy(from: raw) else { return nil }

        await storage.create(cell, under: key)
        await store?.create(cell, under: key)
        return cell
    }

    /// Fetches a sheet — **once per sheet**, even if ten cells need it.
    ///
    /// Without this consolidation every chapter mark loads its own sheet: with five marks on the
    /// same sheet, five times 22 MB through a tunnel with 0.3 Mbit/s.
    private var sheetTasks: [String: Task<CGImage?, Never>] = [:]

    private func fetchAtlas(_ source: URL, pixels: Int) async -> CGImage? {
        let key = "\(source.absoluteString)|sheet|\(pixels)"
        if let running = sheetTasks[key] { return await running.value }
        let job = Task<CGImage?, Never> { [session] in
            do {
                let (data, reply) = try await session.data(from: source)
                if let http = reply as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    ImageMessage.notify(.hint, .network, "Trickplay sheet returned \(http.statusCode)")
                    return nil
                }
                return downscaled(data, to: pixels)
            } catch is CancellationError {
                return nil
            } catch {
                ImageMessage.notify(.hint, .network, "Trickplay sheet not loaded", error)
                return nil
            }
        }
        sheetTasks[key] = job
        let image = await job.value
        sheetTasks[key] = nil
        return image
    }

    /// A real copy that does not hold on to its origin.
    private nonisolated func copy(from image: CGImage) -> CGImage? {
        guard
            let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
            let surface = CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        surface.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return surface.makeImage()
    }

    private func forget(_ key: String) {
        preloaded[key] = nil
    }

    private func fetch(_ source: URL, pixels: Int, key: String) async -> CGImage? {
        if let remembered = await storage.image(for: key) { return remembered }
        if let stored = await store?.image(for: key) {
            await storage.create(stored, under: key)
            return stored
        }

        do {
            let (data, reply) = try await session.data(from: source)
            if let http = reply as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                ImageMessage.notify(.hint, .network, "Image returned \(http.statusCode)")
                return nil
            }
            guard let image = downscaled(data, to: pixels) else {
                ImageMessage.notify(.hint, .network, "Image could not be read (\(data.count) bytes)")
                return nil
            }
            await storage.create(image, under: key)
            await store?.create(image, under: key)
            return image
        } catch is CancellationError {
            // bewusst still: a cancelled load is no failure but the normal case when browsing —
            // whoever records it fills the log with what went well.
            return nil
        } catch {
            ImageMessage.notify(.error, .network, "Image not loaded", error)
            return nil
        }
    }

    /// The series color — **once per image and not on every display.**
    ///
    /// **The finding of 2026-09-07. (AP3), found unchanged on 2026-09-10:** the path from memory called
    /// this calculation just like the path from the network. Fetching an image from memory costs
    /// a dictionary access; obtaining the color from it costs a pass over every pixel. When
    /// scrolling through a shelf, that happened for every tile that came back into view — for a
    /// result that never changes: the same key means the same address at the same edge length.
    ///
    /// **It is remembered in the ``ImageCacheActor``**, so that the color is evicted with the image
    /// and does not stay lying next to it.
    private func color(from image: CGImage, key: String) async -> AccentPaletteValue? {
        if case .computed(let remembered) = await storage.color(for: key) {
            return remembered
        }
        let computed = color(from: image)
        await storage.memorize(color: computed, under: key)
        return computed
    }

    private func color(from image: CGImage) -> AccentPaletteValue? {
        guard let computed = AccentExtractor.color(from: image) else { return nil }
        return AccentPaletteValue(hue: computed.hue, saturation: computed.saturation)
    }

    /// Builds the image at the target size right away.
    private nonisolated func downscaled(_ data: Data, to pixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let parameters: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, parameters as CFDictionary)
    }
}
