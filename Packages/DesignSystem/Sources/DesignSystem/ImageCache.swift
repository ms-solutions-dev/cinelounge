import Foundation
import ImageIO
import SwiftUI

#if canImport(UIKit)
    import UIKit
#else
    import AppKit
#endif

/// Cache for images on two levels.
///
/// **Why two?** A decoded image takes up many times the size of the file: a
/// poster of 240×360 points is drawn at 480×720 pixels on an Apple TV 4K
/// and then takes up about 1.38 MB — the file itself only about 200 KB.
/// A full-width background image comes to over 30 MB decoded. Anyone who limits by
/// count instead of by size miscalculates here by a factor of six.
///
/// Hence:
/// - **Memory** holds the decoded images, limited by *bytes* and
///   via `NSCache`. It evicts by itself under memory pressure instead of waiting
///   until the system terminates the whole app.
/// - **Disk** holds the unmodified files via `URLCache`. They are small,
///   survive an app restart and are managed by the system.
///
/// On tvOS the disk storage is explicitly volatile — the system may clear it
/// at any time. The app must therefore work without it; it is pure
/// acceleration, not a foundation.
///
/// ## Decode downscaled, don't draw downscaled
///
/// Every fetch names the edge length at which the image is **drawn**. Two things
/// depend on it: the key in the cache and the size to which the image is
/// downscaled when decoding.
///
/// That was the most expensive finding of the performance check. `UIImage(data:)` does not decode the
/// pixels on creation but **on drawing** — and that happens on
/// the main thread. A poster fetched at 840 pixels width and drawn at 480
/// is resampled there on every frame. Via ImageIO the image is
/// instead decoded once at the target size, off the main thread, and
/// afterwards drawing is a copy operation.
public actor ImageCache {

    public static let shared = ImageCache()

    /// Images in memory — **outside the actor isolation**.
    ///
    /// This is not a subtlety but the answer to "it should be there immediately
    /// from the cache". When the store was bound to the actor,
    /// *every* hit cost two hops: from the view to the actor
    /// and back to the main thread. Both are busy while scrolling,
    /// so an image that had long been loaded still appeared only one to two
    /// frames later — visible as a brief flash of the placeholder.
    ///
    /// Nothing needs protecting here: `NSCache` is built for access from several threads
    /// by itself. The binding to the actor therefore never secured anything,
    /// it only cost.
    /// `nonisolated` and not just `let`: a `let` of an actor still counts as isolated **across
    /// module boundaries** — in the other module it could
    /// later become a `var`. Without the keyword here the check failed even though
    /// the app itself compiled.
    nonisolated let memory: ImageMemory
    private let session: URLSession
    /// Fetches in flight, per address **and** target size.
    ///
    /// The value is the finished image and no longer the raw data: previously the
    /// running fetch only handed out data, and everyone who attached decoded it
    /// **once more** themselves and stored the result nowhere. The coalescing
    /// saved the request but not the work — and for the attached
    /// callers the cache stayed empty forever.
    private var inFlight: [String: Task<PlatformImage?, Never>] = [:]

    // MARK: - How many at once
    //
    // **Six simultaneous transfers are not faster, they are only later.**
    //
    // They share the same line in equal parts. The total duration for all
    // six is thus the same as sequentially — but the **first** image arrives
    // six times later. That is exactly what the viewer notices: instead of the tiles
    // filling one after the other, everything stays gray and then switches together.
    // Or it runs together into the timeout.
    //
    // Limiting the number of connections is not enough for that: `URLSession` then queues the
    // remaining requests itself, and their timeout runs from the moment of sending —
    // whoever is at the back has timed out before their turn. That is why waiting happens here
    // before the request goes out at all.

    /// How many images are fetched at once.
    ///
    /// Three: enough that one slow response does not hold up the others, and few
    /// enough that the first tiles appear quickly.
    static let maxConcurrentFetches = 3

    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    private func acquireSlot() async {
        while running >= Self.maxConcurrentFetches {
            await withCheckedContinuation { waiting.append($0) }
        }
        running += 1
    }

    private func releaseSlot() {
        running -= 1
        guard !waiting.isEmpty else { return }
        waiting.removeFirst().resume()
    }

    /// - Parameters:
    ///   - memoryLimit: Upper limit in memory, in bytes.
    ///
    ///     160 MB, and the number has a reason: the Home screen holds up to 48
    ///     posters at 1.38 MB each, plus the header's background image. With the
    ///     previous 60 MB the store constantly evicted what was needed again right away —
    ///     and every eviction means reloading and re-decoding.
    ///     A cache that is too small is slower than none, because it does the
    ///     work twice.
    ///
    ///     When playback starts it is released anyway via ``releaseMemory()``;
    ///     the limit therefore applies to the overview, not alongside the
    ///     player.
    ///   - diskLimit: Upper limit on disk. Files are small, so it can
    ///     be more generous here.
    ///   - requestTimeout: How long to wait for a response. Specifiable only
    ///     so that the tests do not have to wait twenty seconds for an invented address.
    public init(
        memoryLimit: Int = 160 * 1024 * 1024,
        diskLimit: Int = 1024 * 1024 * 1024,
        requestTimeout: TimeInterval = 20
    ) {
        self.memory = ImageMemory(limit: memoryLimit)

        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(
            memoryCapacity: 8 * 1024 * 1024,
            diskCapacity: diskLimit,
            diskPath: "cinelounge.images"
        )
        // Existing entries are used as long as the server reports nothing newer.
        config.requestCachePolicy = .useProtocolCachePolicy
        config.timeoutIntervalForRequest = requestTimeout
        // **Six, and that is the default — the throttle sits elsewhere.**
        //
        // A comment used to stand here that justified three, above a value of
        // six. The resolution: how many images go over the line at the same time is decided by ``maxConcurrentFetches`` (three), and **before**
        // sending — the justification including the measurement is there. This number here takes effect
        // behind it and therefore never sees more than three image fetches at once;
        // lowering it to three would have no effect, raising it would not either.
        config.httpMaximumConnectionsPerHost = 6
        self.session = URLSession(configuration: config)
    }

    /// What is there **right now** — without waiting.
    ///
    /// The path for the regular case: a tile that has been visible before has its
    /// image in memory. Through this access it can bring it along at build time,
    /// instead of starting with a placeholder and delivering it afterwards.
    /// The difference is exactly what was noticed on the TV as "loads
    /// late".
    ///
    /// Returns `nil` if the image is missing — then the usual path via
    /// ``image(for:decodeLimit:)`` remains.
    public nonisolated func cachedImage(for url: URL, decodeLimit: Int? = nil) -> Image? {
        memory.object(Self.key(url, decodeLimit)).map(Self.wrap)
    }

    /// The image for an address, downscaled to the size at which it is drawn.
    ///
    /// - Parameter decodeLimit: The longest edge in **pixels**, from
    ///   ``ImageSizing/decodeLimit(points:headroom:)``. Without it the image is decoded at full
    ///   size — correct only where the pixels themselves are needed.
    public func image(for url: URL, decodeLimit: Int? = nil) async -> Image? {
        await platformImage(for: url, decodeLimit: decodeLimit).map(Self.wrap)
    }

    /// The same image, but in the system's form instead of as a view element.
    ///
    /// Needed where the pixels must be accessed — when
    /// deriving the accent color. That is not possible from a SwiftUI `Image`;
    /// it is a description, not an image.
    ///
    /// ``decodeLimit`` is deliberately left empty there: the derivation computes over a
    /// histogram, and a different downscaling would mean different colors. It already requests its
    /// image at 240 points width anyway.
    /// - Parameter keepInMemory: Whether the result stays in memory.
    ///
    ///   Explicitly **no** for the derivation of the accent color: this image is never
    ///   drawn, it serves once as a template for an evaluation whose result is
    ///   kept elsewhere anyway. It would still permanently occupy space and
    ///   thereby displace exactly the posters currently visible — one of the
    ///   causes of images "not always being there". On disk it stays
    ///   stored, where it costs nothing.
    public func platformImage(
        for url: URL,
        decodeLimit: Int? = nil,
        keepInMemory: Bool = true
    ) async -> PlatformImage? {
        let key = Self.key(url, decodeLimit)

        if let cached = memory.object(key) {
            return cached
        }
        // If a fetch for the same address at the same size is already running, it is
        // attached to instead of starting a second one — in a row with recurring
        // images that saves many times over in requests **and** in decoding work.
        if let running = inFlight[key] {
            return await running.value
        }

        // Wait **before** the request goes out — see ``maxConcurrentFetches``.
        // Then look again: while waiting, the same image may have been
        // fetched by another tile, and this would then be a second
        // fetch for something that is already there.
        await acquireSlot()
        defer { releaseSlot() }

        if let cached = memory.object(key) { return cached }
        if let running = inFlight[key] { return await running.value }

        // **`Task.detached` and not `Task`.** An ordinary `Task` in a
        // method of this actor inherits its isolation — decoding would then run
        // on the actor and block every other query, although it is pure computation
        // and touches no state.
        let task = Task.detached(priority: .userInitiated) { [session] () -> PlatformImage? in
            await Self.fetch(url, from: session, decodeLimit: decodeLimit)
        }
        inFlight[key] = task

        let image = await task.value
        inFlight[key] = nil

        guard let image else { return nil }
        guard keepInMemory else { return image }

        // The cost counted is the size in memory, not that of the file —
        // otherwise the limit has no effect.
        memory.set(image, for: key, cost: Self.memoryCost(of: image))
        return image
    }

    /// Loads images ahead of time — quietly, one after the other, and only when
    /// nothing real is pending.
    ///
    /// For the first posters of each library after startup: without the prefetch,
    /// every grid poster starts loading only when its tile appears —
    /// on this line that means pop-in, row by row.
    ///
    /// If the surrounding task is cancelled, the prefetch stops too — it is an extra,
    /// not an obligation.
    ///
    /// **Two conditions, and both were dearly bought** (two findings from
    /// 2026-08-08 in one afternoon):
    ///
    /// 1. **It waits for waiting requests, not for idle.** Here stood
    ///    `while running > 0`, that is "wait until no image at all is being
    ///    fetched". At startup that holds, since nothing is running there. In an open
    ///    library, however, some image is always running — the prefetch never got
    ///    its turn and was silently ineffective for everything but startup
    ///    (the fix seemed to have no effect).
    ///
    /// 2. **And at most one at a time, app-wide.** That was the
    ///    bill for number one: several prefetches run at the same time —
    ///    the library posters, the channel logos, the background image, cast,
    ///    episodes. Each on its own took only one of the three slots;
    ///    together they took all three, and the visible images queued
    ///    behind. After that a detail page loaded **no** cast photos
    ///    at all anymore, and the channel logos stayed empty on first opening.
    ///    The prefetch had clogged the line it was supposed to keep free.
    ///
    /// Together that means: two of the three slots always stay free for whatever
    /// someone is looking at right now — no matter how many prefetches want to run.
    public func prefetch(_ urls: [URL], decodeLimit: Int? = nil) async {
        for url in urls {
            guard !Task.isCancelled else { return }
            if memory.object(Self.key(url, decodeLimit)) != nil { continue }

            while !waiting.isEmpty || prefetching {
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: .milliseconds(120))
            }

            prefetching = true
            // **The prefetch fills the disk, not the memory**
            // (AP7 · L5, expert review 2026-08-24). Here stood the default
            // `keepInMemory: true`, and with it the startup prefetch pushed 564 MB
            // through a 160 MB store: 100 posters × 3 libraries ×
            // 1.88 MB, of which only the last roughly 85 survive — and the
            // images someone is looking at right now get evicted in the process.
            //
            // The comment on ``StartupPrefetch/postersPerLibrary`` already said
            // what was meant: "The prefetch initially fills only the
            // disk." Only the call did something else.
            _ = await platformImage(for: url, decodeLimit: decodeLimit, keepInMemory: false)
            prefetching = false
        }
    }

    /// Whether a prefetch image is currently being fetched — the lock from number two above.
    ///
    /// On the actor and not on the individual prefetch run, because that is exactly the point:
    /// the prefetches know nothing about each other, but they share the line.
    /// Visible in the module so that a test can query it after a run:
    /// if it got stuck, **no** prefetch would ever run again — and nothing would show it
    /// except that images pop in again.
    var prefetching = false

    /// Fetches and decodes, with **one** second attempt.
    ///
    /// The reason shows on the TV: when the Home screen opens, several dozen
    /// tiles request at once, and whatever is waiting behind the open connections runs
    /// into the timeout. A failure was noted nowhere and retried nowhere
    /// — the tile stayed empty forever. That was exactly "sometimes images
    /// don't load at all".
    ///
    /// Only what is worth retrying is retried; see ``isWorthRetrying(status:)``.
    nonisolated static func fetch(
        _ url: URL,
        from session: URLSession,
        decodeLimit: Int?
    ) async -> PlatformImage? {
        // **Three attempts with growing spacing, not two with a fixed one.**
        //
        // Two attempts 500 ms apart fall into the same overload window: when
        // the Home screen opens, the header image, first shelf and the color fetches start
        // at once, and half a second later the same queue stands
        // unchanged. The second attempt therefore failed for the same cause as
        // the first — and after that there was no third. The tile stayed empty as long as
        // the view lived.
        // **An image on the device** — the still frame from ``Core/StillFrameStore``. It has
        // no HTTP response, and `status == 200` below would never let it through.
        if url.isFileURL {
            return (try? Data(contentsOf: url)).flatMap { decode($0, limit: decodeLimit) }
        }

        let delays: [Duration] = [.zero, .milliseconds(800), .seconds(3)]

        for attempt in delays.indices {
            if delays[attempt] > .zero {
                try? await Task.sleep(for: delays[attempt])
            }

            guard let (data, response) = try? await session.data(from: url) else {
                continue  // No response: network gone or timeout — try once more.
            }
            let status = (response as? HTTPURLResponse)?.statusCode
            if status == 200 {
                return decode(data, limit: decodeLimit)
            }
            guard isWorthRetrying(status: status) else { return nil }
        }
        return nil
    }

    /// Whether a second attempt can bring anything.
    ///
    /// No response means network or timeout — that can go well the second time.
    /// From 500 up the server has a temporary problem, likewise worth one attempt.
    /// A 404, on the other hand, means that this image does not exist; for home videos that is
    /// the normal case, and asking again only costs a connection that is
    /// missing elsewhere.
    nonisolated static func isWorthRetrying(status: Int?) -> Bool {
        guard let status else { return true }
        return status >= 500
    }

    /// Discards everything — after logging out, for example, so that no images of the previous
    /// account remain.
    public func clear() {
        memory.removeAll()
        session.configuration.urlCache?.removeAllCachedResponses()
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
    }

    // MARK: - Usage and cleanup

    /// How much is occupied on disk, in bytes.
    ///
    /// Shown in Settings: a cache whose size
    /// nobody sees and nobody can clear grows unnoticed — and suspicion
    /// then falls on the app.
    public func diskUsage() -> Int {
        session.configuration.urlCache?.currentDiskUsage ?? 0
    }

    /// The agreed upper limit on disk.
    public func diskLimit() -> Int {
        session.configuration.urlCache?.diskCapacity ?? 0
    }

    /// Releases the memory but keeps the files on disk.
    ///
    /// Intended for the moment playback begins: there the
    /// player needs the memory more urgently than the overview its thumbnails,
    /// and reloading from disk is fast.
    public func releaseMemory() {
        memory.removeAll()
    }

    // MARK: - Key, decoding, cost

    /// Address **and** target size.
    ///
    /// Without the size in the key, the info column would get the poster at the
    /// size of a grid tile, just because the same address was once fetched small
    /// before — a blurry image with no recognizable cause.
    static func key(_ url: URL, _ limit: Int?) -> String {
        guard let limit else { return url.absoluteString }
        return "\(url.absoluteString)|\(limit)"
    }

    /// Decodes the data, right at the size at which it is drawn.
    ///
    /// Without a limit the ordinary path — then decoding happens on drawing, and that
    /// is correct only where the pixels themselves are needed.
    ///
    /// If ImageIO fails, it falls back to the ordinary path instead of
    /// returning nothing: an image at the wrong size is still better than an empty
    /// area, and a logo from a foreign channel list may come in a format
    /// that only the system class knows.
    nonisolated static func decode(_ data: Data, limit: Int?) -> PlatformImage? {
        guard let limit, let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return PlatformImage(data: data)
        }

        let options: [CFString: Any] = [
            // Downscale even if the file ships with an embedded preview:
            // its size is determined by the sender, not by us.
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: limit,
            kCGImageSourceCreateThumbnailWithTransform: true,
            // **The actual gain.** Without this the result is unpacked only on
            // drawing — that is, on the main thread, in the middle of scrolling.
            kCGImageSourceShouldCacheImmediately: true,
        ]

        guard
            let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                source, 0, options as CFDictionary
            )
        else {
            return PlatformImage(data: data)
        }

        #if canImport(UIKit)
            // The scale is part of it: without it a pixel counts as one point, so the
            // image would be twice as large in the view as intended and would be
            // scaled down again — exactly the work that is supposed to be saved here.
            return UIImage(cgImage: thumbnail, scale: ImageSizing.drawScale, orientation: .up)
        #else
            return NSImage(
                cgImage: thumbnail,
                size: CGSize(width: thumbnail.width, height: thumbnail.height)
            )
        #endif
    }

    /// How much a decoded image takes up in memory: four bytes per
    /// pixel, and one point on a 4K device is several pixels.
    static func memoryCost(of image: PlatformImage) -> Int {
        #if canImport(UIKit)
            let scale = image.scale
            let size = image.size
        #else
            let scale: CGFloat = 1
            let size = image.size
        #endif
        return Int(size.width * scale * size.height * scale * 4)
    }

    static func wrap(_ image: PlatformImage) -> Image {
        #if canImport(UIKit)
            Image(uiImage: image)
        #else
            Image(nsImage: image)
        #endif
    }
}

/// The decoded images, limited by bytes and reachable from any thread.
///
/// A class of its own and no `NSCache` inside the actor: only this way can the
/// cache be queried **without waiting**. `@unchecked Sendable` is not a
/// claim made blindly here — `NSCache` is explicitly built for access from several
/// threads, and this class adds no state of its own that would need
/// protecting. Whoever extends it has to check that again.
final class ImageMemory: @unchecked Sendable {

    private let cache = NSCache<NSString, PlatformImage>()

    init(limit: Int) {
        cache.totalCostLimit = limit
    }

    func object(_ key: String) -> PlatformImage? {
        cache.object(forKey: key as NSString)
    }

    /// - Parameter cost: The size in memory, not that of the file.
    func set(_ image: PlatformImage, for key: String, cost: Int) {
        cache.setObject(image, forKey: key as NSString, cost: cost)
    }

    func removeAll() {
        cache.removeAllObjects()
    }
}

/// The image class is named differently per platform — the tests run on the Mac,
/// the app on the TV.
#if canImport(UIKit)
    public typealias PlatformImage = UIImage
#else
    public typealias PlatformImage = NSImage
#endif
